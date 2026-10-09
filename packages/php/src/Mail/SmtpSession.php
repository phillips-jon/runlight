<?php

declare(strict_types=1);

namespace Runlight\Mail;

/**
 * One SMTP connection for Smtp::send: the socket, the replies read from it
 * (multi-line included, one at a time), and the whole send's deadline, which
 * every wait is held to.
 *
 * @internal
 */
final class SmtpSession
{
    /** @var resource|null */
    private $socket = null;
    private string $buffer = '';
    /** @var list<string> */
    private array $lines = [];

    public function __construct(
        private readonly string $host,
        private readonly int $port,
        private readonly int $deadline,
        private readonly string $lateMessage,
    ) {
    }

    private function late(): MailError
    {
        $this->close();
        return new MailError($this->lateMessage, 'mail_slow', ['host' => "{$this->host}:{$this->port}"]);
    }

    /** Milliseconds left before the deadline. */
    private function left(): float
    {
        return ($this->deadline - hrtime(true)) / 1_000_000;
    }

    public function connect(bool $tls, int $timeoutMs): void
    {
        $address = str_contains($this->host, ':') ? "[{$this->host}]" : $this->host;
        $wait = min($timeoutMs, $this->left());
        if ($wait <= 0) {
            throw $this->late();
        }
        $context = stream_context_create(['ssl' => ['peer_name' => $this->host, 'SNI_enabled' => true, 'verify_peer' => true, 'verify_peer_name' => true]]);
        $errno = 0;
        $errstr = '';
        $socket = @stream_socket_client(($tls ? 'tls' : 'tcp') . "://$address:{$this->port}", $errno, $errstr, $wait / 1000, STREAM_CLIENT_CONNECT, $context);
        if ($socket === false) {
            if ($this->left() <= 0) {
                throw $this->late();
            }
            $detail = $errstr !== '' ? $errstr : ($wait >= $timeoutMs ? 'timed out' : 'connection failed');
            throw new MailError("SMTP: could not connect to {$this->host}:{$this->port}: $detail", 'mail_unreachable', ['host' => "{$this->host}:{$this->port}", 'detail' => $detail]);
        }
        $this->socket = $socket;
    }

    public function write(string $line): void
    {
        $this->writeRaw("$line\r\n");
    }

    public function writeRaw(string $data): void
    {
        while ($data !== '') {
            if ($this->socket === null) {
                throw new MailError('SMTP: the server closed the connection');
            }
            $wait = $this->left();
            if ($wait <= 0) {
                throw $this->late();
            }
            stream_set_timeout($this->socket, (int) floor($wait / 1000), (int) (fmod($wait, 1000) * 1000));
            $sent = @fwrite($this->socket, $data);
            if ($sent === false || $sent === 0) {
                if ($this->left() <= 0) {
                    throw $this->late();
                }
                throw new MailError('SMTP: the server closed the connection');
            }
            $data = substr($data, $sent);
        }
    }

    /**
     * The next whole reply. Throws when none comes within `$timeoutMs` (or, with
     * `$quiet`, gives null then), and a mail_slow error once the deadline passes.
     *
     * @return array{code: int, text: string}|null
     */
    public function next(int $timeoutMs, bool $quiet = false): ?array
    {
        $idleUntil = hrtime(true) + $timeoutMs * 1_000_000;
        for (;;) {
            while (($at = strpos($this->buffer, "\r\n")) !== false) {
                $line = substr($this->buffer, 0, $at);
                $this->buffer = substr($this->buffer, $at + 2);
                $this->lines[] = (string) substr($line, 4);
                if (($line[3] ?? '') !== '-') {
                    $head = substr($line, 0, 3);
                    $reply = ['code' => preg_match('/^\d+$/', $head) ? (int) $head : -1, 'text' => implode(' ', $this->lines)];
                    $this->lines = [];
                    return $reply;
                }
                // Activity resets the idle timer, as Node's socket timeout does.
                $idleUntil = hrtime(true) + $timeoutMs * 1_000_000;
            }
            if ($this->socket === null) {
                throw new MailError('SMTP: the server closed the connection');
            }
            $deadlineLeft = $this->left();
            if ($deadlineLeft <= 0) {
                throw $this->late();
            }
            $idleLeft = ($idleUntil - hrtime(true)) / 1_000_000;
            if ($idleLeft <= 0) {
                if ($quiet) {
                    return null;
                }
                $this->close();
                throw new MailError('SMTP: timed out');
            }
            $wait = min($deadlineLeft, $idleLeft);
            stream_set_timeout($this->socket, (int) floor($wait / 1000), (int) (fmod($wait, 1000) * 1000));
            $chunk = @fread($this->socket, 8192);
            if (stream_get_meta_data($this->socket)['timed_out']) {
                // Nothing came in the time left; the checks above decide what that means.
                continue;
            }
            if ($chunk === false || ($chunk === '' && feof($this->socket))) {
                $this->close();
                throw new MailError('SMTP: the server closed the connection');
            }
            if ($chunk !== '') {
                $this->buffer .= $chunk;
                $idleUntil = hrtime(true) + $timeoutMs * 1_000_000;
            }
        }
    }

    /** Turns on TLS after STARTTLS. Anything the server sent before it is dropped, as a new reader would. */
    public function startTls(): void
    {
        $this->buffer = '';
        $this->lines = [];
        $wait = $this->left();
        if ($wait <= 0) {
            throw $this->late();
        }
        stream_set_timeout($this->socket, (int) floor($wait / 1000), (int) (fmod($wait, 1000) * 1000));
        stream_context_set_option($this->socket, 'ssl', 'peer_name', $this->host);
        stream_context_set_option($this->socket, 'ssl', 'SNI_enabled', true);
        stream_context_set_option($this->socket, 'ssl', 'verify_peer', true);
        stream_context_set_option($this->socket, 'ssl', 'verify_peer_name', true);
        error_clear_last();
        $ok = @stream_socket_enable_crypto($this->socket, true, STREAM_CRYPTO_METHOD_TLS_CLIENT);
        if ($ok !== true) {
            if ($this->left() <= 0) {
                throw $this->late();
            }
            $reason = error_get_last()['message'] ?? 'handshake failed';
            throw new MailError("SMTP: TLS failed: $reason");
        }
    }

    public function close(): void
    {
        if ($this->socket !== null) {
            @fclose($this->socket);
            $this->socket = null;
        }
    }
}
