<?php

declare(strict_types=1);

namespace Runlight\Http;

use Runlight\Json;

/**
 * An answer, shaped like the Fetch API's Response. The body is text, or a
 * callable that echoes its parts for answers too long to hold at once.
 */
final class Response
{
    public readonly Headers $headers;

    /**
     * @param string|\Closure():void $body
     * @param array<string, string|list<string>>|Headers $headers
     */
    public function __construct(
        private string|\Closure $body = '',
        public readonly int $status = 200,
        array|Headers $headers = [],
    ) {
        $this->headers = new Headers($headers);
    }

    /** @param array<string, string> $headers */
    public static function json(mixed $data, int $status = 200, array $headers = []): self
    {
        return new self(Json::encode($data), $status, ['content-type' => 'application/json'] + $headers);
    }

    public static function redirect(string $location, int $status = 302): self
    {
        return new self('', $status, ['location' => $location]);
    }

    public function ok(): bool
    {
        return $this->status >= 200 && $this->status < 300;
    }

    /** The whole body as text; a streamed body is run and captured. */
    public function text(): string
    {
        if (is_string($this->body)) {
            return $this->body;
        }
        ob_start();
        try {
            ($this->body)();
        } finally {
            $text = (string) ob_get_clean();
        }
        return $this->body = $text;
    }

    public function streamed(): bool
    {
        return !is_string($this->body);
    }

    /** Sends the answer from PHP's own server: status, headers, then the body. */
    public function emit(bool $withBody = true): void
    {
        if (!headers_sent()) {
            // PHP adds its default Content-Type to every answer; one sent without a type, such as a 202, carries none.
            if (!$this->headers->has('content-type')) {
                ini_set('default_mimetype', '');
            }
            http_response_code($this->status);
            foreach ($this->headers->all() as $name => $values) {
                foreach ($values as $i => $value) {
                    header(self::headerName($name) . ': ' . $value, $name !== 'set-cookie' && $i === 0);
                }
            }
        }
        if ($withBody) {
            $this->write();
        }
    }

    /** Echoes the body alone, as a framework's streamed response asks, after it has sent the headers itself. */
    public function write(): void
    {
        if (is_string($this->body)) {
            echo $this->body;
            return;
        }
        while (ob_get_level() > 0) {
            ob_end_flush();
        }
        ($this->body)();
    }

    private static function headerName(string $name): string
    {
        return implode('-', array_map('ucfirst', explode('-', $name)));
    }
}
