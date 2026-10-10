<?php

declare(strict_types=1);

namespace Runlight\Http;

/** A request body past its limit, answered with 413 rather than passed on empty. */
final class BodyTooLarge extends \RuntimeException
{
}
