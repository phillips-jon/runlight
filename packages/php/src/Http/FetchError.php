<?php

declare(strict_types=1);

namespace Runlight\Http;

/** No answer came back: the connection was refused, timed out, or failed TLS. fetch() rejects with a TypeError then. */
class FetchError extends \RuntimeException
{
    public function __construct(string $message, public readonly bool $timedOut = false, ?\Throwable $previous = null)
    {
        parent::__construct($message, 0, $previous);
    }
}
