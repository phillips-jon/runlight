<?php

declare(strict_types=1);

namespace Runlight\Importers;

/** A service answered with a status that is not success. */
final class HttpError extends ImportError
{
    /** @param array<string, string> $params */
    public function __construct(string $message, public readonly int $status, string $code, array $params = [])
    {
        parent::__construct($message, $code, $params);
    }
}
