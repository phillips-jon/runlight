<?php

declare(strict_types=1);

namespace Runlight\Server;

/** A failure to reach Runlight or have it take a batch, told apart from a failure to read the log. */
final class SendError extends \RuntimeException
{
}
