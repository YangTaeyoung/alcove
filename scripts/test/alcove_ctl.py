"""Client for the Alcove control socket (docs/control-protocol.md).

    from alcove_ctl import Client, ControlError
    c = Client()
    c.call("vm.exec", name="Windows 11", command="hostname")   # reply dict, or ControlError
    rid = c.send("vm.exec", name="Windows 11", command="Start-Sleep 5")
    c.call("vm.screenshot", name="Windows 11")                 # answered while the exec runs
    c.wait(rid, 30)

One reader thread files replies by id, so several requests can be in flight on
the connection. Starts `alcovectl serve` when nothing answers on the socket
(ALCOVE_CTL, or the development build in AlcoveKit/.build-ctl); Client(spawn=False)
never starts one.

stop_signal_handlers() and ignore_stop_signals() give the e2e scripts their
SIGTERM, SIGHUP and SIGINT handling.
"""
import json, os, signal, socket, subprocess, threading, time

STOP_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)

DEFAULT_SOCKET = os.path.expanduser("~/Library/Application Support/Alcove/control.sock")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


class ControlError(Exception):
    """The server answered `ok: false`, or the connection failed."""


class ControlTimeout(ControlError):
    """No reply arrived within the time given to wait()."""


def stop_signal_handlers():
    """Makes SIGTERM, SIGHUP and SIGINT raise SystemExit(128 + signal number); SIGHUP stays ignored when the process started with it ignored."""
    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    for sig in STOP_SIGNALS:
        if sig == signal.SIGHUP and signal.getsignal(sig) == signal.SIG_IGN:
            continue
        signal.signal(sig, terminate)


def ignore_stop_signals():
    """Ignores SIGTERM, SIGHUP and SIGINT and returns the handlers they had."""
    return {sig: signal.signal(sig, signal.SIG_IGN) for sig in STOP_SIGNALS}


class Client:
    def __init__(self, socket_path=None, spawn=True):
        self.socket_path = socket_path or os.environ.get("ALCOVE_CONTROL_SOCKET") or DEFAULT_SOCKET
        self._spawn = spawn
        self._sock = self._connect()
        self._write_lock = threading.Lock()
        self._cond = threading.Condition()
        self._replies = {}
        self._arrivals = {}
        self._arrived = 0
        self._next_id = 0
        self._closed = None
        self._reader = threading.Thread(target=self._read, daemon=True)
        self._reader.start()

    def _connect(self):
        for attempt in range(40):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                s.connect(self.socket_path)
                return s
            except OSError:
                s.close()
                if attempt == 0 and not self._spawn:
                    raise ControlError(f"cannot connect to {self.socket_path}; nothing was started") from None
                if attempt == 0:
                    ctl = os.environ.get("ALCOVE_CTL") or os.path.join(ROOT, "AlcoveKit", ".build-ctl", "debug", "alcovectl")
                    try:
                        subprocess.Popen([ctl, "serve", "--socket", self.socket_path], stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, start_new_session=True)
                    except OSError as e:
                        raise ControlError(f"cannot connect to {self.socket_path} and cannot start {ctl}: {e}; "
                                           "open Alcove.app or build alcovectl") from None
                time.sleep(0.5)
        raise ControlError("cannot connect to " + self.socket_path)

    def _read(self):
        buf = b""
        reason = "connection closed"
        try:
            while True:
                chunk = self._sock.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        reply = json.loads(line)
                    except ValueError:
                        continue
                    with self._cond:
                        self._arrived += 1
                        self._replies[reply.get("id")] = reply
                        self._arrivals[reply.get("id")] = (self._arrived, time.monotonic())
                        self._cond.notify_all()
        except OSError as e:
            reason = f"connection closed ({e})"
        with self._cond:
            self._closed = reason
            self._cond.notify_all()

    def send(self, op, **params):
        """Sends one request without waiting and returns its id. Every keyword goes to the server as a parameter,
        except `id`, which is the number of the request itself."""
        with self._write_lock:
            self._next_id += 1
            rid = self._next_id
            try:
                self._sock.sendall((json.dumps({**params, "id": rid, "op": op}) + "\n").encode())
            except OSError as e:
                raise ControlError(f"cannot send {op}: {e}") from None
        return rid

    def wait(self, rid, timeout=600):
        """Returns the reply to request `rid` as the server sent it (`ok` may be false); `timeout` None waits without limit."""
        end = None if timeout is None else time.monotonic() + timeout
        with self._cond:
            while rid not in self._replies:
                if self._closed:
                    raise ControlError(self._closed)
                left = None if end is None else end - time.monotonic()
                if left is not None and left <= 0:
                    raise ControlTimeout(f"no reply to request {rid} within {timeout} s")
                self._cond.wait(left)
            return self._replies.pop(rid)

    def arrival(self, rid):
        """(position among all replies received on this connection, time.monotonic() at receipt) of the reply to `rid`."""
        with self._cond:
            return self._arrivals[rid]

    def call(self, op, reply_timeout=600, **params):
        """Sends one request and returns its reply; raises ControlError with the server's message on `ok: false`.

        `reply_timeout` is how long this client waits. Every other keyword,
        including `timeout`, goes to the server as a parameter of the operation.
        """
        reply = self.wait(self.send(op, **params), reply_timeout)
        if not reply.get("ok"):
            raise ControlError(reply.get("error") or f"{op} failed")
        return reply

    def close(self):
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self._sock.close()
        self._reader.join(timeout=5)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
