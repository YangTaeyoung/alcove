"""Stdio JSON-RPC client for the alcove-mcp server (mcp/dist/index.js), speaking like an MCP client."""
import collections, json, os, queue, subprocess, threading, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SERVER = os.path.join(ROOT, "mcp", "dist", "index.js")


class MCPError(Exception):
    """The server broke the protocol, answered a JSON-RPC error, went away or did not answer in time."""


class MCP:
    def __init__(self, env):
        self.p = subprocess.Popen(["node", SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True, bufsize=1)
        self.n = 0
        self.lines = queue.Queue()
        self.stderr_tail = collections.deque(maxlen=40)
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        for line in self.p.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _read_stderr(self):
        for line in self.p.stderr:
            self.stderr_tail.append(line)

    def _write(self, msg):
        try:
            self.p.stdin.write(json.dumps(msg) + "\n"); self.p.stdin.flush()
        except OSError as e:
            raise MCPError(f"cannot write to the server ({e}); stderr: {''.join(self.stderr_tail)}") from None

    def request(self, method, params=None, timeout=300):
        self.n += 1
        msg = {"jsonrpc": "2.0", "id": self.n, "method": method}
        if params is not None:
            msg["params"] = params
        self._write(msg)
        end = time.time() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.0, end - time.time()))
            except queue.Empty:
                raise MCPError(f"{method}: timeout") from None
            if line is None:
                raise MCPError("server closed stdout; stderr: " + "".join(self.stderr_tail))
            try:
                reply = json.loads(line)
            except json.JSONDecodeError:
                raise MCPError("non-JSON on stdout (protocol violation): " + line[:200]) from None
            if reply.get("id") == self.n:
                if "error" in reply:
                    raise MCPError(f"{method}: {reply['error']}")
                return reply["result"]

    def notify(self, method, params=None):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        self._write(msg)

    def initialize(self, client_name="smoke"):
        """Runs the MCP handshake and returns the server's initialize result."""
        init = self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": client_name, "version": "0"}})
        self.notify("notifications/initialized")
        return init

    def call(self, name, args, timeout=300):
        """Calls a tool and returns (isError, joined text content, image contents)."""
        r = self.request("tools/call", {"name": name, "arguments": args}, timeout)
        texts = [c["text"] for c in r.get("content", []) if c["type"] == "text"]
        images = [c for c in r.get("content", []) if c["type"] == "image"]
        return r.get("isError", False), "\n".join(texts), images

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
