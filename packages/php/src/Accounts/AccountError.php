<?php

declare(strict_types=1);

namespace Runlight\Accounts;

/**
 * A problem with an account change, to show the person making it. A RangeError in TypeScript, so a
 * \RangeException here, with a `code` and `params` the dashboard words in its own language.
 *
 * `code` is the string code (Exception's own `$code` property, widened to public, as TS has it).
 */
class AccountError extends \RangeException
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
