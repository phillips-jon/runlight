<?php

declare(strict_types=1);

namespace Runlight;

/**
 * What went wrong with the assistant, as a code the dashboard says in its own words; a service's own text goes
 * in `params['detail']`. The code is text, as in TypeScript, so it is kept in `$code` as PDOException keeps its own.
 */
final class AssistantError extends \RuntimeException
{
    /** @var string */
    public $code;

    /** @param array<string, string> $params */
    public function __construct(string $message, string $code, public readonly array $params = [])
    {
        parent::__construct($message);
        $this->code = $code;
    }
}
