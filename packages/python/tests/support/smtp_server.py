"""A fake SMTP server for the mail tests, on a port the system picks, in a thread of its own. It serves one
connection at a time, and after each one reports every byte the client sent.

relay: answers as the TS tests' relay does (AUTH PLAIN checks jon/pw, no STARTTLS).
trickle: sends "220-still here" every 100 ms and never finishes its greeting.
"""

from __future__ import annotations

import base64
import queue
import socket
import threading
import time
from typing import Any


class SmtpServer:
    def __init__(self, mode: str = "relay") -> None:
        self.mode = mode
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", 0))
        self._listener.listen()
        self._listener.settimeout(0.2)
        self.port: int = self._listener.getsockname()[1]
        self._done: queue.Queue[dict[str, Any]] = queue.Queue()
        self._stopped = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def conversation(self, seconds: float = 5) -> dict[str, Any] | None:
        """What the next finished connection received, waiting up to `seconds` for it."""
        try:
            return self._done.get(timeout=seconds)
        except queue.Empty:
            return None

    def stop(self) -> None:
        self._stopped.set()
        self._thread.join(2)
        self._listener.close()

    def _serve(self) -> None:
        while not self._stopped.is_set():
            try:
                conn, _ = self._listener.accept()
            except OSError:
                continue
            with conn:
                if self.mode == "trickle":
                    self._trickle(conn)
                else:
                    self._relay(conn)

    def _trickle(self, conn: socket.socket) -> None:
        received = b""
        conn.settimeout(0.1)
        while not self._stopped.is_set():
            try:
                conn.sendall(b"220-still here\r\n")
            except OSError:
                break
            time.sleep(0.1)
            try:
                chunk = conn.recv(8192)
            except (TimeoutError, socket.timeout):
                continue
            except OSError:
                break
            if not chunk:
                break
            received += chunk
        self._done.put({"received": received.decode("utf-8", "replace"), "closed": True})

    def _relay(self, conn: socket.socket) -> None:
        received = b""
        conn.settimeout(5)
        conn.sendall(b"220 test ESMTP\r\n")
        buffer = b""
        in_data = False
        open_ = True
        try:
            while open_:
                chunk = conn.recv(8192)
                if not chunk:
                    break
                received += chunk
                buffer += chunk
                while (at := buffer.find(b"\r\n")) >= 0:
                    line, buffer = buffer[:at], buffer[at + 2 :]
                    if in_data:
                        if line == b".":
                            in_data = False
                            conn.sendall(b"250 queued\r\n")
                        continue
                    if line.startswith(b"EHLO"):
                        conn.sendall(b"250-test\r\n250-SIZE 1000\r\n250 AUTH PLAIN\r\n")
                    elif line.startswith(b"AUTH PLAIN"):
                        ok = base64.b64decode(line[11:]) == b"\0jon\0pw"
                        conn.sendall(b"235 ok\r\n" if ok else b"535 no\r\n")
                    elif line == b"DATA":
                        in_data = True
                        conn.sendall(b"354 go\r\n")
                    elif line == b"QUIT":
                        conn.sendall(b"221 bye\r\n")
                        open_ = False
                        break
                    else:
                        conn.sendall(b"250 ok\r\n")
        except OSError:
            pass
        # Whatever the client still sends before it hangs up.
        if not open_:
            conn.settimeout(1)
            try:
                while chunk := conn.recv(8192):
                    received += chunk
            except OSError:
                pass
        self._done.put({"received": received.decode("utf-8", "replace")})
