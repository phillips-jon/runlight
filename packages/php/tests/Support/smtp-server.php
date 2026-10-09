<?php

declare(strict_types=1);

/*
 * A fake SMTP server for the mail tests, run in its own process. It prints the
 * port it listens on, then serves one connection at a time, and after each one
 * prints a JSON line with every byte the client sent.
 *
 * relay: answers as the TS tests' relay does (AUTH PLAIN checks jon/pw, no STARTTLS).
 * trickle: sends "220-still here" every 100 ms and never finishes its greeting.
 * refuse: sends "535 no" and closes at once.
 */

$mode = $argv[1] ?? 'relay';
$server = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
if ($server === false) {
    fwrite(STDERR, "$errstr\n");
    exit(1);
}
echo explode(':', stream_socket_get_name($server, false))[1], "\n";

while (true) {
    $socket = @stream_socket_accept($server, 3600);
    if ($socket === false) {
        continue;
    }
    $received = '';
    if ($mode === 'refuse') {
        fwrite($socket, "535 no\r\n");
        @fclose($socket);
        echo json_encode(['received' => '', 'closed' => true]), "\n";
        continue;
    }
    if ($mode === 'trickle') {
        stream_set_blocking($socket, false);
        while (true) {
            if (@fwrite($socket, "220-still here\r\n") === false) {
                break;
            }
            usleep(100_000);
            $chunk = @fread($socket, 8192);
            if ($chunk === false || ($chunk === '' && feof($socket))) {
                break;
            }
            $received .= $chunk;
        }
        @fclose($socket);
        echo json_encode(['received' => $received, 'closed' => true]), "\n";
        continue;
    }
    fwrite($socket, "220 test ESMTP\r\n");
    $buffer = '';
    $inData = false;
    $open = true;
    while ($open && ($chunk = fread($socket, 8192)) !== false && $chunk !== '') {
        $received .= $chunk;
        $buffer .= $chunk;
        while (($at = strpos($buffer, "\r\n")) !== false) {
            $line = substr($buffer, 0, $at);
            $buffer = substr($buffer, $at + 2);
            if ($inData) {
                if ($line === '.') {
                    $inData = false;
                    fwrite($socket, "250 queued\r\n");
                }
                continue;
            }
            if (str_starts_with($line, 'EHLO')) {
                fwrite($socket, "250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n");
            } elseif (str_starts_with($line, 'AUTH PLAIN')) {
                fwrite($socket, base64_decode(substr($line, 11)) === "\0jon\0pw" ? "235 ok\r\n" : "535 no\r\n");
            } elseif ($line === 'DATA') {
                $inData = true;
                fwrite($socket, "354 go\r\n");
            } elseif ($line === 'QUIT') {
                fwrite($socket, "221 bye\r\n");
                $open = false;
                break;
            } else {
                fwrite($socket, "250 ok\r\n");
            }
        }
    }
    // Whatever the client still sends before it hangs up.
    stream_set_timeout($socket, 1);
    while ($open === false && ($chunk = @fread($socket, 8192)) !== false && $chunk !== '') {
        $received .= $chunk;
    }
    @fclose($socket);
    echo json_encode(['received' => $received]), "\n";
}
