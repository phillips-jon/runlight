<?php

declare(strict_types=1);

namespace Runlight\Importers;

/**
 * Why an import stopped, as a code the dashboard says in its own words.
 * `code` is the string code (Exception's own `$code` property, widened to public, as TS has it).
 */
class ImportError extends \RuntimeException
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
