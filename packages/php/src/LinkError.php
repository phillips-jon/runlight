<?php

declare(strict_types=1);

namespace Runlight;

/**
 * A link that cannot be made. `code` and `params` let the dashboard say it in its own language.
 * `code` is the string code (Exception's own `$code` property, widened to public, as TS has it).
 */
class LinkError extends \RuntimeException
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
