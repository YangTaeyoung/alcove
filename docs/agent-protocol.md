# Alcove guest agent protocol

Version 1. The agent (`alcove-agent`, Go) runs inside the guest and listens on
TCP port 7645. The engine forwards a host loopback port to it
(`hostfwd=tcp:127.0.0.1:<port>-:7645`); the app connects from the host.
Newline-delimited JSON objects in both directions, discriminated by `t`.

## Handshake

Agent → host on connect:

```
{"t":"hello","v":1,"os":"windows"|"linux","agent":"0.1.0","token":"<uuid>","caps":["clipboard","files","shutdown","resolution"]}
```

`token` is read by the agent from the SMBIOS OEM strings (type 11) that the
engine passes with `-smbios type=11,value=alcove-token=<uuid>`. The app
compares it with the token stored in the VM's `config.json` and drops the
connection on mismatch. The host replies `{"t":"welcome","v":1}`.

## Messages

| Direction | `t` | Fields | Meaning |
|---|---|---|---|
| both | `ping` / `pong` | — | keepalive every 10 s |
| host → agent | `clipboard.set` | `text` (string) | put text on the guest clipboard |
| agent → host | `clipboard.changed` | `text` | the guest clipboard changed (text only in v1; polled via the clipboard sequence number on Windows, `wl-paste --watch`/`xclip` polling on Linux) |
| host → agent | `resolution.set` | `w`, `h` | ask the guest to switch its primary display mode |
| agent → host | `resolution` | `w`, `h` | current primary display mode (sent after hello and on change) |
| host → agent | `file.begin` | `id`, `name`, `size`, `dest` ("desktop"/"downloads") | start a file push |
| host → agent | `file.chunk` | `id`, `data` (base64, ≤ 256 KiB decoded) | file bytes |
| host → agent | `file.end` | `id`, `sha256` | finish; the agent verifies the digest |
| agent → host | `file.done` | `id`, `path` or `error` | result |
| host → agent | `shutdown` | — | graceful OS shutdown (`shutdown /s /t 0` or `systemctl poweroff`) |
| host → agent | `exec` | `cmd` (string) | run a command (test harness only; disabled unless the agent was started with `--allow-exec`) |
| agent → host | `exec.result` | `code`, `out` | output of `exec` |

Unknown `t` values are ignored. Strings are UTF-8; the guest clipboard is
converted from/to UTF-16 on Windows by the agent.
