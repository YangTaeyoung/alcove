# Alcove guest agent protocol

Version 1, with request/response layer 2. The agent (`alcove-agent`, Go) runs
inside the guest and listens on TCP port 7645. The engine forwards a host
loopback port to it (`hostfwd=tcp:127.0.0.1:<port>-:7645`); the app connects
from the host. Newline-delimited JSON objects in both directions, discriminated
by `t`.

## Who is served

An agent serves a connection only when both of these hold:

1. The peer address is `10.0.2.2`, the address from which QEMU's user-mode
   network delivers the connections it forwards from the host. Each
   `--allow-peer <address or CIDR range>` (repeatable; `--install` passes them
   on to the scheduled task or the systemd unit) adds a range, for tests and
   for guests on another network.
2. The host proved that it holds the VM's agent key by signing the
   connection's nonce and the VM's token ([Host key](#host-key)).

A peer outside the ranges gets one line and the connection closes; it gets no
`hello`:

```
{"t":"refused","error":"alcove-agent serves only connections from 10.0.2.2/32 and this one comes from 127.0.0.1; start alcove-agent with --allow-peer 127.0.0.1/32 to serve it"}
```

The address check is not a boundary on its own. It refuses programs in the
guest that connect to `127.0.0.1` or to the guest's own address. A guest
program that connects to `10.0.2.2:<agent host port>` instead is sent by
QEMU's user-mode network to the host's loopback, where the agent's forward
delivers it back to the agent from `10.0.2.2`. The host port is derived from
the SMBIOS token, which guest programs can read, and the 1000 ports it is
chosen from can be scanned. Every guest program that can reach `10.0.2.2`
therefore passes the address check.

The host key is the trust boundary. The agent runs elevated on Windows (a
scheduled task with the highest run level) and as root on Linux, and every
connection it serves can use every operation its capabilities name: with
`--allow-exec` that is running commands, writing files and starting programs
with the agent's rights. The agent serves only a peer that holds the VM's
agent key; on the host that is every process that can read the VM's
`config.json` and connect to the forwarded loopback port. An agent that
found no host key in SMBIOS serves nobody. A range given with
`--allow-peer` adds every program at those addresses to the peers that pass
the address check; they still have to prove the key.

## Handshake

Agent → host on connect:

```
{"t":"hello","v":1,"proto":2,"os":"windows"|"linux","agent":"0.2.1","token":"<uuid>","caps":["files","shutdown","resolution","clipboard","exec","rpc","jobs","proc","fs","ui"],"auth":"key","nonce":"<64 hex digits>"}
```

`token` is read by the agent from the SMBIOS OEM strings (type 11) that the
engine passes with `-smbios type=11,value=alcove-token=<uuid>`. The app
compares it with the token stored in the VM's `config.json` and drops the
connection on mismatch. The token names the VM and is not a secret: guest
programs can read the SMBIOS strings. The host's signature covers it
([Host key](#host-key)).

The host then sends `auth` ([Host key](#host-key)) and waits for `authed`;
it then sends `{"t":"welcome","v":1}` and the connection is ready. The host
refuses a hello without `auth: "key"`.

`v` stays 1. `proto` is the revision of the request/response layer described
under [Requests and responses](#requests-and-responses); an agent without the
field has none, and the host then uses only the messages of the next section.

Capabilities:

| `caps` entry | Present when | Meaning |
|---|---|---|
| `files`, `shutdown` | always | `file.*`, `shutdown` |
| `resolution` | Windows agents | `resolution.set` |
| `clipboard` | the guest has a usable clipboard: on Linux a [desktop session](#the-desktop-session-linux) whose display has its tool (`wl-paste` and `wl-copy` for Wayland, `xclip` for X11) | `clipboard.*` |
| `exec` | started with `--allow-exec` | the v1 `exec` message |
| `rpc` | always (agents with `proto` 2) | `req` / `res` / `ev` |
| `jobs`, `proc`, `fs` | started with `--allow-exec` | `exec.*`, `proc.*`, `fs.*`, `app.launch` and `session.info` operations |
| `ui` | Windows agents | `win.*` and `ui.*` operations and the window events |

The hello carries the list the agent found last. The agent checks its
capabilities once when it starts serving, before it accepts a connection,
so a hello does not wait for a check; a connection that arrives during that
first check is accepted after it. From then on it checks them every 5 s,
whether or not a connection is open, so the list of a hello is at most 5 s
old. On Linux a check looks up the desktop session, so a hello does not wait
for `loginctl`.

When the host has sent its first message after the handshake (its
`welcome`, or a request), the agent checks its capabilities and, when they
differ from the hello's, sends `{"t":"caps","caps":[…]}` with the whole new
list before it handles that message; the list replaces the hello's. Events
can come before that line. After each check of every 5 s the agent sends
the same line to each open connection whose host has sent that first
message and whose last list differs. On Linux this is how `clipboard`
appears once a user signs in to the desktop after the host connected, as an
autologin does a few seconds after the agent starts at boot, and disappears
when the session ends.

A host of Alcove 0.2.0 ignores the `caps` line: it keeps the hello's list
for the whole connection. With such a host, a capability that appears or
goes after the hello (on Linux `clipboard` at a sign-in that follows the
connection) is seen only on the next connection, whose hello is at most
5 s old.

### The desktop session (Linux)

The Linux agent is a root system service (`alcove-agent --install` writes the
systemd unit `alcove-agent.service`). It finds the desktop session with
`loginctl list-sessions` and `loginctl show-session`: of the sessions of
class `user` that are not closing, the active graphical session (type
`wayland`, `x11` or `mir`) of `seat0`, else the only graphical one, else the
active session of `seat0`, else the one that began first. The user's home
directory and groups come from the user database. A lookup is reused for
5 s.

- The home directory of the agent's paths is that user's: `~`, `~/x`,
  relative paths, the `cwd` of `exec.*` and `app.launch`, the working
  directory of `exec.*` without `cwd`, the `Desktop` and `Downloads` folders
  of `file.begin` and the folders `fs.delete` refuses. Without a session, and
  for a session user whose home is not an absolute path or is `/`, it is the
  agent's own home directory (`/root`), and the home rules below do not
  apply. One request reads the session once and uses that home throughout.
- What changes entries in that home — `file.begin`, `fs.write`, `fs.mkdir`,
  `fs.rename`, `fs.delete`, and so the transfers, `vm.sync_dir` and
  `vm.deploy` of the host — opens the home as one `os.Root` and works
  relative to it. A link with a relative target that stays inside the home is
  followed. A link with an absolute target, even one inside the home, is not:
  the operation fails with
  `'<link>' is a link with the absolute target '<target>', and the agent follows only relative links inside the home folder of the desktop user; make it a relative link or pass the path it leads to`
  for a target inside the home, and with
  `'<link>' is a link with the absolute target '<target>' outside the home folder of the desktop user, which the agent does not follow there; pass the path it leads to`
  for one outside it.
  A path that leads out of the home through a relative link (`~/Downloads` →
  `../../etc`) fails with
  `the path leads out of the home folder of the desktop user through a link, which the agent does not follow there; pass the path the link leads to`.
  Both come after the operation's own beginning
  (`cannot open '<path>' for writing: `, …), and nothing outside the home is
  touched. An existing file that has other hard links and does not belong to
  the session's user is not written:
  `it has other hard links and does not belong to <user>, so it may be a file outside the home folder of the desktop user; write to that file's own path`
  (checked before it is truncated). Files the agent creates there are given to
  the session's user and its primary group through their open descriptors,
  folders by a chown of the folder itself that does not follow a link, each
  with the mode it was created with; entries that existed keep their owner.
  `fs.rename` from inside the home to outside it or back answers
  `'<from>' and '<to>' lie on different sides of the home folder of the desktop user; rename within it or outside it, or copy the file`.
  Paths outside the home are changed as root, as on other systems.
  When the home does not exist, those operations, `fs.mkdir` of the home
  itself included, fail with
  `the home folder '<home>' of the desktop user <user> does not exist; create it with exec.run (mkdir '<home>' && chown <user>: '<home>'), then retry`;
  when it cannot be opened for another reason, with
  `cannot open the home folder '<home>' of the desktop user: <reason>; check it with exec.run (ls -ld '<home>'), then retry`.
- `app.launch` and the clipboard tools run as that user (its user id, group
  id and groups), in a session of their own, with the session's environment:
  `HOME`, `USER`, `LOGNAME`, the agent's `PATH`,
  `XDG_RUNTIME_DIR=/run/user/<uid>` when that folder exists,
  `WAYLAND_DISPLAY` (the `wayland-0` socket in it, else the first other
  `wayland-<n>`) for a Wayland session, `DISPLAY` when logind names the
  session's display, `DBUS_SESSION_BUS_ADDRESS` when the folder holds `bus`,
  `XDG_SESSION_TYPE`, and the `LANG`, `LANGUAGE` and `LC_*` variables of
  `/etc/default/locale` (else `/etc/locale.conf`, else the agent's own). `env`
  of `app.launch` is added to that environment.
- When the runtime folder holds `bus` and `systemd-run` exists and reports
  systemd 254 or later (`systemd-run --version`, kept once read; a failed read is logged once and tried again after a minute), and the
  program is an executable file (a relative path is looked up in the
  launch's working directory), `app.launch`
  and the clipboard writer (`wl-copy`, `xclip -i`, which keep running to hold
  the text) start through
  `systemd-run --user --scope --quiet --collect --expand-environment=no --`:
  they run in a scope of the user's service manager, keep the process id the
  agent reports, and are not ended when the agent's service stops or
  restarts. Otherwise they run in the agent's service and end with it.
- `exec.*` keeps the agent's identity: the commands run as root with the
  agent's environment, in which `HOME` is root's home directory when systemd
  started the agent without one.
- Without a session `app.launch` runs as the agent with its environment, and
  the clipboard is the one the agent's own `WAYLAND_DISPLAY` or `DISPLAY`
  names, if any.
- A clipboard tool that has not finished after 5 s is killed with its process
  group; a read then fails (`clipboard.text` carries `""`) and a write is
  dropped, both logged. A read that fails is not a change of the clipboard:
  a reader that exits with a non-zero code (the tools do for an empty
  clipboard; `clipboard.text` then carries what it printed, `""`), does not
  finish or does not start leaves the watcher with the text it read last, so
  the next good read of the same text sends no `clipboard.changed`. The
  agent keeps at most 700000 bytes of the clipboard, cut on a character
  boundary.

`alcove-agent --install` on Linux writes the running program to a temporary
file in `/usr/local/bin`, flushes it to disk and renames it over
`/usr/local/bin/alcove-agent`, which works while the old agent runs from that
file; it then writes the unit and runs `systemctl daemon-reload`,
`systemctl enable alcove-agent` and `systemctl restart alcove-agent`. It
prints `installed` only after every step succeeded. A step that fails ends
the install with exit code 1, a line on stderr that begins
`install failed: ` and the same line in `/var/log/alcove/install.log`:
`the path of the running alcove-agent cannot be read (<reason>); run it by its full path`,
`cannot read <file> (<reason>); run alcove-agent --install from a copy you can read`,
`cannot replace /usr/local/bin/alcove-agent (<reason>); check with sudo that /usr/local/bin is writable and that /usr/local/bin/alcove-agent is not immutable (lsattr /usr/local/bin/alcove-agent; chattr -i removes the flag), then run alcove-agent --install again`,
`cannot write /etc/systemd/system/alcove-agent.service (<reason>); run alcove-agent --install as root` or
`systemctl <step> failed (<error>: <output>); check journalctl -u alcove-agent, then run alcove-agent --install again`.
Run it from ssh or a terminal: the restart also ends a command that the
agent started.

## Host key

The host keeps one Ed25519 private key per VM: `agentKey` in the VM's
`config.json`, the 32-byte seed of the key (RFC 8032) written as 64
lower-case hexadecimal digits of random bytes. Every 32 bytes are a seed, so
every stored `agentKey` of 64 hexadecimal digits is used as it is. The app
creates it with the VM, and adds it to the `config.json` of a VM created
before the field existed when it first loads that file; a stored key is
never replaced by a save. Every VM has its own key and its own `agentToken`:
a linked clone gets a new key and a new token when it is created. The
private key never leaves the host.

**Where the agent gets the public key.** The engine passes the public key to
the guest as a second SMBIOS OEM string (type 11), next to the token:

```
-smbios type=11,value=alcove-token=<agentToken>
-smbios type=11,value=alcove-hostkey=<public key, 64 lower-case hexadecimal digits>
```

QEMU puts both values into one type 11 structure. The agent reads the
SMBIOS table once at start (Windows: `GetSystemFirmwareTable('RSMB')`;
Linux: `/sys/firmware/dmi/tables/DMI`) and keeps the token and the public
key in memory; it stores no key on disk. A program in the guest can read the
strings but cannot change them: they are set by the host when the VM starts.
`--token` replaces the SMBIOS token; there is no option that replaces the
host key.

An agent whose SMBIOS strings lack `alcove-hostkey` (a VM started by Alcove
before 0.2, or by QEMU without the string), whose `alcove-hostkey` is not 64
hexadecimal digits, or that has no token serves nothing. It answers every
connection that passes the address check with one line instead of the hello,
and the connection closes:

```
{"t":"refused","error":"this alcove-agent serves nothing because the VM's SMBIOS strings lack alcove-hostkey or alcove-token; start the VM with Alcove 0.2 or later"}
```

**Hello fields.** The agent adds to its hello:

| Field | Value |
|---|---|
| `auth` | `"key"` |
| `nonce` | 64 lower-case hexadecimal digits: 32 random bytes from `crypto/rand`, new for every connection |

**Host → agent.** The host's first message after the hello is

```
{"t":"auth","signature":"<128 lower-case hexadecimal digits>"}
```

`signature` is the Ed25519 signature (RFC 8032, pure Ed25519) by the VM's
`agentKey` of this message:

| Bytes | Content |
|---|---|
| 20 | the ASCII bytes `alcove-agent-auth-v2` |
| any | the VM's `agentToken` as UTF-8 (on the host: the token in `config.json`, which it compared with the hello's `token` first; in the agent: its SMBIOS token) |
| 32 | the hello's `nonce`, hex-decoded |

The nonce has a fixed length at the end, so the token is the part between
the context and the nonce. The agent verifies the signature with the public
key from SMBIOS (`crypto/ed25519`). A signature answers one nonce of one VM:
it is refused on another connection, by an agent with another token (another
VM, a clone of the same template) and by an agent with another public key.
The host may sign with random per-signature data (CryptoKit does); every
valid signature is accepted.

The host refuses a hello without `auth: "key"`. Such an agent was built
before this version and does not check the host; the host sends nothing to
it, closes the connection and reports
`the guest tools do not ask the host for the VM's key, so the host does not use them; reinstall the guest tools from this version of Alcove (scripts/test/install-agent.py)`
as a refusal by the host (`the guest tools in '<vm>' cannot be used:
<sentence>` in control replies and vm.status `toolsRefused`, the app's
"Tools not used" label). The scripts that speak the protocol refuse it with
the same sentence.

Scripts that speak the protocol sign through the host's `alcovectl`:
`alcovectl agent-sign --vm <name> --nonce <hex>` prints the signature of
that nonce under the VM's token; `--public-key` adds the public key and
`--token` adds the VM's `agentToken`, one per line in that order
(signature, public key, token). It reads the `agentKey` and `agentToken` of
the VM whose `config.json` has that `name` in the VM folder (`--dir`,
`ALCOVE_VM_DIR`, or `~/Library/Application Support/Alcove/VMs`). A script
compares the hello's `token` with the printed token before it signs.

**Agent → host.** The agent answers with one line:

- `{"t":"authed"}`: the connection is served from now on.
- `{"t":"refused","error":"<sentence>"}`, and the connection closes.

Until `authed` the agent sends nothing else: no keepalive, no events, no
`clipboard.changed`, no `resolution`. It ignores `welcome`, `ping` and `pong`
and empty lines. Any other message, `pair` of earlier hosts included, and a
line that is not a JSON object with a string `t` get the refusal
`this alcove-agent serves only a host that proves the VM's key; update the Alcove app on the host`
at once and the connection closes. Before that line a `req` is answered with a `res`
that carries the sentence as `error`, an `exec` with an `exec.result` of
`code` -1 that carries it as `out`, and a `file.end` with a `file.done` that
carries it as `error`, so a host without key support shows the sentence.

The other refusals before `authed`:

| Case | `error` |
|---|---|
| `auth` with a wrong or malformed `signature` | `the host's signature does not match this VM's alcove-hostkey and alcove-token; restart the VM with Alcove so the guest reads the key and token in its config.json` |
| no `auth` within 10 s of the hello | `no auth message arrived within 10 s; the host authenticates right after the hello` |
| a line longer than 64 KiB before `authed` | `a line before auth is longer than 65536 bytes; the host sends only auth before authed` |
| the connection was the oldest of 16 between their hello and `authed` when another one connected | `this connection was closed for a newer one because 16 connections were authenticating; the host authenticates right after the hello` |
| no random nonce could be read | none: the connection closes after a log line |
| the connection fails before `authed` (a reset, for example) | none; the failure is written to the log like a refusal |

**What it does not prevent.** The host authenticates to the agent; the
agent does not authenticate to the host. A guest program that listens on
port 7645 while the agent is not running (see [Listening](#listening))
receives the host's requests. The signatures it receives answer its own
nonces under this VM's token: no agent of another VM accepts them, and the
agent of this VM accepts none of them, because every connection to it has a
new nonce.

The agent keeps at most 16 connections between their hello and `authed`; a
new connection closes the oldest of them, and each has 10 s to send `auth`.
A guest program that opens connections faster than the host completes its
handshake (one round trip) can still close the host's pending handshake, and
the host then connects again; the agent does not tell such a program from
the host before its signature arrives.

**Agent log.** The agent writes a served connection to its log as
`connection from <address>` once it is served (after `authed`), and a
refused one as `refused the connection from <address>: <sentence>`. Each
reason of a refusal (the address check, a missing host key, a wrong
signature, a message other than `auth`, the 10 s deadline, a long line,
the handshake limit, a connection that failed before `authed`) is written at most once per minute, with the address
and sentence of the connection it writes; refusals for the address check
from different addresses count as one reason. The next line written for a
reason ends with `(<n> more refused for this reason since the last line)`
when connections were refused for it in between.

## Listening

The agent listens on `0.0.0.0:<port>` (7645 unless `--port` is given). On
Windows the socket is bound with `SO_EXCLUSIVEADDRUSE`, so no other program
can bind the same port on a specific address of the guest while the agent
holds it. When the port cannot be bound (another program holds it), the
agent logs `listen on 0.0.0.0:<port> failed (<system error>); trying again in <n> s`
and tries again after 1 s, then after twice the previous pause, up to 5 s
between attempts, until the bind succeeds.

## Messages

| Direction | `t` | Fields | Meaning |
|---|---|---|---|
| agent → host | `refused` | `error` | the last line to a peer that is not served ([Who is served](#who-is-served), [Host key](#host-key)); the connection closes |
| host → agent | `auth` | `signature` | prove the VM's key ([Host key](#host-key)) |
| agent → host | `authed` | — | the `auth` succeeded; the connection is served |
| both | `ping` / `pong` | — | keepalive every 10 s |
| agent → host | `caps` | `caps` | the capabilities changed; the list replaces the hello's ([Handshake](#handshake)) |
| host → agent | `clipboard.set` | `text` (string) | put text on the guest clipboard |
| host → agent | `clipboard.get` | `id` (optional) | ask for the current text; answered with `clipboard.text` |
| agent → host | `clipboard.text` | `text`, `id` (the `clipboard.get`'s, when it carried one), `error` (when the get was not run) | reply to `clipboard.get`; text longer than 700000 bytes of UTF-8 is cut to that size on a character boundary |
| agent → host | `clipboard.changed` | `text` | the guest clipboard changed (text only in v1; one watcher per agent polls while a connection is open: on Windows the clipboard sequence number every 0.4 s; on Linux it runs `wl-paste` or `xclip -o` 0.5 s after a change and then at twice the interval after each poll that found none, up to every 4 s; a change the agent made itself is not reported); text longer than 700000 bytes of UTF-8 is cut to that size on a character boundary |
| host → agent | `resolution.set` | `w`, `h` | ask the guest to switch its primary display mode (agents with the `resolution` capability; others log the request and ignore it) |
| agent → host | `resolution` | `w`, `h` | current primary display mode (sent after hello and on change) |
| host → agent | `file.begin` | `id`, `name`, `size`, `dest` ("desktop"/"downloads") | start a file push into the `Desktop` or `Downloads` folder of the home directory (on Linux the [desktop session](#the-desktop-session-linux)'s); the file of a push that the connection leaves unfinished is removed |
| host → agent | `file.chunk` | `id`, `data` (base64, ≤ 256 KiB decoded) | file bytes |
| host → agent | `file.end` | `id`, `sha256` | finish; the agent verifies the digest |
| agent → host | `file.done` | `id`, `path` or `error` | result |
| host → agent | `shutdown` | — | graceful OS shutdown (`shutdown.exe /s /t 0` of the System32 folder or `systemctl poweroff`); the UI helper is closed only after that command succeeded |
| host → agent | `exec` | `cmd` (string) | run a command with the default shell and no time limit; answered with `exec.result` (`code` -1 and `out` "exec disabled" unless the agent was started with `--allow-exec`) |
| agent → host | `exec.result` | `code`, `out` | exit code and combined stdout and stderr of `exec`; `out` keeps the last 200000 bytes, starting on a character boundary when older bytes were dropped (there is no `truncated` field) |

`clipboard.get` and `clipboard.set` of one connection run one after another
in the order they arrived, apart from the connection's other messages, so a
clipboard that does not answer delays neither `pong` nor requests. Each
`clipboard.get` gets one `clipboard.text`, in the order of the gets. A
connection holds at most 64 clipboard operations waiting; one more
`clipboard.get` is answered at once with `"text":""` and the `error`
`64 clipboard operations of this connection are waiting for the guest's clipboard tool; retry once it answers`,
and one more `clipboard.set` is dropped and logged. The host sends an `id`
with each `clipboard.get` and takes a `clipboard.text` only as the reply of
the get with that `id`, so a reply that arrives after the host stopped
waiting is not taken for a later get; a reply without `id` (agents before
0.2.1) goes to the oldest get.

Unknown `t` values are ignored, and after `authed` so is a line that is not
a JSON object with a string `t`. Strings are UTF-8; the guest clipboard is
converted from/to UTF-16 on Windows by the agent.

## Requests and responses

```
host → agent   {"t":"req","id":7,"op":"exec.run","cmd":"hostname"}
agent → host   {"t":"res","id":7,"ok":true,"code":0,"stdout":"alcove-win\r\n","stderr":"","timed_out":false,"truncated":false}
agent → host   {"t":"res","id":8,"ok":false,"error":"no job 'j9'; call exec.list"}
agent → host   {"t":"ev","name":"job.exited","job":"j3","code":0}
```

- A request carries its parameters next to `t`, `id` and `op`. The reply
  repeats `id` unchanged and carries the result fields next to `ok`, or
  `ok: false` and `error`, a sentence that names the next step.
- Requests on one connection run at the same time; replies arrive in the
  order the operations finish. The host matches them by `id`.
- An unknown `op` answers `unknown op '<op>'; update alcove-agent`.
- A `req` without `id` (or with `id: null`) is not run; it answers
  `{"t":"res","id":null,"ok":false,"error":"the request has no id; give every req an id to match its answer"}`.
- The `exec.*`, `proc.*` and `fs.*` operations, `app.launch` and `session.info` answer
  `exec disabled; start alcove-agent with --allow-exec` unless the agent was
  started with `--allow-exec`. `ping`, `win.*` and `ui.*` do not need it.
- `ev` messages are not replies. They go to every open connection. The events
  are `job.exited` ([Jobs](#jobs-execstart-execread-execwrite-execkill-execlist)),
  `process.exited` ([App launch](#app-launch-applaunch)), the window events
  ([Window events](#window-events)) and `events.dropped` (a connection's event
  queue overflowed; it carries only `count`, the number of events dropped at
  that place in the stream).

### Operations

| `op` | Params | Result |
|---|---|---|
| `ping` | — | `pong` (true) |
| `exec.run` | `cmd` (string) or `argv` ([string]); `shell` (`powershell`, `cmd`, `sh`, `none`); `cwd`; `env` (object of strings); `stdin` (string); `timeout_ms` (default 120000) | `code`, `stdout`, `stderr`, `timed_out`, `truncated` |
| `exec.start` | `cmd` or `argv`, `shell`, `cwd`, `env` as for `exec.run` | `job` (string), `pid` |
| `exec.read` | `job`; `out_offset`, `err_offset` (default 0); `max` (bytes per stream, default and cap 262144) | `state` (`running`/`exited`), `code` (when exited), `pid`, `out`, `err`, `out_next`, `err_next`, `dropped` |
| `exec.write` | `job`, `data` (string), `eof` (bool) | — |
| `exec.kill` | `job` | `state` |
| `exec.list` | — | `jobs`: [{`job`, `pid`, `state`, `code` (when exited), `cmd`, `started` (RFC 3339)}] |
| `proc.list` | `name` (case-insensitive substring of the process name) | `procs`: [{`pid`, `ppid`, `name`, `path`, `cmd`, `mem_kb`}] |
| `proc.kill` | `pid`, or `name` (exact process name); `tree` (bool) | `killed` (int) |
| `fs.stat` | `path`; `sha256` (bool) | `exists`, `path` (absolute); for an existing entry also `dir`, `size`, `mtime` (RFC 3339, UTC), and `sha256` when asked for a file; `link: true` when the entry at `path` is a link; `owner` on Windows; `locked` for the deploy root on Windows |
| `fs.list` | `path`; `recursive` (bool); `sha256` (bool) | `entries`: [{`name` (relative, `/` separators), `dir`, `size`, `mtime`, `sha256`, `link`, `executable` (outside Windows, for regular files: the owner's execute bit)}], `truncated` (more than 5000 entries), `skipped` (entries that could not be read, when above 0) |
| `fs.read` | `path`, `offset` (default 0), `length` (default and cap 262144) | `data` (base64), `size` (of the file), `eof`, `encoding` |
| `fs.tail` | `path`, `lines` (default 200) | `data` (base64 of the last lines, taken from at most the last 262144 bytes), `size`, `encoding` |
| `fs.write` | `path`, `data` (base64), `offset` (default 0), `truncate` (bool), `append` (bool), `mkdirs` (bool), `executable` (bool; outside Windows `true` adds the execute bit wherever the file has the read bit and `false` removes every execute bit; Windows ignores it; when the mode cannot be changed after the data was written: `cannot set the execute bits of '<path>': <reason>; the data is written, so set them with exec.run (chmod)`) | `size` (of the file afterwards) |
| `fs.rename` | `from`, `to`, `overwrite` (bool) | `path` |
| `fs.mkdir` | `path` | `path` |
| `fs.delete` | `path`, `recursive` (bool) | `deleted` (bool) |
| `app.launch` | `path`; `args` ([string]); `cwd`; `env` (object of strings); `wait_window_ms` (default 15000, 0 skips the wait, cap 300000) | `pid`, `window` (a window object, when a window was found) |
| `session.info` | — | on Linux the [desktop session](#the-desktop-session-linux): `session` (logind id), `user`, `uid`, `home`, `type` (`wayland`, `x11`, `tty`, …), `locked` (logind `LockedHint`); no fields without a session. Windows agents do not know the op |
| `win.list` | — | `windows`: [window object] |
| `win.action` | `window`, `action` (`focus`, `minimize`, `maximize`, `restore`, `close`, `move`, `resize`); `x`, `y` for `move`; `w`, `h` for `resize` | `window` (after the action, `null` when it is gone); `closed` (bool, for `close`) |
| `ui.tree` | `window` (default `foreground`), `root` (ref), `depth` (default 12, at most 256), `max` (default 300, cap 2000), `filter` (`interactive` default, `all`) | `window`, `nodes`, `truncated` |
| `ui.find` | selector fields, `limit` (default 20, cap 2000) | `nodes` (depth 0); `truncated: true` when the search ended early |
| `ui.text` | `ref` or selector fields, `mode` (`auto` default, `pattern`, `descendants`), `offset`, `length` (default and cap 200000; 0 returns `total` alone) | `text`, `total`, `source` (`text`, `value`, `name`, `descendants`) |
| `ui.rect` | `ref` or selector fields, `scroll` (bool) | `node`, `cx`, `cy`, `clickable`; `blocked` (a sentence, when not clickable) |
| `ui.act` | `ref` or selector fields, `action` (`invoke`, `toggle`, `expand`, `collapse`, `select`, `set_value`, `focus`, `scroll_into_view`), `value` (for `set_value`) | `node`; `unresponsive: true`, `gone: true` or `pending: true` when the node could not be read after the action |
| `ui.focused` | — | `node`, `window` |
| `ui.at` | exactly one of `x` and `y`, `ref`, `focused: true`; `budgetMs` (default 250, 50–2000) | `node`, `window` (`id`, `title`), `byAutomationId`, `byName` |
| `ui.ping` | — | `pong`, `pid`, `session`, `integrity`, `dpi`, `clr`, `refs` |

### Commands (`exec.run`, `exec.start`)

- With `argv` the program `argv[0]` starts directly with the remaining
  elements as arguments. `shell` is then left out or `none`; another `shell`
  answers `shell '<shell>' does not run argv; pass shell 'none' or leave shell out`,
  and `cmd` together with `argv` answers `pass cmd or argv, not both`.
  `shell: "none"` without `argv` is an error.
- With `cmd` the text runs through `shell`; the default is `powershell` on
  Windows and `sh` elsewhere:

  | `shell` | Command line |
  |---|---|
  | `powershell` (Windows only) | `<System32>\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Restricted -Command "<prefix><cmd>"` with the prefix `$env:PSModulePath = $PSHOME + '\Modules'; [Console]::InputEncoding=[Text.UTF8Encoding]::new($false); [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; ` (see [Windows PowerShell](#windows-powershell)) |
  | `cmd` (Windows only) | `<System32>\cmd.exe /D /S /C "<cmd>"`, passed to the process verbatim, so `cmd.exe` runs neither `AutoRun` command (the `AutoRun` value of `Software\Microsoft\Command Processor` under `HKLM` and under `HKCU`), removes exactly the outer quotes and runs `<cmd>` as typed |
  | `sh` | `/bin/sh -c <cmd>` |

- `cwd` is the working directory; `~`, `~/x` and relative paths resolve
  against the home directory of the agent's user (on Linux the
  [desktop session](#the-desktop-session-linux)'s user; on Windows the
  profile folder of the agent's account, read as described in
  [Environment of a command on Windows](#environment-of-a-command-on-windows),
  never from `USERPROFILE`), which is also the working directory without
  `cwd`. The command runs as the agent's user (root on Linux) and `env` adds
  variables to its environment: on Windows the
  [environment of a command](#environment-of-a-command-on-windows), elsewhere
  the agent's environment.
- On Windows every child starts with `CREATE_NO_WINDOW`: it has no console
  window, and a GUI program started directly shows its own windows.
- `exec.run` gives the child a pipe that carries the `stdin` text and then
  ends; without the field the child reads end-of-file at once. It waits for
  the child, at most `timeout_ms`. On timeout the process tree is killed,
  `timed_out` is true and `code` is -1. When the connection of the request
  closes first, the process tree is killed too and no reply is sent.
- `exec.run` keeps the last 200000 bytes of each stream; `truncated` is true
  when either stream lost earlier bytes. A character split by the cut is
  dropped, so a truncated stream starts on a character boundary. Other
  invalid UTF-8 becomes U+FFFD.
- Killing a tree (timeout, `exec.kill`, `proc.kill` with `tree`) runs
  `taskkill /F /T /PID <pid>` (`taskkill.exe` of the System32 folder, in the
  environment of the system folders that a recipe of
  [Windows PowerShell](#windows-powershell) gets) on Windows; elsewhere each child leads its own
  process group and the group receives SIGKILL. `taskkill` follows parent
  process ids, so on Windows a process whose parent had already exited (for
  example a server started by `cmd /c start /b`) is not part of the tree and
  keeps running; stop it with `proc.kill` by `pid` or `name`.

#### Environment of a command on Windows

The processes the agent starts on Windows for the host (`exec.run`,
`exec.start`, the v1 `exec` and `app.launch`) do not get the agent's own
environment, and so not the desktop user's `HKCU\Environment`, which an
unelevated program of that user can change (`COR_PROFILER`,
`DOTNET_STARTUP_HOOKS`, the user's `PATH` entries and the like). Each one
starts with an environment the agent builds when the request arrives:

- The machine's variables: the `REG_SZ` and `REG_EXPAND_SZ` values under
  `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, such
  as `PATHEXT`, `ComSpec`, `OS`, `NUMBER_OF_PROCESSORS`, `PROCESSOR_*` and
  `PSModulePath`. A `REG_EXPAND_SZ` value is expanded only from the system
  folders that [App launch](#app-launch-applaunch) names (`%SystemRoot%`,
  `%SystemDrive%`, `%windir%`, `%ProgramFiles%` and the like); a value that
  names any other variable is left out. `Path` keeps, in order, the folders
  that expand that way and start with a drive, the folders `app.launch`
  searches.
- Values the account cannot change as variables, which replace a machine
  value of the same name: `USERNAME` and `USERDOMAIN` of the account of the
  agent's token, `COMPUTERNAME` (`GetComputerNameW`); `USERPROFILE`,
  `HOMEDRIVE` and `HOMEPATH` of the account's profile folder, the
  `ProfileImagePath` of its SID under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList` expanded
  from the system folders; `APPDATA` (`<profile>\AppData\Roaming`),
  `LOCALAPPDATA` (`<profile>\AppData\Local`), `TEMP` and `TMP`
  (`<profile>\AppData\Local\Temp`); `ProgramData` (the `ProgramData` value
  of that key); `SystemRoot`, `windir`, `SystemDrive`, `ProgramFiles`,
  `ProgramFiles(x86)`, `ProgramW6432`, `CommonProgramFiles`,
  `CommonProgramFiles(x86)` and `CommonProgramW6432` of the system folders.
- The request's `env` after it: a name given there replaces one of the same
  name without regard to case.

Folder redirection of `AppData`, the user's own variables and `PATH`
entries (such as `%LOCALAPPDATA%\Microsoft\WindowsApps`, which holds app
execution aliases like `winget.exe`), `OneDrive`, `PUBLIC`,
`ALLUSERSPROFILE`, `LOGONSERVER` and `SESSIONNAME` are not part of it, and
neither is a `PSModuleAnalysisCachePath` other than the machine's: pass what
a command needs with `env`, or the full path of a program. A change an
installer makes to the machine's variables reaches the next command without
a restart of the agent.

A bare `argv[0]` (without `\`, `/` or `:`) is looked up in the folders of
the `PATH` of that environment, `env` included, that start with a drive and
a backslash or with `\\`, in order: the name itself when it has an
extension, then the name with each extension of its `PATHEXT` (`.com`,
`.exe`, `.bat`, `.cmd` without one). The working directory is not searched.
A name found in none answers
`'<name>' is not in a folder of the command's PATH (the machine's PATH, or PATH of env); pass the full path of the program`.
`shell: "cmd"` runs `cmd.exe` of the System32 folder (with `/D`, see above)
of the Windows folder that Windows reports (`GetSystemWindowsDirectoryW`);
when that folder cannot be read the request answers
`cmd.exe could not be located (<reason>); restart alcove-agent and retry`.

When the environment cannot be built the request answers
`the system folders could not be read (<reason>); restart alcove-agent and retry`,
`the machine's environment variables could not be read (<reason>); restart alcove-agent and retry`,
`the account of alcove-agent could not be read (<reason>); restart alcove-agent and retry`
or
`the profile folder of alcove-agent's account could not be read (<reason>); check the ProfileImagePath value of HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\<SID>, then retry`.

The home directory of the agent's user is the same profile folder. The
agent's own processes take nothing of its environment either:
`taskkill.exe`, `shutdown.exe` and the recipes of
[Windows PowerShell](#windows-powershell) get the environment of the system
folders below, and the UI helper gets its own
([Windows and UI Automation](#windows-and-ui-automation-win-ui)).

#### Windows PowerShell

The agent runs Windows PowerShell for `shell: "powershell"` (also the v1
`exec` message) and for its own recipes (the process list of `proc.list`)
the same way:

- The program is `powershell.exe` in `WindowsPowerShell\v1.0` of the
  System32 folder of the Windows folder that Windows reports
  (`GetSystemWindowsDirectoryW`), not one found through `PATH`. When that
  folder cannot be read the request answers
  `Windows PowerShell could not be located (<reason>); restart alcove-agent and retry`.
- `-NoProfile`: no profile script runs.
- `-ExecutionPolicy Restricted`: commands run, script files do not, so a
  `.ps1` file or a script module (`.psm1`) does not run whatever execution
  policy a user of the guest set for themselves. To run a script file on
  purpose, start `powershell.exe -ExecutionPolicy Bypass -File <path>` from
  the command.
- Modules load by command name only from Windows PowerShell's own module
  folder, `<System32>\WindowsPowerShell\v1.0\Modules`: `PSModulePath` in the
  new process's environment is that folder (or the value `env` of the request
  gives), and the first statement of every `-Command` sets it to
  `$PSHOME\Modules`. A module in the user's
  `Documents\WindowsPowerShell\Modules`, in
  `Program Files\WindowsPowerShell\Modules`, or in a folder that a
  `PSModulePath` of the agent's environment or of `env` names is not loaded by
  a command name. The command can load one with `Import-Module <path>` (a
  script module only under a policy that allows scripts) or set
  `$env:PSModulePath` itself.
- `shell: "powershell"` gets the
  [environment of a command](#environment-of-a-command-on-windows) with that
  `PSModulePath`, and the request's `env` added after it. A recipe of the
  agent gets an environment of the system folders only: `SystemRoot`,
  `windir`, `SystemDrive`, `ComSpec`, `PATH` of the System32 folder, the
  Windows folder, `Wbem` and Windows PowerShell's folder, and that
  `PSModulePath`.
- A `powershell.exe` that a `shell: "powershell"` command starts itself
  inherits that command's environment: the Process-scope execution policy
  `Restricted` (`-ExecutionPolicy` sets it through
  `PSExecutionPolicyPreference`, which applies to the session and its child
  sessions) and the `PSModulePath` of Windows PowerShell's own module folder.
  It gets neither `-NoProfile` nor the reset of `PSModulePath` as its first
  statement; pass `-NoProfile` to it when its profile must not run.
- A `powershell.exe` started through `argv` or through `shell: "cmd"` gets
  the [environment of a command](#environment-of-a-command-on-windows), with
  the machine's `PSModulePath`, and none of the above: no `-NoProfile`, no
  Process-scope policy and no reset of `PSModulePath`.

### Jobs (`exec.start`, `exec.read`, `exec.write`, `exec.kill`, `exec.list`)

- A job belongs to the agent process, not to a connection: it keeps running
  when the host disconnects and any connection can read it by id (`j1`,
  `j2`, …). Restarting the agent empties the table.
- A job keeps the last 1 MiB of each stream. `out_offset` and `err_offset`
  count bytes since the job started. `exec.read` returns up to `max` bytes per
  stream from the given offsets and the offsets to pass next. A read below the
  retained window starts at the oldest retained byte and sets `dropped`. A
  piece does not end inside a UTF-8 sequence; the bytes of an unfinished
  sequence come with the next read. Only the read that reaches the end of an
  exited job's output returns the bytes as they are. A `max` below 4 counts
  as 4, so every read can carry a whole character.
- The job's stdin stays open. `exec.write` writes `data` and, with `eof`,
  closes it; it fails for an exited job, for a closed stdin, and after 10 s
  when the job does not read
  (`job '<id>' is not reading its input; the data may still reach it later, so exec.kill it or wait before writing again`).
- `exec.kill` kills the job's process tree, waits up to 5 s for the exit and
  answers the state; for an exited job it answers `exited` at once.
- The table holds 64 jobs. Starting one more forgets the oldest exited job;
  with 64 running jobs `exec.start` fails and names `exec.kill`.
- `exec.list` reports each job's `cmd` text (for `argv`, the elements joined
  by spaces) cut to 4096 characters with a trailing `…` when longer, and
  `started` in the guest's local time with its offset.
- A job is listed and found by its id once its process has started; a start
  that fails leaves no job.
- When a job's process exits the agent sends
  `{"t":"ev","name":"job.exited","job":"<id>","code":<int>}` to every open
  connection. For a job that ends at once the event can arrive before the
  `exec.start` reply; match it by `job` after the reply.

### Processes (`proc.list`, `proc.kill`)

- Windows lists `Win32_Process` (`mem_kb` is the working set) through
  [Windows PowerShell](#windows-powershell) as a recipe of the agent, at most 30 s
  (`listing the processes took longer than 30 s; retry`); elsewhere
  `ps axo pid=,ppid=,rss=,args=`: `name` is the kernel's name of the process
  (`/proc/<pid>/comm`, at most 15 bytes), or the base name of the first
  argument when that is the same name or begins with a kernel name of 15
  bytes, or when there is no `/proc`; a program that rewrites its arguments,
  such as `sshd: /usr/sbin/sshd -D [listener] …`, is named `sshd`. `path` is
  set when the first argument is absolute. Each `cmd` is cut to
  8192 characters with a trailing `…` when longer, after each run of invalid
  UTF-8 bytes became one U+FFFD (`exec.list` cuts its `cmd` the same way).
- `proc.kill` with `pid` answers `killed: 1` or an error. With `name` it kills
  every process of that name, compared without regard to case, except the
  agent itself. On Windows `.exe` is added to a name without an extension;
  the agent lists the processes with their creation times and terminates
  each match and, with `tree`, its descendants, children first, then waits
  up to 5 s for them to end. A process counts as a child only when both
  creation times can be read and it was not created before its listed
  parent, and a tree is not followed into the agent. A listed creation time
  later than the moment just before the listing is treated as unknown.
  Before it terminates a process the agent opens it and requires that its
  creation time equals the listed one and that the base name of its program
  file (`QueryFullProcessImageNameW`) equals the listed name without regard
  to case; a process that differs, or whose listed time, time or name
  cannot be read, is skipped and not counted. `killed` counts the processes that were
  terminated. When any of them refuses access the answer is an error: from
  an agent that is not elevated
  `could not kill <n> of the <total> processes named '<name>' because access was denied (<k> were killed); restart alcove-agent elevated through the scheduled task that alcove-agent --install creates, then retry`,
  and from an elevated agent
  `could not kill <n> of the <total> processes named '<name>' because Windows denied access to the elevated agent (<k> were killed); such a process is protected or needs more than administrator rights, so stop it through its service (sc stop <service>) or leave it running`
  (`(1 was killed)` when one was).
  Elsewhere `killed` counts the processes that were sent SIGKILL, with `tree`
  to the process group a match leads.
  No match answers `killed: 0`.

### App launch (`app.launch`)

- `path` is the program. On Windows a bare file name (`.exe` added when it
  has no extension) is looked for only in places a standard user cannot
  change: the folders of the machine's `PATH` (the `Path` value under
  `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`, in
  order), then `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\<name>`
  and the 32-bit view `HKLM\SOFTWARE\WOW6432Node\…\App Paths\<name>`, so
  `msedge.exe` starts Edge. `%VAR%` references in these values are expanded
  from the machine, never from the agent's environment: `%SystemDrive%`,
  `%SystemRoot%` and `%windir%` from the system's Windows folder
  (`GetSystemWindowsDirectoryW`), and `%ProgramFiles%`, `%ProgramFiles(x86)%`,
  `%ProgramW6432%`, `%CommonProgramFiles%`, `%CommonProgramFiles(x86)%` and
  `%CommonProgramW6432%` from their `…Dir` values under
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion`. A folder or program that
  names any other variable, or does not start with a drive, is skipped. When
  the system's Windows folder cannot be read the answer is
  `the system folders could not be read (<system error>); pass the full path of the program`.
  A name found in none of them answers
  `'<name>' is not in the system folders of PATH or under HKLM App Paths; pass the full path of the program`.
- The program starts directly with `args` as its arguments and with a normal
  window. Without `cwd` it runs in the directory of the program file; `cwd`
  resolves like the `cwd` of `exec.run`. On Windows the program runs as the
  agent in the [environment of a command](#environment-of-a-command-on-windows),
  without the desktop user's `HKCU\Environment`, and `env` adds variables to
  that environment; the lookup of `path` above is unchanged. On Linux with a
  [desktop session](#the-desktop-session-linux) the program runs as the
  session's user in the session's environment, and `env` adds variables to
  that environment; otherwise it runs as the agent and `env` adds variables
  to the agent's environment. A name given in `env` replaces one of the same name
  (case-insensitive on Windows), and an empty name or one that contains `=`
  answers `env names cannot be empty or contain '='`. Its standard input,
  output and error are the null device, so a console program that reads its
  input ends at once.
- A program that cannot be started answers
  `cannot start '<path>': <system error>; check the path with fs.stat`.
- When the process ends the agent sends
  `{"t":"ev","name":"process.exited","pid":<int>,"code":<int>,"path":"<program file>"}`.
  `code` is the unsigned exit code: a process killed by `proc.kill` reports
  1, a fail-fast crash 3221227010 (`0xC0000602`). For a launcher that hands
  over to another process (`notepad.exe`, `calc.exe`, `msedge.exe` when Edge
  already runs) the event names the launcher and arrives within a second, so
  `process.exited` can arrive before the `app.launch` reply. The process is
  not a job, and it keeps running when the agent restarts; `process.exited`
  is then not sent.
- With `wait_window_ms` above 0 on an agent with the `ui` capability, the
  agent lists the windows before the start and then every 150 ms:
  - candidates are the titled windows that were not listed before the start,
    have a rectangle that is not empty or are minimized (a window of 0×0 such
    as `OLEChannelWnd` of `mmc.exe` is none), and are
    not already claimed by another in-flight or finished `app.launch` (a
    claim ends when its window closes; a helper start ends the claims of the
    launches that have answered and keeps those of launches still waiting for
    their window; the agent keeps the 1024 newest claims);
  - a candidate of the started process or one of its descendants is chosen,
    and beats a candidate of any other process whatever their sizes;
  - when the started process has exited, or 2 s after the start, a candidate
    of any process is chosen;
  - of several candidates the one with the largest rectangle is chosen, after
    one more listing 150 ms later, so that windows which open together compete;
  - a frame window of a packaged app that still reports
    `ApplicationFrameHost.exe` is read again for up to 3 s until it reports the
    app's process.

  Without a candidate within `wait_window_ms` the reply has `pid` alone. When
  the windows cannot be listed before the start the program is not started:
  `'<path>' was not started because the windows could not be listed: <reason>`.
  `notepad.exe` answers with the window of `Notepad.exe`, another process,
  and `calc.exe` with the window of `CalculatorApp.exe`.

### Windows and UI Automation (`win.*`, `ui.*`)

A Windows agent runs a helper (C# compiled by Windows PowerShell 5.1, .NET
Framework UI Automation) as a child process in the agent's logon session and
passes these operations to it. Other agents answer
`UI Automation is only available on Windows guests`.

**Helper process.** The agent starts the helper on the first `win.*` or
`ui.*` operation, and again on the next operation after the helper ended; it
does not start on connect, so a wait for a window event must be preceded by
`ui.ping` (and `app.launch` with `wait_window_ms: 0` does not start it). The
helper runs in the agent's logon session. Its files are in
`C:\ProgramData\Alcove\uia`: `bootstrap.ps1`, `helper.cs`, `helper.log` and
`helper.log.1` (1 MiB each: a write that would make `helper.log` larger moves
it to `helper.log.1` first, or empties it when it cannot be moved), and a
`tmp` folder the compile uses. Every start
compiles `helper.cs` in memory; no compiled helper is stored.
`C:\ProgramData` stands for the folder Windows names as ProgramData: the
`ProgramData` value of `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList`
(normally `%SystemDrive%\ProgramData`), in which the agent and `--install`
replace `%SystemDrive%` with the drive of the system's Windows folder
(`GetSystemWindowsDirectoryW`) and `%SystemRoot%` and `%windir%` with that
folder; a value with any other variable is refused. No environment variable is
read, so a `ProgramData` or `SystemDrive` set in a user's
`HKCU\Environment` does not move the folder. That
folder and its parent `C:\ProgramData\Alcove` are given the owner
Administrators and the access list "Administrators and SYSTEM: full control"
with inheritance removed (`icacls` reads it back as
`BUILTIN\Administrators:(OI)(CI)(F)` and `NT AUTHORITY\SYSTEM:(OI)(CI)(F)`),
so `agent.log`, `install.log` and `helper.log` are readable by administrators
only. The lock is applied first thing at install and at agent start, before a
log file is opened, and again at every helper start. A folder the lock creates
is created with that owner and access list. An existing folder is opened
without following a reparse point and kept in place only when it is a
directory, not a reparse point, and already has exactly that owner and access
list; its access list is never rewritten in place, so a handle a standard user
opened on it before the lock cannot outlive the lock on a folder that was once
theirs. A folder that exists and is anything else (a reparse point, another
owner, or any other access list, such as the one a folder created by path
under `C:\ProgramData` inherits) is moved aside and a new, locked folder is
created in its place. This applies to `C:\ProgramData\Alcove` and to its `uia`
folder. When a folder is kept in place, the parent keeps the agent's logs
(`agent.log` and `agent.log.1`, 1 MiB each, kept like `helper.log`) and
the uia folder keeps only its logs (every other entry is deleted at each start;
a deletion refused because something is in use, access is denied or a folder is
not empty yet is tried again every 50 ms for 2 s).

A folder that is moved aside is renamed to `<name>.untrusted-<yyyyMMddHHmmss>`
(UTC) beside it; a handle someone kept on the old folder names the renamed one,
and the new folder starts empty, so `helper.log` is not carried into it. At
most one `<name>.untrusted-*` folder is kept per data folder: an older one is
removed first, and a reparse point among them is unlinked rather than followed.
The renamed folder is left for an administrator to remove, and the agent log
names it
(`a data folder that was not already locked was moved to <path>; an administrator may remove it after checking it`,
or `a helper folder that was not already locked was moved to <path>; an administrator may remove it after checking it`
at a helper start).
When the rename fails (a handle is open on something inside the folder, or on
the folder without delete sharing) the folder is not locked, with the reason
`<dir> is a link, belongs to another owner or lets other users change it, and could not be moved aside (<error>); close the programs that use files in it, remove it as an administrator and restart alcove-agent`.
A reparse point at the uia path itself is removed rather than followed and the
uia folder is created again.

**Deploy root.** At start a Windows agent also locks `C:\alcove-apps`, the
default root of `vm.deploy`, whose files the host installs and launches with
the agent's elevated token: owner Administrators, "Administrators and
SYSTEM: full control, Users: read and execute" with inheritance removed
(`O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)`). A missing
root is created that way. An existing root is kept only when it is a
directory, not a reparse point, owned by Administrators or SYSTEM and has
exactly that access list. Anything else (a junction or other link, another
owner, or an access list that lets other users change it, such as the one a
folder under `C:\` inherits) is renamed to
`C:\alcove-apps.untrusted-<yyyyMMddHHmmss>` (UTC) with what it holds, and a new
locked root is created; the agent log says
`C:\alcove-apps was a link, belonged to another owner or let other users change it; it was moved to <path>, which an administrator may remove after checking it`.
The host deploys again into the new root. When the rename or the lock
fails, the agent logs `the deploy root is not locked (<reason>)` and serves
as usual; the reason for a failed rename is
`C:\alcove-apps is a link, belongs to another owner or lets other users change it, and could not be moved aside (<error>); close the programs that use files in it, remove it as an administrator and restart alcove-agent`.

The agent also creates the root that way when it is missing while it runs:
an `fs.write` with `mkdirs`, an `fs.mkdir` or an `fs.rename` whose target is
the root or lies below it first creates and locks a missing root, then does
its work. When that fails the operation does nothing and answers
`C:\alcove-apps is missing and could not be created locked (<reason>); remove what is in its way as an administrator and retry`.
`fs.stat` of the root itself adds `locked`: true when it is a directory, not
a reparse point, with the owner and access list above, false otherwise (an
old root the agent could not move aside, or one another program created).
`locked` is absent for a missing root, for every other path, on other
systems and from older agents.

The agent opens no log file that is a reparse point and none inside a folder
it could not lock; it then writes
`log: <path> is not opened because its folder is not locked (<reason>)` to
stderr and logs there. When a folder cannot be locked the helper does not
start:
`the UI helper folder <dir> could not be locked (<reason>); fix its owner and access list, then retry`.
The reasons:

- `C:\ProgramData\Alcove is a reparse point; remove it` (a reparse point at
  the folder itself),
- `<dir> is not a directory; remove it and restart alcove-agent`,
- `<dir> is a link, belongs to another owner or lets other users change it, and could not be moved aside (<error>); close the programs that use files in it, remove it as an administrator and restart alcove-agent`,
- `open <dir>: <system error>`,
- `<dir> still has the access list <sddl>; fix it with icacls and restart alcove-agent`,
- `SetNamedSecurityInfo(<path>): <system error>` and the system error of a
  deletion, for an entry of the folder.

An agent for which Windows names no ProgramData folder uses no other folder:
it logs `the ProgramData folder could not be located (<system error>)`, opens
no log file (`log: <path> is not opened because the ProgramData folder could not be located`
on stderr), logs to stderr, starts no helper, and answers every `ui.*` and
`win.*` operation with
`the UI helper cannot start because the ProgramData folder could not be located (<reason>); fix the ProgramData value of HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList, then restart alcove-agent through its scheduled task`.
An `app.launch` that waits for a window (`wait_window_ms` above 0, the
default) starts nothing and answers
`'<path>' was not started because the windows could not be listed: the UI helper cannot start because the ProgramData folder could not be located (<reason>); fix the ProgramData value of HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList, then restart alcove-agent through its scheduled task`;
with `wait_window_ms: 0` it starts the program.

Before a start the agent waits up to 10 s for the previous helper process to
end (`the previous UI helper process has not ended after 10 s; retry`); once
such a wait ran out, later starts answer that sentence at once until that
process has ended, without waiting again. The wait and the start run in the
turn of the request that needs the helper, so the requests behind it wait for
them (within their 60 s turn limit); they do not hold up `Close`. After
`Close` a start that is waiting or preparing stops before the next step and
answers `the UI helper is shut down; restart alcove-agent`. The start
failures:

- `the UI helper could not be prepared in <dir>: <reason>; check free space and the folder's access list`
  (the helper files could not be written or read),
- `the UI helper could not be started (<reason>); restart alcove-agent and retry`
  (the system directory, a pipe or the PowerShell process),
- `the UI helper could not be compiled: <first compiler error>; reinstall the guest tools`,
- `the UI helper stopped: <message>; retry, and restart alcove-agent if it repeats`
  (the helper's serving thread ended with an error after it had started; the
  requests inside it get this answer).

On the wire the failures of a start follow
`could not start the UI helper through PowerShell: ` (lock, wait, file and
process failures) or `UI helper failed to start through PowerShell: ` (a
failure the bootstrap script reports before the helper is ready); the
`the UI helper stopped: …` sentence of a helper that had been ready comes
without a prefix.
The helper's environment takes nothing from the agent's: it holds
`SystemRoot`, `windir` and `SystemDrive` of the system's Windows folder,
`ComSpec` (`cmd.exe` of the system folder), a `PATH` of the system folder,
the Windows folder, `Wbem` and Windows PowerShell's folder, a `PSModulePath`
of Windows PowerShell's own `Modules` folder only (`bootstrap.ps1` sets it
again before its first command), `PSModuleAnalysisCachePath` and
`TEMP`/`TMP` inside the locked folder, and `ALCOVE_UIA_START`. A helper
killed while it starts, the compiler included, leaves no process behind that
blocks the next start. The helper, and an app launched through
`app.launch`, inherit the agent's elevated token. `alcove-agent --install`
locks the folders in the same way before it copies or registers anything and
fails, with exit code 1 and a line on stderr that begins `install failed: `,
when they cannot be locked
(`the Alcove data folder <dir> could not be locked (<reason>); fix its owner and access list with icacls, then run alcove-agent --install again`)
or when Windows names no ProgramData folder
(`the ProgramData folder could not be located (<system error>), so the Alcove data folder cannot be located; run alcove-agent --install again as an administrator`);
it then writes no `install.log`. The later steps fail the same way and write
the line to `install.log` too, each with its next step:

| Step | Line after `install failed: ` |
|---|---|
| finding the running program | `the path of this alcove-agent.exe could not be read (<reason>); run alcove-agent --install again from the folder that holds alcove-agent.exe` |
| reading the running program | `<file> could not be read (<reason>); copy alcove-agent.exe to a local folder and run alcove-agent --install from there` |
| copying the program to `C:\Program Files\Alcove` | `could not write <file> (<reason>); delete <file>, then run alcove-agent --install again from an elevated prompt`, `the copy at <file> holds <n> bytes instead of <m>; delete <file>, then run alcove-agent --install again from an elevated prompt`, or `the copy at <file> could not be checked (<reason>); delete <file>, then run alcove-agent --install again from an elevated prompt` |
| creating the scheduled task | `the scheduled task AlcoveAgent could not be created (<error>: <schtasks output>); run alcove-agent --install again from an elevated prompt` |
| adding the firewall rule | `the firewall rule AlcoveAgent for TCP port <port> could not be added (<error>: <netsh output>); run alcove-agent --install again from an elevated prompt` |
| starting the task | `the scheduled task AlcoveAgent was created but did not start (<error>: <schtasks output>); start it with schtasks /Run /TN AlcoveAgent, or sign out and in again` |

**One request at a time.** The agent hands requests to the helper one by one
in the order they arrived. An operation's time limit (20 s; 30 s for
`ui.tree` and `ui.text`) starts when the helper receives it. Waiting for a
turn is limited to 60 s and then answers
`the UI helper is busy with '<op>'; retry` (`<op>` is the helper operation
holding the helper); the helper keeps running. Each request is cancelled when
its connection closes: one still waiting for its turn leaves the queue without
reaching the helper (`the request was cancelled`), while one already handed to
the helper runs to its end. A
request the helper does not answer within its limit answers
`UI helper did not answer '<op>' within <n> s; it was restarted`: the helper
is killed, requests that waited behind it run in the next helper, and every
ref is forgotten. A request that was inside a helper that ended answers
`UI helper exited; retry`. A helper that does not start within 120 s answers
`UI helper did not start within 120 s; see <helper.log>`.

**Window object.**

```
{"id":"0xd0368","title":"Alcove Fixture","pid":7140,"process":"alcove-fixture.exe","class":"AlcoveFixtureWindow",
 "x":40,"y":40,"w":800,"h":600,"state":"normal","foreground":true,"responding":true,"modal":false}
```

- `id` is the window handle. `x`, `y`, `w`, `h` are guest pixels of the
  visible frame (without the invisible resize border); a minimized window has
  `0,0 0x0`. `state` is `normal`, `minimized` or `maximized`.
- `responding` is false once the system considers the window hung (about 5 s
  without message handling). `modal` is true when the window's owner is
  disabled.
- `pid` and `process` name the process a user would name: for the frame
  window of a packaged app the process of its core window, for the `Ghost`
  window the system shows in place of a hung window (titled
  `<title> (Not Responding)`) the process of the hung window. The hung window
  itself stays listed.
- `win.list` lists, top-most first, the top-level windows that are visible,
  not cloaked and titled, and the foreground window even without a title. A
  notification toast that has the foreground (`New notification`, class
  `Windows.UI.Core.CoreWindow` of `ShellExperienceHost.exe`, seen with the
  OneDrive backup toast) is not listed, so no listed window has `foreground:
  true` then; `ui.tree` with `window: foreground` reads it, and while it is in
  front `win.action focus` on another window answers the `did not come to the
  foreground` sentence.

**Window argument.** `window` is an id from `win.list`, `foreground`, or a
part of a title (case-insensitive; the top-most match). Errors:
`window 0x1 no longer exists; call win.list again` (also for the handle of a
child window), `"0xzz" is not a window id; ids look like 0x1a2b3c and come from win.list`,
`no window has "<text>" in its title; call win.list to see the open windows`,
`no window is in the foreground; pass a window id from win.list`,
`pass a window id, a title part, or foreground` (empty string). A window that
does not handle messages answers the `ui.*` operations addressed to it with
`window <id> "<title>" is not responding; wait and retry, or end its process with proc.kill when win.list still shows responding false after 10 s`.
A window of a higher integrity level, which denies the probe message rather
than being hung, is not reported as not responding.

**`win.action`.** `window` is required.

- `focus` restores a minimized window and brings the window to the
  foreground with `SetForegroundWindow`; when that call fails, with the same
  call while the helper's thread input is attached to the foreground window's
  thread; then with `SwitchToThisWindow`. A window that still is not in the
  foreground answers
  `window <id> "<title>" did not come to the foreground; click its title bar through the display`.
- `minimize`, `maximize` and `restore` wait up to 2 s for the new state;
  `restore` ends the minimized state of a minimized window and the maximized
  state of a maximized one. A window that does not change answers
  `window <id> "<title>" was not minimized within 2 s; check responding in win.list, then retry or end its process with proc.kill`.
- `move` (`x`, `y`) and `resize` (`w`, `h`) apply to the visible frame, the
  rectangle `win.list` reports; a minimized or maximized window returns to
  its normal state first, without being activated. The window decides its
  final size (the fixture app answers `resize` to 100×100 with 506×393), and
  a position outside the screen is accepted.
- `close` posts `WM_CLOSE` and waits up to 2 s. `closed` says whether the
  window is gone; `window` is then `null`, otherwise the window as it is. A
  shell window (class `Progman`, `WorkerW`, `Shell_TrayWnd` or
  `Shell_SecondaryTrayWnd`) is refused:
  `window <id> is part of the Windows shell and is not closed; close app windows only`.
  When the message cannot be posted: a window that no longer exists answers
  `closed: true` with `window: null`; one that denies the post answers
  `window <id> belongs to a process the helper cannot send to; run the app without elevation or use input ops`;
  any other
  failure answers `window <id> could not be asked to close (error <n>); retry`
  with the Windows error code.
- A show-state change (`minimize`, `maximize`, `restore`) that does not take
  within 2 s answers
  `window <id> "<title>" <what> within 2 s; the app may not allow it; use win.list to see its state`
  when the window still answers messages, and the
  `… check responding in win.list, then retry or end its process with proc.kill`
  form only when the window is hung.
- Errors: `action must be one of focus, minimize, maximize, restore, close, move, resize`,
  `pass window: a window id from win.list, a title part, or foreground`,
  `move needs x and y`, `resize needs w and h`, `pass w and h of at least 1`.

**Node object.**

```
{"ref":"e620","depth":0,"role":"Edit","name":"Message","value":"안녕 \"fixture\"","aid":"101","x":186,"y":125,"w":484,"h":26,"flags":["focused"]}
```

- `ref` matches `^e\d+$` and names the element while it exists; each helper
  process numbers its refs from `<number of earlier helpers> × 1000000 + 1`.
  A snapshot restore of the VM puts back the helper's ref counter with the
  guest memory, so a ref from before the restore may name another element
  afterwards; call `ui.find` or `ui.tree` again after a restore.
  A ref whose element is gone answers
  `element <ref> no longer exists; call ui.tree again`; other text answers
  `ref "<text>" is not a ref; refs look like e12 and come from ui.tree or ui.find`.
- `role` is the control type name (`Button`, `Edit`, `Document`, …). A
  multi-line Win32 edit control is a `Document`.
- `value` is the value-pattern value cut at 200 characters with `…`; it is
  absent when empty and for password fields. `aid` is the automation id,
  absent when empty. Line ends in `value` and in `ui.text` are LF.
- A password field (flag `password`) has `name: ""` in every reply, whatever
  name its provider reports, and no `value`; its `aid` and rectangle are
  given. The selector fields `name` and `nameContains` are compared with the
  name the provider reports, so `role: Edit, name: Password` finds a labelled
  password field; the node that comes back has the empty name.
- `flags` come from `focused`, `disabled`, `offscreen`, `selected`,
  `checked`, `expanded`, `collapsed`, `password`. The children of a window
  whose modal dialog is open are `disabled`.
- `depth` counts the listed ancestors.

**Selector fields.** `window` (default `foreground`), `role`
(case-insensitive; an unknown role answers `unknown role "<text>"; use one of …`),
`name` (exact), `nameContains` (case-insensitive), `automationId` (exact),
`index` (0-based among the matches in tree order). At least one of `role`,
`name`, `nameContains`, `automationId` is required:
`pass ref or at least one of role, name, nameContains, automationId`. No
match answers
`no element matches {"window":"0xd0368","role":"Button","name":"Nope"}; call ui.tree to see what exists`
(the JSON holds the selector fields that were sent); `ui.find` answers
`nodes: []` instead. A search that ended early answers one of

- `the search for <selector> did not finish within 12 s; read the window in parts with ui.tree and root, then use a ref` (22 s for `ui.text`),
- `the search for <selector> stopped 256 levels below the window; read the deeper part with ui.tree and root, then use a ref`,
- `the search for <selector> met an element that disappeared; call the operation again`,

and `ui.find` with at least one match returns the matches with
`truncated: true`.

**`ui.tree`** lists the control view below the window or `root`. `filter:
interactive` keeps elements with a name, a value, keyboard focus support or
an invoke pattern, and the control types people act on; `all` lists the raw
view. `truncated` is true when a listed element did not fit in `max`, after
20 s, and when an element disappeared during the walk. `depth` above 256
answers `depth must be 256 or less; read deeper parts with root`. A `root`
that is a password field is listed alone, and a `root` below a password field
is refused with the password sentence of `ui.text`.

**`ui.text`** in `auto` mode returns the text pattern's document text, then
the value, then the names (for edits and documents, the values) of the text,
list item, edit and document elements below the element joined by newlines,
then the element's name. `pattern` uses the text pattern alone
(`the element has no text pattern; use mode auto or descendants`). A password
field, or an element below one, answers
`the element is a password field; its text is not read; it cannot be read through UI Automation`
in every mode; a failed password-property read counts as a password field, as
do a parent that cannot be read and a chain of more than 256 parents; and
`ui.tree`, `ui.find` and the descendant text of `ui.text` do not list what is
below a password field. A node below a password field in a `ui.rect`, `ui.act`,
`ui.focused` or `ui.at` reply has the `password` flag, an empty `name` and no
`value`, as the password field itself has; a parent whose read fails with a
system error counts as a password field too.
The document text of a Chromium page shows a password field as bullets.

**`ui.rect`**: `cx`, `cy` are the centre of the element's rectangle;
`clickable` is false with a `blocked` sentence when the rectangle is empty,
the element is off screen or disabled, the centre is outside the screen or
another top-level window covers it. `scroll: true` scrolls the element into
view first when it has a scroll-item pattern.

**`ui.act`** calls a UI Automation pattern on the element:

| `action` | Pattern call |
|---|---|
| `invoke` | `InvokePattern.Invoke` |
| `toggle` | `TogglePattern.Toggle` |
| `expand`, `collapse` | `ExpandCollapsePattern` |
| `select` | `SelectionItemPattern.Select` |
| `set_value` | `ValuePattern.SetValue(value)`; a read-only element answers `the element is read-only; its value cannot be set; type into another element or change it in the app` |
| `focus` | brings the element's window to the foreground as `win.action focus` does, then `SetFocus` |
| `scroll_into_view` | `ScrollItemPattern.ScrollIntoView` |

- The reply's `node` is read 100 ms after the call. A pattern call may bring
  the element's window to the foreground (`set_value` on a Win32 edit control
  does).
- The call counts as done when it returned or when the element's window
  stopped taking input because it opened a modal window. A call that has not
  returned after 1.5 s is left running; the reply then carries the node as it
  was before the action and, when the window no longer handles a message
  within 0.5 s, `unresponsive: true` (a button that makes its window hang
  answers after about 2.1 s), otherwise `pending: true`.
- When the element is gone after the action the reply carries the node as it
  was before and `gone: true`. The same reply is given when the element's
  window no longer exists after the call, and when the pattern call failed
  with a UI Automation or COM error and the window stopped existing within
  0.5 s of it or the element can no longer be read (a button that removes
  itself). A pattern call that failed that way while the window and the
  element stay answers
  `the element's app did not complete <action> (<hresult>); read the element again with ui.find and retry`
  (`<hresult>` as `0x80004005`).
- A disabled element is refused before the call:
  `the element is disabled; wait until it is enabled`. More than eight `ui.act`
  calls still running in one app answer
  `<n> earlier ui.act calls are still running in the app; wait for them or end its process with proc.kill`.
- Errors: `the element does not support toggle; it supports invoke, focus; click it through the display for anything else`
  (the list names what the element supports), `the element is disabled; wait until it is enabled`,
  `set_value needs value`,
  `action must be one of invoke, toggle, expand, collapse, select, set_value, focus, scroll_into_view`,
  `<action> is not possible on the element in its present state: <reason>`.

**`ui.focused`** returns the element with the keyboard focus and its window
(`window` is `null` when the element has none), or
`no element has the keyboard focus; click a window or use win.action focus`.

**`ui.at`** tells what a point, a ref or the keyboard focus is aimed at,
within a time limit, and how a selector would name it. It registers no ref,
moves no focus and sends nothing to the app. The request has exactly one of

- `x`, `y`: whole numbers, physical pixels of the guest screen (the space of
  window rectangles and node `x`, `y`, `w`, `h`),
- `ref`: an element ref,
- `focused: true`: the element with the keyboard focus,

otherwise `pass x and y, ref, or focused: true`. `budgetMs` (default 250) is
the time for the whole answer; a value outside 50–2000 is brought into that
range.

```
{"node":{"depth":0,"role":"Button","name":"Send","aid":"1","x":678,"y":124,"w":96,"h":28,"flags":[]},
 "window":{"id":"0x603b6","title":"Alcove Fixture"},
 "byAutomationId":{"matches":1,"index":0},
 "byName":{"matches":1,"index":0}}
```

- `node` is a node object with `depth: 0`. It has `ref` only when the request
  named a ref (that ref). For a point it is the deepest element there, for
  `focused` the focused element, each replaced by its nearest ancestor in the
  control view (the view `ui.find` searches) when it is not in that view, and
  by the outermost password field above it when it lies below one. For a ref
  it is that element itself.
- `window` is the top-level window that contains the element: `id` as in
  `win.list` and `title`, which is `""` for a popup or a menu. For a ref
  whose element and parents give no window handle it is the window found
  through the element's parents, else the window the ref was taken in while
  that window exists.
- `byAutomationId` is present when the node has an `aid`: `matches` counts the
  elements of that window which the selector `{role, automationId}` matches,
  and `index` is the node's place among them in the order a selector search
  visits them, so `{window, role, automationId, index}` names the node.
  `byName` is the same for `{role, name}` and present when `name` is not
  empty, so never for a password field or a node below one. Either is `null`
  when the count did not finish within the time, when the walk did not
  meet the element (an element outside the control view, or below a password
  field, named by a ref), and when the window's `title` given as a selector's
  `window` would name another window: the title is empty, the window is not
  one `win.list` shows (hidden or cloaked), or a window listed before it in
  `win.list` has the title in its own (two windows titled `Untitled -
  Notepad`).
- Errors: `no element at (<x>, <y>); take a screenshot to see what is there`
  (a point outside every screen, on the desktop window itself, or in a window
  that refuses UI Automation), `no element has the keyboard focus; click the field first`,
  `element <ref> no longer exists; call ui.tree again` (also when reading
  the element fails with a system error and the window the ref was taken in
  closes within the time limit). A point on the
  wallpaper or on a desktop icon lies in the shell's `Progman`/`WorkerW`
  window and answers its element (a `List` named `Desktop`, or the icon),
  not this error.
- The UI Automation calls run on a thread the helper abandons at the time
  limit, so the reply comes within `budgetMs` + 100 ms and the helper serves
  the next request at once. An app that did not answer in time gives
  `no element at (<x>, <y>): the app did not answer within <n> ms; retry`,
  `the focused element was not read: the app did not answer within <n> ms; retry` or
  `element <ref> was not read: the app did not answer within <n> ms; retry`.
  The same sentence is given at once for a window the system reports as not
  responding, for the `Ghost` window the system shows in place of such a
  window, and while eight earlier `ui.at` calls into that app are still
  waiting.
- Measured on the test guest: 50 calls on a button of the fixture app took
  12–14 ms in the median and 15–26 ms at most; on the fixture made to hang, a
  call with the default limit answered after 252–270 ms and one with
  `budgetMs: 100` after 105–116 ms, and `win.list` after it took 1–6 ms.

#### Window events

While the helper runs it compares the titled windows every 300 ms and the
agent sends one event per difference, each with the window object:

```
{"t":"ev","name":"window.opened","window":{…}}
```

| `name` | Sent when |
|---|---|
| `window.opened` | a titled window is listed that was not listed before |
| `dialog.opened` | in addition to `window.opened`, when that window is modal or of class `#32770` |
| `window.closed` | a listed window is gone (the object is the last one seen, with `foreground: false`) |
| `window.title` | the title of a listed window changed |
| `window.foreground` | another window is in the foreground (also sent for a window without a title, such as the taskbar) |

- An event arrives up to 300 ms after the change, plus under 2 ms for the
  comparison (a `window.title` one comparison later). In one comparison the order is closed, opened (with
  `dialog.opened`), title, foreground.
- The first comparison of a helper process sends nothing; changes while no
  helper runs are not reported. Events flow only while the helper runs, so a
  client that wants them sends `ui.ping` first to start it.
- The first comparison of a helper also records the titles and the foreground
  window, so a helper start sends no `window.title` or `window.foreground` for
  windows that did not change.
- At most one `window.title` is sent per window per second: the title a
  window has at a comparison is sent when it differs from the one last sent
  for that window and a second has passed since that window's previous
  `window.title`. A title that keeps changing therefore raises an event about
  every 1.2 s (the first comparison after the second), each with the title of
  that moment, and the last event carries the title the window ends with; a
  title that returns to the one last sent sends nothing. The fixture's
  `Titles` button (a new title every 50 ms for 5 s, then the base title)
  raises 5 events 1.23–1.26 s apart: 4 with a numbered title and the last
  with the base title.
- At most one `window.foreground` is sent per window per second. One that
  falls inside that second is sent once the second has passed, when the
  window is still in front, so the last `window.foreground` names the window
  in front. When the window the last event named no longer exists, the window
  in front is announced at the next comparison without waiting for its second
  (a dialog that closes 0.6 s after its owner was announced: the owner's
  `window.foreground` arrives together with the dialog's `window.closed`).
- Each connection has a bounded event queue of 256 messages. When it is full
  (a client that does not read) events are dropped and counted, and the agent
  puts `{"t":"ev","name":"events.dropped","count":<n>}` in the place of the
  dropped events: before the next event that is queued, or after the last
  queued message when no event follows. It carries only the count. A
  connection whose write stalls for 30 s is closed.
- A window that gets its title after it was shown is reported as opened at
  that moment. Short-lived system windows are reported like any other
  (`PopupHost` of class `Xaml_WindowedPopupClass` from the shell, the `Ghost`
  window of a hung window).
- A hung window stays listed; its `Ghost` window raises `window.opened` and
  `window.foreground` about 5 s after the hang began.

### Files (`fs.*`)

- Paths: `~`, `~/x`, `~\x` and relative paths resolve against the home
  directory of the agent's user (on Linux the [desktop session](#the-desktop-session-linux)'s user; on Windows the profile folder of the agent's account from the `ProfileList` key, see [Environment of a command on Windows](#environment-of-a-command-on-windows), never `USERPROFILE`); results report absolute paths. On Windows a
  drive without a separator after it (`C:foo`) and a path that starts at the
  root of the current drive (`\x`) are refused with a sentence that names the
  full form to pass.
- `fs.stat` of a path that goes through a file (`f.txt/inner`) answers
  `exists: false`.
- `fs.stat` of a missing path answers `exists: false` without an error.
  `fs.list`, `fs.read` and `fs.tail` of a missing path are errors that name
  the path.
- `fs.stat` describes what the path leads to and adds `link: true` when the
  entry at the path is a symbolic link or, on Windows, a junction or another
  reparse point that is not a plain directory; a link to nothing answers
  `exists: false` with `link: true`. `fs.list` marks such entries with
  `link: true`, lists them with `dir: false` and does not list what is below
  them; `fs.list` of a path that is itself a link answers
  `'<path>' is a link and fs.list does not follow links; list the folder it leads to`.
- On Windows `fs.stat` adds `owner`, the owner of the entry at the path
  itself (a link is not followed), also for a link to nothing:
  `"administrators"` (`BUILTIN\Administrators`), `"system"`
  (`NT AUTHORITY\SYSTEM`), `"user"` (the account the agent runs as), any
  other owner as its SID string (`"S-1-5-21-…"`), or `"unknown"` when the
  owner cannot be read. Agents on other systems, and older agents, send no
  `owner`. For `C:\alcove-apps` itself it also adds `locked`
  ([Deploy root](#windows-and-ui-automation-win-ui)).
- `fs.list` lists the direct children, or with `recursive` the whole tree, in
  lexical order, at most 5000 entries. `sha256` (lower-case hex) is present
  only when asked for, and only for regular files the agent could read: a
  file another process holds open is listed without it. Entries the agent
  cannot read (a folder without access, below which nothing is listed) are
  left out and counted in `skipped`, present only when above 0.
- `fs.read`, `fs.tail` and `fs.stat` with `sha256` refuse what is neither a
  regular file nor a directory, such as a FIFO:
  `'<path>' is not a regular file; fs.read, fs.tail and sha256 read regular files only`.
- `fs.read` returns up to `length` bytes from `offset`; `eof` is true when
  the piece reaches the end of the file.
- `fs.tail` returns the last `lines` lines found in the last 262144 bytes.
  When that window begins inside a line, the partial line is left out.
- `encoding` is `"utf-16le"` for a file that begins with the bytes `FF FE`
  but not `FF FE 00 00` (the UTF-32LE mark), and absent otherwise. `fs.tail`
  of such a file starts on a code unit after the byte order mark and ends lines at the code unit `0A 00`; the returned
  bytes do not include the mark.
- `fs.write` creates the file when needed. With `append` the bytes go to the
  end and `offset` is not used; otherwise they are written at `offset`, after
  emptying the file when `truncate` is set. A missing parent directory is an
  error unless `mkdirs` is set. It refuses, before opening the file, more
  than 262144 bytes of `data`
  (`data is <n> bytes; fs.write takes at most 262144 bytes, so write the rest with further calls`),
  `append` together with `truncate` (`pass append or truncate, not both`) and
  an `offset` past the end of the file, counted after `truncate`
  (`offset <n> lies past the end of '<path>' (<size> bytes); write from offset <size> or lower`).
- `fs.rename` fails when `to` exists unless `overwrite` is set, and never
  replaces a directory. `fs.mkdir` creates missing parents and succeeds for an
  existing directory.
- `fs.delete` of a missing path answers `deleted: false`. A directory with
  entries needs `recursive`. It refuses, before touching anything, the home
  directory, a file-system root (`/`, `C:\`) and any ancestor of the home
  directory, whether or not `recursive` is set. The path is compared as given
  and with a `\\?\` prefix removed and the links, junctions and short names of
  its parent folder resolved; the home directory as given and with its links
  resolved. A folder whose identity (volume serial number and file index on
  Windows, device and inode elsewhere, read without following a link at its
  end) equals that of one of those folders or of the root of its own volume
  is refused as well, so other names for them, such as `\\localhost\C$\…`,
  `\\127.0.0.1\C$\…` or `\\?\UNC\localhost\C$\…`, are refused too. A folder
  is also refused while its identity, its volume root or the identity of one
  of those existing folders cannot be read, for example
  `refusing to delete '<path>': its identity could not be read (<reason>), so it cannot be told apart from the home directory; delete its contents instead, or use exec.run if this is intended`.
  A link itself is deleted without what it leads to.
- The host transfers a file as `fs.write` pieces to `<path>.alcove-part`,
  compares `fs.stat` with `sha256` against its own digest and then renames;
  the first piece carries `executable`: true when the host file, or the file a host link leads to, has an execute bit, false otherwise;
  downloads use `fs.stat` with `sha256` and `fs.read` pieces.

### Limits

| What | Limit |
|---|---|
| One message read by the agent (a line with its newline) | 1 MiB (`proto.MaxLine`); a longer line closes the connection |
| Binary payload of one `fs.read` / `fs.write` / `file.chunk` | 256 KiB (262144 bytes) before base64; a larger `fs.write` is refused and a larger `file.chunk` ends the push with `file.done` `error` `a file.chunk carries at most 262144 bytes; send smaller chunks` |
| `exec.run` output | last 200000 bytes per stream |
| `exec` (v1) output | last 200000 bytes of the combined output, starting on a character boundary |
| `exec.list` `cmd` | 4096 characters per job, then `…` |
| `proc.list` `cmd` | 8192 characters per process, then `…` |
| `clipboard.text` / `clipboard.changed` text | 700000 bytes of UTF-8, cut on a character boundary |
| Job output | last 1 MiB per stream; `exec.read` returns at most 262144 bytes per stream |
| Jobs | 64 |
| `fs.list` | 5000 entries |
| `fs.tail` | last 262144 bytes of the file |
| One `win.*` / `ui.*` reply | 8 MiB minus 4 KiB; a larger one answers `the answer to '<op>' is larger than 8 MiB; ask for less with max, depth, limit or length` |
| `ui.tree` | `max` 2000 nodes, `depth` 256, 20 s |
| `ui.find` | `limit` 2000, 12 s, 256 levels |
| `ui.text` | 200000 UTF-16 code units per reply, 22 s |
| Node `value` | 200 characters, then `…` |
| Refs kept by a helper | 20000; beyond that the least recently used half is forgotten |
| Waiting for the helper | 60 s per request |
| One `res` line written by the agent | under 8 MiB minus 64 KiB; a larger answer is replaced by `the answer to '<op>' is larger than the 8 MiB line the host reads; ask for less (a lower max, depth or limit, a narrower path or a name filter)` |
| Time from the hello to `auth` | 10 s, then `refused` |
| One line read before `authed` | 64 KiB (65536 bytes); a longer line is refused |
| Connections between their hello and `authed` | 16; one more closes the oldest of them with `refused` |
| Requests running at once on one connection | 256; one more answers `256 requests are running on this connection; wait for an answer before sending another` without running |

The host reads lines of up to 8 MiB and does not send a `req` longer than
1 MiB. JSON escaping can expand text (a NUL byte becomes six characters; `<`,
`>` and `&` are written as they are), so a reply can be several megabytes
long. The agent encodes every `res` before it writes it and answers with the
error above when the line would reach 8 MiB minus 64 KiB, so no `res` makes
the host close the connection. What bounds the replies before that check:

- `exec.run`, `exec.read`, `fs.read` and `fs.tail` carry at most the payload
  limits in the table.
- `exec.list` is bounded by 64 jobs of at most 4096 characters of `cmd`.
- `proc.list` has one entry per process on the machine, each `cmd` at most
  8192 characters.
- `exec.result` carries at most 200000 bytes of `out`.
- `clipboard.text` and `clipboard.changed` carry at most 700000 bytes of
  text.
- `fs.list` is bounded by 5000 entries, not by bytes. A name is at most 255
  characters on the supported file systems, which keeps a listing of one
  folder under 8 MiB unless the names consist mostly of control characters.
  With `recursive` a name is a relative path and a tree of 5000 entries with
  very long paths can pass the limit; it then answers the error above.

### Known limitations

- PowerShell's `$input` does not decode non-ASCII stdin: with
  `stdin: "가\n"`, `$input` yields `Ω░Ç`, while `[Console]::In.ReadLine()`
  returns `가`. Read stdin through `[Console]::In`.
- With `shell: "cmd"` the output of `cmd.exe` built-ins goes through the OEM
  code page of the hidden console (437 on en-US), so `echo 한글` prints `??`.
  The same command started from the default shell (`cmd /c 'echo 한글'` as a
  PowerShell command) prints UTF-8.
- `findstr` and other programs that buffer until end-of-file print nothing
  to a running job until `exec.write` sends `eof`.
- `app.launch` chooses the window on the first listing that shows a
  candidate and the listing after it. A window that opens later (a main
  window after a splash screen) is not returned; `win.list` and
  `window.opened` show it.
- UI Automation lists only the realized rows of a virtualized list, and the
  first read of a Chromium window after a page load can lack the page.
- A Win32 edit control takes its `name` from the label before it in the
  z-order of its siblings. `ui.act set_value` sometimes moves the edit in
  front of its label; its `name` is then its own text (empty for a password
  field). A `ref` or `automationId` keeps addressing it.
- The helper serves no request while a UI Automation call into an
  unresponsive application waits; windows the system already reports as not
  responding are refused before the call.
- A connection that does not read its events loses them: the agent drops the
  overflow and reports the count with an `events.dropped` event at the place
  of the dropped events.
- The timeout of `exec.run`, the close of its connection and `exec.kill` kill
  a process tree by process id. In the instant between the agent reaping the
  process and stopping its timer, or marking the job exited, that id can
  already belong to another process, whose tree is then killed.
- `timeout_ms` of `exec.run` has no upper bound; the command still ends when
  its connection closes. Start a command that must outlive the connection with
  `exec.start`.
- On Windows the agent's port can stay taken for a moment after the agent
  ends, so a restarted agent may log the `listen on … failed` line before a
  later attempt binds the port (see [Listening](#listening)).
