<?php

declare(strict_types=1);

namespace Runlight\Mail;

/**
 * A mail problem to show the person setting it up. `code` and `params` let the dashboard say it in
 * its own language; a service's own words, which only it can give, travel in `params.detail`.
 *
 * `code` is the string code (Exception's own `$code` property, widened to public, as TS has it).
 */
class MailError extends \RuntimeException
{
    /** @var string */
    public $code;

    /** @var array<string, string> */
    public readonly array $params;

    /** @param array<string, string>|null $params null means `{ detail: message }`, as the TS default */
    public function __construct(string $message, string $code = 'mail_failed', ?array $params = null)
    {
        parent::__construct($message);
        $this->code = $code;
        $this->params = $params ?? ['detail' => $message];
    }
}
