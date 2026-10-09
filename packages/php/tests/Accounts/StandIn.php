<?php

declare(strict_types=1);

namespace Runlight\Tests\Accounts;

use Runlight\Http\Request;
use Runlight\Store\SqlStore;

/**
 * The little of a Runlight that accounts on the web reach for: its store, its mail, and the client's address.
 * Mail is kept in a list instead of sent; `$mailFails` makes sending throw.
 */
final class StandIn
{
    /** @var list<array<string, mixed>> */
    public array $sent = [];
    public ?array $mail = null;
    public ?\Throwable $mailFails = null;

    public function __construct(public readonly SqlStore $store)
    {
    }

    public function mailSettings(): ?array
    {
        return $this->mail;
    }

    public function sendMail(array $message): void
    {
        if ($this->mailFails !== null) {
            throw $this->mailFails;
        }
        $this->sent[] = $message;
    }

    /** The last X-Forwarded-For entry, else the connection's address, as Runlight reads it by default. */
    public function clientIp(Request $request, array $context = []): string
    {
        $header = $request->headers->get('x-forwarded-for');
        if ($header !== null && trim($header) !== '') {
            $parts = array_values(array_filter(array_map('trim', explode(',', $header)), static fn (string $p): bool => $p !== ''));
            return (string) end($parts);
        }
        return $context['ip'] ?? '';
    }
}
