"""The host side of the agent's host key (docs/agent-protocol.md, "Host key").

agent_key(vm) reads the VM's agentKey from its config.json in ALCOVE_VM_DIR (default
~/Library/Application Support/Alcove/VMs). first_message(hello, key) returns the
message the host sends after the agent's hello: pair for an unpaired agent, auth
with the HMAC-SHA256 of the hello's nonce for a paired one, or None for an agent
without key support. check_answer(message) raises AgentKeyError with the agent's
sentence unless the message is authed.
"""
import glob, hashlib, hmac, json, os


class AgentKeyError(Exception):
    pass


def vm_dir():
    return os.environ.get("ALCOVE_VM_DIR") or os.path.expanduser("~/Library/Application Support/Alcove/VMs")


def config_path(vm):
    """The config.json of the bundle whose config names vm, else <vm>.alcovevm/config.json."""
    for path in sorted(glob.glob(os.path.join(vm_dir(), "*.alcovevm", "config.json"))):
        try:
            with open(path, encoding="utf-8") as f:
                if json.load(f).get("name") == vm:
                    return path
        except (OSError, ValueError):
            continue
    return os.path.join(vm_dir(), vm + ".alcovevm", "config.json")


def agent_key(vm):
    """The agentKey of the VM named vm; AgentKeyError with a sentence when there is none."""
    path = config_path(vm)
    try:
        with open(path, encoding="utf-8") as f:
            key = json.load(f).get("agentKey")
    except (OSError, ValueError) as e:
        raise AgentKeyError(f"cannot read {path} ({e}); pass the VM's name with --vm") from None
    if not isinstance(key, str) or len(key) != 64:
        raise AgentKeyError(f"{path} has no agentKey of 64 hexadecimal digits; load the VM once with the current "
                            f"Alcove build (for example `alcovectl agent '{vm}'`), which adds it")
    return key


def first_message(hello, key):
    """The pair or auth message that answers hello, or None for an agent without key support."""
    if hello.get("auth") != "key":
        return None
    if hello.get("paired"):
        mac = hmac.new(bytes.fromhex(key), bytes.fromhex(hello.get("nonce", "")), hashlib.sha256).hexdigest()
        return {"t": "auth", "mac": mac}
    return {"t": "pair", "key": key}


def check_answer(message):
    """Raises AgentKeyError unless message is the agent's authed line."""
    if message and message.get("t") == "authed":
        return
    if message and message.get("t") == "refused":
        raise AgentKeyError("the agent refused the host: " + str(message.get("error")))
    raise AgentKeyError(f"expected authed after pair or auth, got {message!r}")
