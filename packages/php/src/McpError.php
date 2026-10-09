<?php

declare(strict_types=1);

namespace Runlight;

/** A JSON-RPC error with its own code, such as -32602 for an unknown tool, answered with its message as it is. */
final class McpError extends \RuntimeException
{
    public function __construct(string $message, int $code)
    {
        parent::__construct($message, $code);
    }
}
