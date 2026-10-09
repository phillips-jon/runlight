<?php

declare(strict_types=1);

namespace Runlight;

/** Refused before anything was fetched, because the address is not on the public internet. */
final class PrivateAddressError extends \RuntimeException
{
    public function __construct(string $what)
    {
        parent::__construct("$what is not a public address");
    }
}
