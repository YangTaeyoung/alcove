# Alcove control protocol (automation API)

Version 1. Lets automation on the Mac — the `alcove-mcp` server for Claude
Code and other agents, `alcovectl`, scripts — drive VMs: list and start them,
take screenshots, move the mouse, click, type, press keys, run shell commands
in the guest, exchange clipboard text and push files.

The same server runs inside the Alcove app (which owns the VMs while it is
running) and inside `alcovectl serve` (headless, when the app is not running).
Clients connect to the unix socket
`~/Library/Application Support/Alcove/control.sock`; a client that cannot
connect may start `alcovectl serve` itself.

Transport: newline-delimited JSON. Request `{"id": n, "op": "...", ...params}`;
response `{"id": n, "ok": true, ...result}` or `{"id": n, "ok": false, "error": "message"}`.
Requests on one connection are handled sequentially. Coordinates are guest
pixels at the resolution of the last screenshot / `vm.status`.

## Operations

| `op` | Params | Result |
|---|---|---|
| `hello` | — | `{version: 1, host: "app"|"headless"}` |
| `vm.list` | — | `{vms: [{name, guestOS, state, width, height, tools: bool}]}` |
| `vm.status` | `name` | `{state, width, height, tools, agentCaps: [...], suspended: bool}` |
| `vm.start` | `name` | `{state}` after the guest is running |
| `vm.stop` | `name`, `force?` | `{state}` after the engine exited (graceful ACPI first) |
| `vm.pause` / `vm.resume` | `name` | `{state}` |
| `vm.screenshot` | `name`, `format?` ("png"), `maxWidth?` | `{png: base64, width, height}` — the full guest frame via QMP screendump; `maxWidth` downsamples (aspect kept) to save tokens |
| `vm.mouse.move` | `name`, `x`, `y` | `{}` |
| `vm.mouse.click` | `name`, `x`, `y`, `button?` ("left"/"right"/"middle"), `count?` (1 or 2), `hold?` ms | `{}` — moves, presses, releases |
| `vm.mouse.drag` | `name`, `fromX`, `fromY`, `toX`, `toY`, `button?` | `{}` |
| `vm.mouse.scroll` | `name`, `x`, `y`, `dx?`, `dy?` (notches, +down) | `{}` |
| `vm.key.press` | `name`, `keys` (string like "ctrl+alt+delete", "enter", "win+r"), `hold?` ms | `{}` — presses modifiers then the key, releases in reverse |
| `vm.key.down` / `vm.key.up` | `name`, `key` | `{}` |
| `vm.type` | `name`, `text`, `delay?` ms per key | `{}` — US-layout text typing; characters outside the layout use the guest clipboard + paste when tools are connected |
| `vm.exec` | `name`, `command`, `timeout?` s | `{code, output}` — PowerShell on Windows, `/bin/sh` on Linux, through the guest agent (requires tools; the agent must allow exec) |
| `vm.clipboard.get` / `vm.clipboard.set` | `name` / `name`, `text` | `{text}` / `{}` |
| `vm.push_file` | `name`, `path` (host), `dest?` ("desktop"/"downloads") | `{guestPath}` |
| `vm.wait_idle` | `name`, `seconds?` (stable period), `timeout?` | `{}` — returns when the frame stops changing |

Key names: letters, digits, `enter return tab space esc escape backspace delete
insert home end pageup pagedown up down left right f1..f20 capslock
printscreen`, modifiers `ctrl control alt option shift win cmd meta super`,
punctuation by character (`-` `=` `[` `]` `;` `'` `,` `.` `/` `` ` `` `\`).
Combos use `+`. Names are case-insensitive.

Errors are plain strings that say what to do next
("VM 'Win' is stopped; call vm.start first", "guest tools not connected").
