<?php

declare(strict_types=1);

namespace Runlight\Tests\Support;

/** Runs tests/Support/smtp-server.php in a child process and reads back what each connection received. */
final class SmtpServer
{
    /** @var resource */
    private $process;
    /** @var resource */
    private $out;
    public readonly int $port;

    public function __construct(string $mode = 'relay')
    {
        $process = proc_open([PHP_BINARY, __DIR__ . '/smtp-server.php', $mode], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        if (!is_resource($process)) {
            throw new \RuntimeException('Could not start the fake SMTP server');
        }
        $this->process = $process;
        $this->out = $pipes[1];
        $port = $this->line(5);
        if ($port === null || !ctype_digit($port)) {
            throw new \RuntimeException('The fake SMTP server did not say its port: ' . stream_get_contents($pipes[2]));
        }
        $this->port = (int) $port;
    }

    /** What the next finished connection received, waiting up to `$seconds` for it. */
    public function conversation(float $seconds = 5): ?array
    {
        $line = $this->line($seconds);
        return $line === null ? null : json_decode($line, true);
    }

    private function line(float $seconds): ?string
    {
        $until = microtime(true) + $seconds;
        $text = '';
        while (microtime(true) < $until) {
            $read = [$this->out];
            $write = $except = null;
            $left = max(0, $until - microtime(true));
            if (stream_select($read, $write, $except, (int) $left, (int) (fmod($left, 1) * 1e6)) > 0) {
                $c = fgets($this->out);
                if ($c === false) {
                    return null;
                }
                $text .= $c;
                if (str_ends_with($text, "\n")) {
                    return rtrim($text, "\n");
                }
            }
        }
        return null;
    }

    public function stop(): void
    {
        proc_terminate($this->process);
        proc_close($this->process);
    }
}
