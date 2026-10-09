<?php

declare(strict_types=1);

namespace Runlight\Tests\Routes;

/** The stand-in's SettingsError, a RangeException with a code and params, as runlight.ts's is a RangeError. */
final class SettingsError extends \RangeException
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
