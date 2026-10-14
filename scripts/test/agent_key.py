"""The host side of the agent's host key (docs/agent-protocol.md, "Host key").

The VM's agentKey is the seed of an Ed25519 key; the scripts sign with it through
`alcovectl agent-sign` (ALCOVE_CTL, or the development build in AlcoveKit/.build-ctl),
which reads the VM's config.json in ALCOVE_VM_DIR (default
~/Library/Application Support/Alcove/VMs). agent_key(vm) returns the VM's AgentKey
with its public key and token. first_message(hello, key) returns the auth message
the host sends after the agent's hello: the signature of the VM's token and the
hello's nonce. It raises AgentKeyError with a sentence for a hello without auth or
with another VM's token. check_answer(message) raises AgentKeyError with the
agent's sentence unless the message is authed.
"""
import os, re, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX128 = re.compile(r"[0-9a-f]{128}")

# The sentence for a hello without auth; AgentClient.agentWithoutAuth on the host.
AGENT_WITHOUT_AUTH = ("the guest tools do not ask the host for the VM's key, so the host does not use them; "
                      "reinstall the guest tools from this version of Alcove (scripts/test/install-agent.py)")


class AgentKeyError(Exception):
    pass


def ctl_path():
    return os.environ.get("ALCOVE_CTL") or os.path.join(ROOT, "AlcoveKit", ".build-ctl", "debug", "alcovectl")


def agent_sign(vm, *options):
    """The lines `alcovectl agent-sign --vm vm <options>` prints; AgentKeyError with a sentence when it fails."""
    ctl = ctl_path()
    try:
        done = subprocess.run([ctl, "agent-sign", "--vm", vm, *options], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise AgentKeyError(f"cannot run {ctl} ({e}); build it with `cd AlcoveKit && swift build --product alcovectl "
                            "--scratch-path .build-ctl` or set ALCOVE_CTL") from None
    if done.returncode != 0:
        raise AgentKeyError(done.stderr.strip() or f"{ctl} agent-sign exited with {done.returncode}")
    return done.stdout.split()


class AgentKey:
    """The agentKey of one VM: its public key, its token, and signatures made by alcovectl."""

    def __init__(self, vm, public_key, token):
        self.vm = vm
        self.public_key = public_key
        self.token = token

    def sign(self, nonce):
        """The hex signature of the auth context, the VM's token and nonce (64 hexadecimal digits)."""
        if not isinstance(nonce, str) or not HEX64.fullmatch(nonce):
            raise AgentKeyError(f"the agent's hello carries no nonce of 64 hexadecimal digits ({nonce!r}); reinstall alcove-agent in the guest")
        lines = agent_sign(self.vm, "--nonce", nonce)
        if len(lines) != 1 or not HEX128.fullmatch(lines[0]):
            raise AgentKeyError(f"alcovectl agent-sign printed {lines!r} in place of one signature; rebuild alcovectl")
        return lines[0]


def agent_key(vm):
    """The AgentKey of the VM named vm; AgentKeyError with a sentence when alcovectl cannot read it."""
    lines = agent_sign(vm, "--public-key", "--token")
    if len(lines) != 2 or not HEX64.fullmatch(lines[0]) or not lines[1]:
        raise AgentKeyError(f"alcovectl agent-sign printed {lines!r} in place of a public key and a token; rebuild alcovectl")
    return AgentKey(vm, lines[0], lines[1])


def first_message(hello, key):
    """The auth message that answers hello; AgentKeyError for a hello without auth or with another token."""
    if hello.get("auth") != "key":
        raise AgentKeyError(AGENT_WITHOUT_AUTH)
    if hello.get("token") != key.token:
        raise AgentKeyError(f"the agent's hello carries the token {hello.get('token')!r}, not the agentToken of "
                            f"{key.vm!r}; connect to the agent port of {key.vm!r}")
    return {"t": "auth", "signature": key.sign(hello.get("nonce", ""))}


def check_answer(message):
    """Raises AgentKeyError unless message is the agent's authed line."""
    if message and message.get("t") == "authed":
        return
    if message and message.get("t") == "refused":
        raise AgentKeyError("the agent refused the host: " + str(message.get("error")))
    raise AgentKeyError(f"expected authed after auth, got {message!r}")
