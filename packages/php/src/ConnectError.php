<?php

declare(strict_types=1);

namespace Runlight;

/**
 * Why connecting failed, as a code the dashboard says in its own words. The first four (expired, denied, refused, token) come back from the consent page, the rest (url, unreachable, not_runlight, endpoints, old, register) from starting.
 * `code` is the string code (Exception's own `$code` property, widened to public, as TS has it).
 */
class ConnectError extends \RangeException
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
