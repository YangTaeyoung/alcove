# QEMU 11.1.1 notes: qmp-commands
Source tree: build/qemu-src (tag v11.1.1). Every claim cites path:line. Produced by parallel research agents and checked by two skeptical reviewers; reviewer corrections could NOT be applied automatically (session limit) and are listed verbatim at the end — treat them as overriding the body where they conflict.

# QEMU 11.1.1 QMP reference for a VM-manager client

Source tree: `/Users/giraffewithcode/dev/personal/alcove/build/qemu-src` (VERSION file = `11.1.1`). All paths below are relative to that root. Schema notation: `'*name'` = optional member; unprefixed = required. Types are QAPI types (`str`, `int`, `bool`, `uint32`, `uint64`, `size`, `number`).

---

## 1. Wire protocol (docs/interop/qmp-spec.rst)

| Item | Format | Citation |
|---|---|---|
| Encoding | Server expects UTF-8 input, emits ASCII; every server message is a json-object terminated by CRLF | docs/interop/qmp-spec.rst:37-38, 56-57 |
| Greeting (sent immediately on connect) | `{ "QMP": { "version": json-object, "capabilities": json-array } }` — `version` has the same shape as `query-version`'s return | docs/interop/qmp-spec.rst:69-81 |
| Greeting builder | `qmp_greeting()` marshals `query-version` and lists offered capabilities: `{'QMP': {'version': %p, 'capabilities': %p}}` | monitor/qmp.c:552-572 |
| Greeting sent on | `CHR_EVENT_OPENED`; monitor enters capability-negotiation mode | monitor/qmp.c:617-626 |
| `oob` offered only if | the chardev supports a GContext (i.e. can run in the monitor iothread) | monitor/qmp.c:173-177, 184-190 |
| Command | `{ "execute": json-string, "arguments": json-object, "id": json-value }` (or `"exec-oob"`); `arguments` optional if none; `id` optional, any json-value | docs/interop/qmp-spec.rst:95-118 |
| Success | `{ "return": json-value, "id": json-value }` — `return` is `{}` for commands with no data | docs/interop/qmp-spec.rst:165-179 |
| Error | `{ "error": { "class": json-string, "desc": json-string }, "id": json-value }` | docs/interop/qmp-spec.rst:184-200 |
| Event | `{ "event": json-string, "data": json-object, "timestamp": { "seconds": n, "microseconds": n } }`; `data` optional; timestamp is -1/-1 on host-time failure; some events rate-limited to 1/s | docs/interop/qmp-spec.rst:209-232 |
| Capabilities mode | Only `qmp_capabilities` accepted; other commands return `CommandNotFound`; **events are not delivered until negotiation completes** | docs/interop/qmp-spec.rst:336-349; monitor/qmp.c:160-171, 283-292 |
| Parser recovery | Send an ASCII control char (not `\t`, `\r`, `\n`), or `0xFF` for old servers | docs/interop/qmp-spec.rst:237-246 |
| OOB in-flight limit | Keep at most 8 in-band commands in flight | docs/interop/qmp-spec.rst:145-146 |
| Example greeting | `{"QMP": {"version": {"qemu": {"micro": 0, "minor": 0, "major": 3}, "package": "v3.0.0"}, "capabilities": ["oob"]}}` | docs/interop/qmp-spec.rst:273-274 |

---

## 2. Starting QEMU with a QMP UNIX socket server

### Options (qemu-options.hx)

```
-qmp dev        like -monitor but opens in 'control' mode          (qemu-options.hx:4964-4966)
-qmp-pretty dev like -qmp but uses pretty JSON formatting            (qemu-options.hx:4979-4981)
-mon [chardev=]name[,mode=readline|control][,pretty=on|off]          (qemu-options.hx:4987-4988)
-chardev socket,id=id,path=path[,server=on|off][,wait=on|off][,telnet=on|off][,websocket=on|off][,reconnect-ms=milliseconds]
         [,mux=on|off][,logfile=PATH][,logappend=on|off][,abstract=on|off][,tight=on|off] (unix)
                                                                     (qemu-options.hx:4087-4088)
```

Documented examples:

```
-qmp tcp:localhost:4444,server=on,wait=off                            (qemu-options.hx:4972)
-chardev socket,id=mon1,host=localhost,port=4444,server=on,wait=off \
-mon chardev=mon1,mode=control,pretty=on                              (qemu-options.hx:5002-5003)
```

The `-qmp dev` short form takes the same device strings as `-serial`; the unix form is `unix:path[,server=on|off][,wait=on|off][,reconnect-ms=milliseconds]` (qemu-options.hx:4905-4908). So a UNIX-socket QMP server is either:

```
-qmp unix:/run/vm/qmp.sock,server=on,wait=off
```
or the explicit form
```
-chardev socket,id=qmp0,path=/run/vm/qmp.sock,server=on,wait=off -mon chardev=qmp0,mode=control
```

Semantics of `server`/`wait`:
- `server=on|off` "specifies that the socket shall be a listening socket"; `wait=on|off` "specifies that QEMU should not block waiting for a client to connect to a listening socket" (qemu-options.hx:4208-4211).
- **Default for `wait` on the CLI is `true` whenever `server=on`** (chardev/char-socket.c:1485-1486: `sock->has_wait = qemu_opt_find(opts, "wait") || sock->server; sock->wait = qemu_opt_get_bool(opts, "wait", true);`). Therefore `wait=off` must be passed explicitly or QEMU blocks at startup until a client connects.
- `path` is required for unix sockets; `abstract=on|off` (default off), `tight=on|off` (default on) (qemu-options.hx:4259-4265).

### Multiple QMP monitors

Allowed. Each `-qmp`/`-mon mode=control` is sugar for `-object monitor-qmp`, "each use of which creates an object with the ID `compat_monitorNNN` where NNN is a counter starting from 0" (qemu-options.hx:4974-4977, 5012-5015; monitor/monitor.c:706-711 `monitor_compat_id`). Monitors are inserted into the global `mon_list` without any count restriction (monitor/monitor.c:606-618 `monitor_list_append`; monitor/qmp.c:690-701 `monitor_new_qmp`, 703-745 `monitor_qmp_complete`). No documentation sentence explicitly stating a monitor limit was found (NOT FOUND in docs/interop, docs/system grep). `MonitorOptions` QAPI struct: `{ '*id': 'str', '*mode': 'MonitorMode', '*pretty': 'bool', 'chardev': 'str' }` (qapi/control.json:207-214); `MonitorMode` = `['readline', 'control']` (qapi/control.json:189).

---

## 3. Session commands (qapi/control.json)

### `qmp_capabilities`
```
{ 'command': 'qmp_capabilities',
  'data': { '*enable': [ 'QMPCapability' ] },
  'allow-preconfig': true }                                   (qapi/control.json:38-40)
{ 'enum': 'QMPCapability', 'data': [ 'oob' ] }                (qapi/control.json:53-54)
```
Return: `{}`. Must be the first command; fails once the monitor accepts other commands; omitting `enable` enables nothing (qapi/control.json:16-34). Example: `{"execute":"qmp_capabilities","arguments":{"enable":["oob"]}}` (qapi/control.json:23-25).

### `query-version`
```
{ 'command': 'query-version', 'returns': 'VersionInfo', 'allow-preconfig': true }  (qapi/control.json:116-117)
{ 'struct': 'VersionTriple', 'data': {'major': 'int', 'minor': 'int', 'micro': 'int'} }  (69-70)
{ 'struct': 'VersionInfo',   'data': {'qemu': 'VersionTriple', 'package': 'str'} }         (90-91)
```
`package` is always `""` upstream (qapi/control.json:83-86).

### `query-commands`
```
{ 'command': 'query-commands', 'returns': ['CommandInfo'], 'allow-preconfig': true }  (qapi/control.json:156-157)
{ 'struct': 'CommandInfo', 'data': {'name': 'str'} }                                  (128)
```

### `quit`
```
{ 'command': 'quit', 'allow-preconfig': true }               (qapi/control.json:175-176)
```
Return `{}` but "a premature EOF would not be unexpected" (qapi/control.json:164-166). Implementation: sets `shutdown_action = SHUTDOWN_ACTION_POWEROFF` and requests shutdown with cause `host-qmp-quit` (monitor/qmp-cmds.c:44-48), which forces exit even with `-no-shutdown` (system/runstate.c:845-847). A `SHUTDOWN` event with `reason: "host-qmp-quit"` is emitted (system/runstate.c:857-861).

---

## 4. Run-state commands and RunState

### `query-status`
```
{ 'command': 'query-status', 'returns': 'StatusInfo', 'allow-preconfig': true }   (qapi/run-state.json:132-133)
{ 'struct': 'StatusInfo', 'data': {'running': 'bool', 'status': 'RunState'} }     (115-117)
```
`running`: true if all vCPUs are runnable (qapi/run-state.json:109).

### `RunState` enum (qapi/run-state.json:58-62)
```
{ 'enum': 'RunState',
  'data': [ 'debug', 'inmigrate', 'internal-error', 'io-error', 'paused',
            'postmigrate', 'prelaunch', 'finish-migrate', 'restore-vm',
            'running', 'save-vm', 'shutdown', 'suspended', 'watchdog',
            'guest-panicked', 'colo' ] }
```
Meanings (qapi/run-state.json:16-56): `inmigrate` = paused waiting for incoming migration (does not say whether it will start; depends on `-S`, `stop`, `cont`); `paused` = stopped via `stop`; `postmigrate` = paused after successful `migrate`; `prelaunch` = started with `-S`; `restore-vm`/`save-vm` = paused to load/save VM state; `shutdown` = guest shut down and `-no-shutdown` in use; `io-error`; `guest-panicked`; `suspended` (ACPI S3).

### `ShutdownCause` enum (qapi/run-state.json:98-102)
```
{ 'enum': 'ShutdownCause',
  'data': [ 'none', 'host-error', 'host-qmp-quit', 'host-qmp-system-reset',
            'host-signal', 'host-ui', 'guest-shutdown', 'guest-reset',
            'guest-panic', 'subsystem-reset', 'snapshot-load'] }
```
`snapshot-load` never appears in QMP (qapi/run-state.json:94-96).

### `stop`
```
{ 'command': 'stop' }                                         (qapi/misc.json:158)
```
Succeeds if already stopped; in `inmigrate` it only ensures the guest stays paused after migration (as with `-S`); in `suspended` transitions to `paused` (qapi/misc.json:145-151). Implementation: in `inmigrate` sets `autostart = 0`, else `vm_stop(RUN_STATE_PAUSED)` (monitor/qmp-cmds.c:50-64). Emits `STOP` (system/cpus.c:310).

### `cont`
```
{ 'command': 'cont' }                                         (qapi/misc.json:182)
```
Succeeds if running; in `inmigrate` makes guest start after migration (removes `-S` effect); if previously suspended goes back to `suspended` (qapi/misc.json:167-175). Errors: "Resetting the Virtual Machine is required" when `runstate_needs_reset()`, "Migration is not finalized yet" in `finish-migrate`, COLO (monitor/qmp-cmds.c:79-90). Resets block iostatus for all BlockBackends and block jobs (92-101). In `inmigrate` sets `autostart = 1` (103-104). Emits `RESUME` (system/cpus.c:794).

### `system_powerdown`
```
{ 'command': 'system_powerdown' }                             (qapi/machine.json:378)
```
Requests ACPI-style powerdown; "A guest may or may not respond"; return does not mean the guest accepted (qapi/machine.json:368-371). Impl: `qemu_system_powerdown_request()` (hw/core/machine-qmp-cmds.c:308-311). `POWERDOWN` event emitted when delivered (system/runstate.c:851-855).

### `system_reset`
```
{ 'command': 'system_reset' }                                 (qapi/machine.json:359)
```
Hard reset. Impl: `qemu_system_reset_request(SHUTDOWN_CAUSE_HOST_QMP_SYSTEM_RESET)` (hw/core/machine-qmp-cmds.c:303-306). Emits `RESET` with `guest:false, reason:"host-qmp-system-reset"` (system/runstate.c:569).

---

## 5. Block commands

### `query-block`
```
{ 'command': 'query-block', 'returns': ['BlockInfo'],
  'data': { '*flat': 'bool' }, 'allow-preconfig': true }      (qapi/block-core.json:951-953)

{ 'struct': 'BlockInfo',
  'data': {'device': 'str', '*qdev': 'str', 'type': 'str', 'removable': 'bool',
           'locked': 'bool', '*inserted': 'BlockDeviceInfo',
           '*tray_open': 'bool', '*io-status': 'BlockDeviceIoStatus' } }   (814-817)
{ 'enum': 'BlockDeviceIoStatus', 'data': [ 'ok', 'failed', 'nospace' ] }  (683)
```
`device` = legacy drive name (may be `""`), `qdev` = qdev ID or QOM path (since 2.10), `type` always `"unknown"`, `tray_open` only if the device has a tray, `io-status` only for virtio-blk/IDE/SCSI when configured to stop on errors (qapi/block-core.json:788-810). `flat=true` omits `inserted.image.backing-image` (858-860). Implicitly-created filter nodes are skipped (862-863).

```
{ 'struct': 'BlockDeviceInfo',
  'data': { 'file': 'str', 'node-name': 'str', 'ro': 'bool', 'drv': 'str',
            '*backing_file': 'str', 'backing_file_depth': 'int',
            'children': ['BlockdevChild'],
            'active': 'bool', 'encrypted': 'bool',
            'detect_zeroes': 'BlockdevDetectZeroesOptions',
            'bps': 'int', 'bps_rd': 'int', 'bps_wr': 'int',
            'iops': 'int', 'iops_rd': 'int', 'iops_wr': 'int',
            'image': 'ImageInfo',
            '*bps_max': 'int', '*bps_rd_max': 'int', '*bps_wr_max': 'int', '*iops_max': 'int',
            '*iops_rd_max': 'int', '*iops_wr_max': 'int',
            '*bps_max_length': 'int', '*bps_rd_max_length': 'int', '*bps_wr_max_length': 'int',
            '*iops_max_length': 'int', '*iops_rd_max_length': 'int', '*iops_wr_max_length': 'int',
            '*iops_size': 'int', '*group': 'str', 'cache': 'BlockdevCacheInfo',
            'write_threshold': 'int', '*dirty-bitmaps': ['BlockDirtyInfo'] } }   (651-667)
{ 'struct': 'BlockdevCacheInfo', 'data': { 'writeback': 'bool', 'direct': 'bool', 'no-flush': 'bool' } } (534-537)
{ 'struct': 'ImageInfo', 'base': 'BlockNodeInfo', 'data': { '*backing-image': 'ImageInfo' } }          (397-401)
{ 'struct': 'BlockNodeInfo',
  'data': {'filename': 'str', 'format': 'str', '*dirty-flag': 'bool',
           '*actual-size': 'int', 'virtual-size': 'int',
           '*cluster-size': 'int', '*encrypted': 'bool', '*compressed': 'bool',
           '*backing-filename': 'str', '*full-backing-filename': 'str',
           '*backing-filename-format': 'str', '*snapshots': ['SnapshotInfo'],
           '*limits': 'BlockLimitsInfo', '*format-specific': 'ImageInfoSpecific' } }          (378-385)
{ 'struct': 'SnapshotInfo',
  'data': { 'id': 'str', 'name': 'str', 'vm-state-size': 'int',
            'date-sec': 'int', 'date-nsec': 'int',
            'vm-clock-sec': 'int', 'vm-clock-nsec': 'int', '*icount': 'int' } }             (40-44)
```
`inserted.image.snapshots[]` lists existing internal snapshots (useful to enumerate qcow2 snapshots without HMP).

### `query-named-block-nodes`
```
{ 'command': 'query-named-block-nodes',
  'returns': [ 'BlockDeviceInfo' ],
  'data': { '*flat': 'bool' }, 'allow-preconfig': true }      (qapi/block-core.json:2103-2106)
```
Each entry carries `node-name` (BlockDeviceInfo, 652) — this is the value to pass in `snapshot-save.devices`/`vmstate`.

### `blockdev-add` / `blockdev-del`
```
{ 'command': 'blockdev-add', 'data': 'BlockdevOptions', 'boxed': true, 'allow-preconfig': true }   (4976-4977)
{ 'command': 'blockdev-del', 'data': { 'node-name': 'str' }, 'allow-preconfig': true }             (5056-5057)

{ 'union': 'BlockdevOptions',
  'base': { 'driver': 'BlockdevDriver', '*node-name': 'str',
            '*discard': 'BlockdevDiscardOptions', '*cache': 'BlockdevCacheOptions',
            '*active': 'bool', '*read-only': 'bool', '*auto-read-only': 'bool',
            '*force-share': 'bool', '*detect-zeroes': 'BlockdevDetectZeroesOptions' },
  'discriminator': 'driver',
  'data': { ... 'file': 'BlockdevOptionsFile', 'qcow2': 'BlockdevOptionsQcow2', 'raw': 'BlockdevOptionsRaw',
            'host_cdrom'/'host_device': BlockdevOptionsFile (if HAVE_HOST_BLOCK_DEVICE) ... } }   (4823-4892)
{ 'enum': 'BlockdevDriver', 'data': [ ... 'file', ... 'qcow2', ... 'raw', ... ] }                   (3339-3357)
{ 'struct': 'BlockdevOptionsFile',
  'data': { 'filename': 'str', '*pr-manager': 'str', '*locking': 'OnOffAuto',
            '*aio': 'BlockdevAioOptions', '*aio-max-batch': 'int',
            '*drop-cache': bool (CONFIG_LINUX), '*x-check-cache-dropped': bool (unstable) } }      (3406-3417)
{ 'struct': 'BlockdevOptionsGenericFormat', 'data': { 'file': 'BlockdevRef' } }                     (3492-3493)
{ 'struct': 'BlockdevOptionsGenericCOWFormat', 'base': 'BlockdevOptionsGenericFormat',
  'data': { '*backing': 'BlockdevRefOrNull' } }                                                     (3525-3527)
{ 'struct': 'BlockdevOptionsQcow2', 'base': 'BlockdevOptionsGenericCOWFormat',
  'data': { '*lazy-refcounts': 'bool', ... '*encrypt': 'BlockdevQcow2Encryption', '*data-file': 'BlockdevRef' } } (3751-3765)
{ 'struct': 'BlockdevOptionsRaw', 'base': 'BlockdevOptionsGenericFormat', 'data': { '*offset': 'int', '*size': 'int' } } (4679-4681)
{ 'alternate': 'BlockdevRef', 'data': { 'definition': 'BlockdevOptions', 'reference': 'str' } }     (4905-4907)
```
`node-name` is required at top level of `blockdev-add`; valid names start alphabetic, contain `[A-Za-z0-9._-]`, max 31 chars (4787-4791). `blockdev-del` fails if node is attached/used (5029-5031). Example: `{"execute":"blockdev-add","arguments":{"driver":"qcow2","node-name":"test1","file":{"driver":"file","filename":"test.qcow2"}}}` (4938-4948).

### `blockdev-change-medium`
```
{ 'command': 'blockdev-change-medium',
  'data': { '*device': { 'type': 'str', 'features': [ 'deprecated' ] },
            '*id': 'str',
            'filename': 'str',
            '*format': 'str',
            '*force': 'bool',
            '*read-only-mode': 'BlockdevChangeReadOnlyMode' } }     (qapi/block.json:378-384)
{ 'enum': 'BlockdevChangeReadOnlyMode', 'data': ['retain', 'read-only', 'read-write'] }  (312-313)
```
`id` = qdev ID or QOM path of the guest device (use this; `device` is deprecated); `format` defaults to probed; `read-only-mode` defaults `retain`; `force` (since 7.1) opens tray even if guest-locked (qapi/block.json:324-340). Combines open-tray/remove-medium/insert-medium/close-tray (318-322). Example: `{"execute":"blockdev-change-medium","arguments":{"id":"ide0-1-0","filename":"/srv/images/Fedora-12-x86_64-DVD.iso","format":"raw"}}` (351-355).

### `eject`
```
{ 'command': 'eject',
  'data': { '*device': { 'type': 'str', 'features': [ 'deprecated' ] },
            '*id': 'str', '*force': 'bool' } }                (qapi/block.json:128-131)
```
Ejecting with no media succeeds; `DeviceNotFound` if bad device (116-119). Example `{"execute":"eject","arguments":{"id":"ide1-0-1"}}` (125-126).

### Tray/medium primitives
```
{ 'command': 'blockdev-open-tray',   'data': { '*device': str(deprecated), '*id': 'str', '*force': 'bool' } }  (181-184)
{ 'command': 'blockdev-close-tray',  'data': { '*device': str(deprecated), '*id': 'str' } }                    (219-221)
{ 'command': 'blockdev-remove-medium','data': { 'id': 'str' } }                                                (262-263)
{ 'command': 'blockdev-insert-medium','data': { 'id': 'str', 'node-name': 'str' } }                            (294-296)
{ 'event': 'DEVICE_TRAY_MOVED', 'data': { 'device': 'str', 'id': 'str', 'tray-open': 'bool' } }               (412-413)
```

---

## 6. Device hotplug

### `device_add`
```
{ 'command': 'device_add',
  'data': {'driver': 'str', '*bus': 'str', '*id': 'str'},
  'gen': false,   # so we can get the additional arguments
  'features': ['json-cli', 'json-cli-hotplug'] }              (qapi/qdev.json:81-84)
```
Additional arguments depend on the driver (qapi/qdev.json:57). Implementation `qmp_device_add` -> `qdev_device_add_from_qdict(qdict, from_json=true)` (system/qdev-monitor.c:868-872, 652-750): resolves `driver` (663-673), `bus` via `qbus_find` or default bus (676-692), refuses while migrating ("device_add not allowed while migrating", 704-707), sets `id` (722-725), then applies all remaining keys as QOM properties via `object_set_props_from_keyval(..., from_json=true)` (727-738) — so values are typed JSON (integers for uint32 props), then `qdev_realize` (740).

### `usb-host` over `device_add` (hw/usb/host-libusb.c)
Type name: `#define TYPE_USB_HOST_DEVICE "usb-host"` (hw/usb/host-libusb.c:63). Built only when libusb is found and CONFIG_USB (hw/usb/meson.build:84-87). Properties (hw/usb/host-libusb.c:1761-1782):

```c
static const Property usb_host_dev_properties[] = {
    DEFINE_PROP_UINT32("hostbus",  USBHostDevice, match.bus_num,    0),
    DEFINE_PROP_UINT32("hostaddr", USBHostDevice, match.addr,       0),
    DEFINE_PROP_STRING("hostport", USBHostDevice, match.port),
    DEFINE_PROP_UINT32("vendorid",  USBHostDevice, match.vendor_id,  0),
    DEFINE_PROP_UINT32("productid", USBHostDevice, match.product_id, 0),
#if LIBUSB_API_VERSION >= 0x01000107
    DEFINE_PROP_STRING("hostdevice", USBHostDevice, hostdevice),
#endif
    DEFINE_PROP_UINT32("isobufs",  USBHostDevice, iso_urb_count,    4),
    DEFINE_PROP_UINT32("isobsize", USBHostDevice, iso_urb_frames,   32),
    DEFINE_PROP_BOOL("guest-reset", USBHostDevice, allow_one_guest_reset, true),
    DEFINE_PROP_BOOL("guest-resets-all", USBHostDevice, allow_all_guest_resets, false),
    DEFINE_PROP_UINT32("loglevel",  USBHostDevice, loglevel, LIBUSB_LOG_LEVEL_WARNING),
    DEFINE_PROP_BIT("pipeline",    USBHostDevice, options, USB_HOST_OPT_PIPELINE, true),
    DEFINE_PROP_BOOL("suppress-remote-wake", USBHostDevice, suppress_remote_wake, true),
};
```
Match filter struct (hw/usb/host-libusb.c:70-76): `struct USBAutoFilter { uint32_t bus_num; uint32_t addr; char *port; uint32_t vendor_id; uint32_t product_id; }`.

Realize semantics (hw/usb/host-libusb.c:1181-1253):
- `vendorid > 0xffff` -> error "vendorid out of range"; `productid > 0xffff` -> "productid out of range"; `hostaddr > 127` -> "hostaddr out of range" (1191-1202).
- If `hostdevice` set (Linux-style `/dev/bus/usb/...` path; not on WIN32): opened directly via fd, no autoscan (1211-1224).
- If **only** `hostbus` and `hostaddr` are set (no vendorid/productid/hostport): device is looked up and opened immediately; `device_add` fails with "failed to find host usb device %d:%d" / "failed to open host usb device %d:%d" (1226-1244).
- Otherwise (any vendorid/productid/hostport, or nothing): device is added to the autoscan list and `usb_host_auto_check` runs (1245-1249); **`device_add` returns success even if no matching device is currently present**. Autoscan matching: each non-zero field of `hostbus`, `hostaddr`, `hostport` (string compared to `"%d.%d..."` port path from `libusb_get_port_numbers`, 320-339), `vendorid`, `productid` must match; hubs are skipped; runs only while `runstate_is_running()` (1834-1895).

Example QMP (JSON ints for the uint32 properties):
```json
{"execute":"device_add","arguments":{"driver":"usb-host","id":"usb0","vendorid":4660,"productid":22136}}
{"execute":"device_add","arguments":{"driver":"usb-host","id":"usb1","hostbus":1,"hostaddr":5}}
{"execute":"device_add","arguments":{"driver":"usb-host","id":"usb2","bus":"xhci.0","hostport":"1.2"}}
```
`bus` naming: USB buses are created with `qbus_init(bus, ..., TYPE_USB_BUS, host, NULL)` (hw/usb/bus.c:83-90); with name NULL the bus is named `"<parent-id>.<n>"` if the controller has an `id`, else `"<lowercased type name>.<n>"` (hw/core/bus.c:111-125). If `bus` is omitted, `qdev_find_default_bus` picks one (system/qdev-monitor.c:687-691).

### `device_del`
```
{ 'command': 'device_del', 'data': {'id': 'str'} }           (qapi/qdev.json:120)
```
`id` = device ID or QOM path; `DeviceNotFound` if invalid (91-94); completion is signaled by `DEVICE_DELETED`; guest-side failure -> `DEVICE_UNPLUG_GUEST_ERROR` (96-104). Impl: errors "Device %s is already in the process of unplug"; calls `qdev_unplug` (system/qdev-monitor.c:951-965). For USB devices the bus is its own hotplug handler with `unplug = qdev_simple_device_unplug_cb` (hw/usb/bus.c:37, 87), which is an immediate `qdev_unrealize(dev)` (hw/core/qdev-hotplug.c:112-116) — no guest cooperation required; `DEVICE_DELETED` fires from device finalize (hw/core/qdev.c:704-711).

### `query-usbhost`
**NOT FOUND** in any `qapi/*.json` (grep for `usbhost` and `usb-host` returned nothing). Only the HMP `info usbhost` exists (hmp-commands-info.hx:343-353: `.name = "usbhost", .help = "show host USB devices"`), reachable via:
```
{ 'command': 'human-monitor-command',
  'data': {'command-line': 'str', '*cpu-index': 'int'},
  'returns': 'str', 'features': [ 'savevm-monitor-nodes' ] }   (qapi/misc.json:247-250)
```
i.e. `{"execute":"human-monitor-command","arguments":{"command-line":"info usbhost"}}` — output is unstable text (qapi/misc.json:228-232).

---

## 7. Internal snapshots (qcow2) — `snapshot-save` / `snapshot-load` / `snapshot-delete`

```
{ 'command': 'snapshot-save',
  'data': { 'job-id': 'str', 'tag': 'str', 'vmstate': 'str', 'devices': ['str'] } }   (qapi/migration.json:2113-2117)
{ 'command': 'snapshot-load',
  'data': { 'job-id': 'str', 'tag': 'str', 'vmstate': 'str', 'devices': ['str'] } }   (2183-2187)
{ 'command': 'snapshot-delete',
  'data': { 'job-id': 'str', 'tag': 'str', 'devices': ['str'] } }                     (2239-2242)
```
All four members are required. `vmstate` = block node name to store/load vmstate; `devices` = list of block **node names** (2052-2058, 2124-2130, 2194-2198). Return `{}` immediately; completion must be tracked via job events (2060-2063). Recommended: `devices` should contain all writable nodes (2069-2070). Existing `tag` -> error (2072).

Implementation facts (migration/savevm.c, block/snapshot.c):
- Jobs are created with `JOB_MANUAL_DISMISS` (savevm.c:3721-3723, 3743-3745, 3764-3766) => the job stays in `concluded` until `job-dismiss` is issued.
- The QMP path always passes `has_devices=true` (savevm.c:3639-3640, 3622, 3653). With an explicit list: empty list -> "At least one device is required for snapshot" (block/snapshot.c:488-492); each name is resolved with `bdrv_find_node` -> "No block device node '%s'" (494-502).
- Every listed node must pass `bdrv_can_snapshot`: inserted, writable, and driver implements `bdrv_snapshot_create` (or a fallback child does) (block/snapshot.c:195-214); otherwise "Device '%s' is writable but does not support snapshots" (532-563). **Only qcow2 and rbd implement `.bdrv_snapshot_create`** (block/qcow2.c:6333, block/rbd.c:1869). Read-only nodes (e.g. ISO media) therefore must NOT be listed.
- `vmstate` must name one of the nodes in `devices` and it must support snapshots: `bdrv_all_find_vmstate_bs` iterates only the `devices` list; errors "vmstate block device '%s' does not support snapshots" / "vmstate block device '%s' does not exist" (block/snapshot.c:736-785).
- `snapshot-save` order: `bdrv_all_can_snapshot` (savevm.c:3287) -> tag existence check "Snapshot '%s' already exists in one or more devices" (3299-3308) -> find vmstate bs (3312) -> `global_state_store(); vm_stop(RUN_STATE_SAVE_VM)` (3317-3318, emits `STOP`, later `RESUME`).
- `snapshot-load`: `vm_stop(RUN_STATE_RESTORE_VM)` (3620) -> checks tag present on all devices "Snapshot '%s' does not exist in one or more devices" (3472-3480) -> refuses disk-only snapshots "This is a disk-only snapshot..." (3492-3496) -> `bdrv_all_goto_snapshot` (3507) -> `qemu_system_reset(SHUTDOWN_CAUSE_SNAPSHOT_LOAD)` (3519) -> `qemu_loadvm_state` (3526) -> on success resumes to the pre-job run state via `load_snapshot_resume(orig_state)` (3623-3625, 3542-3548).
- `snapshot-delete`: `bdrv_all_can_snapshot` then `bdrv_all_delete_snapshot` (3550-3562; block/snapshot.c:565-608).

Job observation:
```
{ 'event': 'JOB_STATUS_CHANGE', 'data': { 'id': 'str', 'status': 'JobStatus' } }        (qapi/job.json:129-131)
{ 'enum': 'JobStatus', 'data': ['undefined', 'created', 'running', 'paused', 'ready', 'standby',
           'waiting', 'pending', 'aborting', 'concluded', 'null' ] }                     (87-89)
{ 'enum': 'JobType', 'data': ['commit', 'stream', 'mirror', 'backup', 'create', 'amend',
           'snapshot-load', 'snapshot-save', 'snapshot-delete'] }                        (39-41)
{ 'command': 'query-jobs', 'returns': ['JobInfo'] }                                       (304)
{ 'struct': 'JobInfo',
  'data': { 'id': 'str', 'type': 'JobType', 'status': 'JobStatus',
            'current-progress': 'int', 'total-progress': 'int', '*error': 'str' } }      (290-293)
{ 'command': 'job-dismiss', 'data': { 'id': 'str' } }                                     (236)
{ 'command': 'job-cancel',  'data': { 'id': 'str' } }                                     (187)
```
`JobInfo.error` present => failed; absent in `concluded` => success (280-286). `job-dismiss` refuses jobs not yet `concluded` (227-230). Expected event sequence for save (documented example): `created` -> `running` -> `STOP` -> `RESUME` -> `waiting` -> `pending` -> `concluded`, then `query-jobs` (qapi/migration.json:2076-2109). Recommended client flow: on `JOB_STATUS_CHANGE{status:"concluded"}` run `query-jobs`, read `error`, then `job-dismiss`.

---

## 8. Migration to/from file (save/restore full VM state)

### `migrate`
```
{ 'command': 'migrate',
  'data': {'*uri': 'str', '*channels': [ 'MigrationChannel' ], '*resume': 'bool' } }   (qapi/migration.json:1460-1463)
```
`uri` and `channels` are mutually exclusive, exactly one required; `channels` has exactly one entry (1416-1420).
```
{ 'struct': 'MigrationChannel', 'data': { 'channel-type': 'MigrationChannelType', 'addr': 'MigrationAddress' } } (1383-1386)
{ 'enum': 'MigrationChannelType', 'data': [ 'main', 'cpr' ] }                                                     (1369-1370)
{ 'union': 'MigrationAddress', 'base': { 'transport' : 'MigrationAddressType'}, 'discriminator': 'transport',
  'data': { 'socket': 'SocketAddress', 'exec': 'MigrationExecCommand', 'rdma': 'InetSocketAddress', 'file': 'FileMigrationArgs' } } (1349-1356)
{ 'enum': 'MigrationAddressType', 'data': [ 'socket', 'exec', 'rdma', 'file' ] }                                 (1314-1315)
{ 'struct': 'FileMigrationArgs', 'data': { 'filename': 'str', 'offset': 'uint64' } }                             (1326-1328)
{ 'struct': 'MigrationExecCommand', 'data': {'args': [ 'str' ] } }                                               (1337-1338)
```
Both `filename` and `offset` are required in the structured form. Documented examples (1424-1458):
```json
{"execute":"migrate","arguments":{"uri":"tcp:0:4446"}}
{"execute":"migrate","arguments":{"channels":[{"channel-type":"main","addr":{"transport":"exec","args":["/bin/nc","-p","6000","/some/sock"]}}]}}
{"execute":"migrate","arguments":{"channels":[{"channel-type":"main","addr":{"transport":"file","filename":"/tmp/migfile","offset":"0x1000"}}]}}
```

URI string parsing (`migrate_uri_parse`, migration/channel.c:353-406):
- `exec:CMD` -> transport `exec` with args `["/bin/sh","-c",CMD]` (or `cmd.exe /c` on Windows) (361-370); spawned via `qio_channel_command_new_spawn` (migration/exec.c:43-59 outgoing, 70-88 incoming).
- `tcp:`, `unix:`, `vsock:`, `fd:` -> `socket` (377-389).
- `file:PATH[,offset=N]` -> transport `file`; `offset` stripped by `file_parse_offset` using `qemu_strtosz` (size suffixes or `0x`, "not both" per docs) (390-396; migration/file.c:22, 30-45; qemu-options.hx:5443-5445).
- Unknown prefix -> "unknown migration protocol: %s" (397-399).

File transport behaviour: outgoing opens `O_CREAT|O_WRONLY` mode 0600, `ftruncate` to `offset`, seeks to `offset` (migration/file.c:96-130); incoming opens `O_RDONLY` and seeks to `offset` (180-200). File transport is seekable and can be opened multiple times (supports `mapped-ram` and multifd) (migration/migration.c:185-186, 207-220). Optional `mapped-ram` capability + `file:` URI documented in docs/devel/migration/mapped-ram.rst:25-33.

Preconditions in `migrate_prepare` (migration/migration.c:1956-2011): error if a migration is running, if runstate is `inmigrate` ("Guest is waiting for an incoming migration"), or `postmigrate` ("Can't migrate the vm that was paused due to previous migration"). On `completed` the source enters `RUN_STATE_POSTMIGRATE` (3470-3473); a save-to-file flow is therefore `migrate` -> wait for `completed` -> `quit`.

### `migrate-set-capabilities` / `query-migrate-capabilities`
```
{ 'command': 'migrate-set-capabilities', 'data': { 'capabilities': ['MigrationCapabilityStatus'] } }  (575-576)
{ 'struct': 'MigrationCapabilityStatus', 'data': { 'capability': 'MigrationCapability', 'state': 'bool' } } (557-558)
{ 'enum': 'MigrationCapability',
  'data': ['xbzrle', 'rdma-pin-all', 'auto-converge', 'events', 'postcopy-ram',
           { 'name': 'x-colo', 'features': [ 'unstable' ] }, 'release-ram',
           'return-path', 'pause-before-switchover', 'multifd', 'dirty-bitmaps', 'postcopy-blocktime',
           'late-block-activate', { 'name': 'x-ignore-shared', 'features': [ 'unstable' ] },
           'validate-uuid', 'background-snapshot', 'zero-copy-send', 'postcopy-preempt', 'switchover-ack',
           'dirty-limit', 'mapped-ram'] }                                                            (534-544)
{ 'command': 'query-migrate-capabilities', 'returns': ['MigrationCapabilityStatus']}                 (597)
```
**The `MIGRATION` event is emitted only when the `events` capability is enabled** (`migrate_generate_event`: `if (migrate_events()) qapi_event_send_migration(new_state)`, migration/migration.c:499-504; `migrate_events()` reads `capabilities[MIGRATION_CAPABILITY_EVENTS]`, migration/options.c:339-344). Enable with `{"execute":"migrate-set-capabilities","arguments":{"capabilities":[{"capability":"events","state":true}]}}` before `migrate`.

### `query-migrate`
```
{ 'command': 'query-migrate', 'returns': 'MigrationInfo' }   (434)
{ 'struct': 'MigrationInfo',
  'data': {'*status': 'MigrationStatus', '*ram': 'MigrationRAMStats', '*remaining': 'size',
           '*vfio': 'VfioStats', '*xbzrle-cache': 'XBZRLECacheStats',
           '*total-time': 'int', '*expected-downtime': 'int', '*downtime': 'int', '*setup-time': 'int',
           '*cpu-throttle-percentage': 'int', '*error-desc': 'str', '*blocked-reasons': ['str'],
           '*postcopy-blocktime': 'uint32', '*postcopy-vcpu-blocktime': ['uint32'],
           '*postcopy-latency': uint64 (unstable), '*postcopy-latency-dist': [uint64] (unstable),
           '*postcopy-vcpu-latency': [uint64] (unstable), '*postcopy-non-vcpu-latency': uint64 (unstable),
           '*socket-address': ['SocketAddress'],
           '*dirty-limit-throttle-time-per-round': 'uint64', '*dirty-limit-ring-full-time': 'uint64'} }  (314-338)
{ 'struct': 'MigrationRAMStats',
  'data': {'transferred': 'int', 'remaining': 'int', 'total': 'int', 'duplicate': 'int', 'normal': 'int',
           'normal-bytes': 'int', 'dirty-pages-rate': 'int', 'mbps': 'number', 'dirty-sync-count': 'int',
           'postcopy-requests': 'int', 'page-size': 'int', 'multifd-bytes': 'uint64', 'pages-per-second': 'uint64',
           'precopy-bytes': 'uint64', 'downtime-bytes': 'uint64', 'postcopy-bytes': 'uint64',
           'dirty-sync-missed-zero-copy': 'uint64' } }                                                (67-77)
{ 'enum': 'MigrationStatus',
  'data': [ 'none', 'setup', 'cancelling', 'cancelled', 'active', 'postcopy-device', 'postcopy-active',
            'postcopy-paused', 'postcopy-recover-setup', 'postcopy-recover', 'completed', 'failing', 'failed',
            'colo', 'pre-switchover', 'device', 'wait-unplug' ] }                                    (183-188)
```
`status` absent => no migration ever started; returns `{}` (208-210, 351-352). `error-desc` human-readable on failure (240-241). `failing` (since 11.0) precedes `failed` (161-164).

### `migrate_cancel`
```
{ 'command': 'migrate_cancel' }                              (1280)
```
Succeeds even if nothing is running; not allowed after postcopy started (1264-1271).

### `MIGRATION` event
```
{ 'event': 'MIGRATION', 'data': {'status': 'MigrationStatus'}}   (1114-1115)
{ 'event': 'MIGRATION_PASS', 'data': { 'pass': 'int' } }         (1132-1133)
```

### `-incoming` / `migrate-incoming` (restore)
```
-incoming file:filename[,offset=offset]          (qemu-options.hx:5416, 5443-5445)
-incoming exec:cmdline                           (5417, 5447-5449)
-incoming unix:socketpath | tcp:[host]:port | fd:fd | <channel JSON/keyval> | defer   (5410-5423, 5451-5467)
```
```
{ 'command': 'migrate-incoming',
  'data': {'*uri': 'str', '*channels': [ 'MigrationChannel' ], '*exit-on-error': 'bool' } }   (qapi/migration.json:1532-1535)
```
`migrate-incoming` requires `-incoming defer` (1468-1469, 1490-1491); `exit-on-error` defaults true — set false to get a `MIGRATION` event and `query-migrate.error-desc` instead of process exit (1477-1480).

Semantics of restore:
- The first `-incoming` sets runstate to `inmigrate` at option parse (system/vl.c:3559-3562); `-loadvm` and `-incoming` are mutually exclusive (2536-2537).
- Non-`defer` URIs are started automatically after machine creation by calling `qmp_migrate_incoming(NULL, true, channels, true, true, ...)` — i.e. `exit-on-error=true`, so a failed restore exits QEMU (system/vl.c:2836-2848).
- When the incoming stream finishes: if the source runstate was live and `autostart` is set, block devices are activated and `vm_start()` is called; if `-S` was given (`autostart = 0`, system/vl.c:3174-3175) the VM is left in `paused` (migration/migration.c:697-716); then status becomes `completed` (728-729). `stop` during `inmigrate` clears `autostart`, `cont` sets it (monitor/qmp-cmds.c:59-60, 103-104).
- `-S` = "freeze CPU at startup" (qemu-options.hx:5051-5057).

---

## 9. Display, input, network, CPU, memory, balloon

### `screendump`
```
{ 'command': 'screendump',
  'data': {'filename': 'str', '*device': 'str', '*head': 'int', '*format': 'ImageFormat'},
  'coroutine': true, 'if': 'CONFIG_PIXMAN' }                  (qapi/ui.json:198-202)
{ 'enum': 'ImageFormat', 'data': ['ppm', 'png'] }             (169-170)
```
Default format `ppm`; `device` = display device ID (default primary display); `head` only with `device` (177-188). Impl (ui/ui-qmp-cmds.c:323-389): error "'head' must be specified together with 'device'" (340-343); "There is no console to take a screendump from" (344-348); file created with `O_WRONLY|O_TRUNC` mode 0666 (368); `png` requires CONFIG_PNG, else error "Enable PNG support with libpng for screendump" (282-290). The file is removed on encode failure (380-387).

### `input-send-event` (QMP input path, alternative to VNC/SPICE input)
```
{ 'command': 'input-send-event',
  'data': { '*device': 'str', '*head': 'int', 'events': [ 'InputEvent' ] } }   (qapi/ui.json:1312-1315)

{ 'union' : 'InputEvent', 'base': { 'type': 'InputEventKind' }, 'discriminator': 'type',
  'data'  : { 'key': 'InputKeyEventWrapper', 'btn': 'InputBtnEventWrapper',
              'rel': 'InputMoveEventWrapper', 'abs': 'InputMoveEventWrapper',
              'mtt': 'InputMultiTouchEventWrapper' } }                          (1236-1243)
{ 'enum': 'InputEventKind', 'data': [ 'key', 'btn', 'rel', 'abs', 'mtt' ] }   (1184-1185)
# each wrapper is { 'data': <event struct> }                                    (1194-1225)
{ 'struct': 'InputKeyEvent',  'data': { 'key': 'KeyValue', 'down': 'bool' } }            (1109-1111)
{ 'struct': 'InputBtnEvent',  'data': { 'button': 'InputButton', 'down': 'bool' } }      (1124-1126)
{ 'struct': 'InputMoveEvent', 'data': { 'axis': 'InputAxis', 'value': 'int' } }          (1140-1142)
{ 'struct': 'InputMultiTouchEvent', 'data': { 'type': 'InputMultiTouchType', 'slot': 'int',
              'tracking-id': 'int', 'axis': 'InputAxis', 'value': 'int' } }              (1162-1167)
{ 'enum': 'InputButton', 'data': [ 'left', 'middle', 'right', 'wheel-up', 'wheel-down', 'side',
  'extra', 'wheel-left', 'wheel-right', 'touch' ] }                                      (1064-1066)
{ 'enum': 'InputAxis', 'data': [ 'x', 'y' ] }                                            (1075-1076)
{ 'enum': 'InputMultiTouchType', 'data': [ 'begin', 'update', 'end', 'cancel', 'data' ] } (1095-1096)
{ 'union': 'KeyValue', 'base': { 'type': 'KeyValueKind' }, 'discriminator': 'type',
  'data': { 'number': 'IntWrapper', 'qcode': 'QKeyCodeWrapper' } }                       (1015-1020)
{ 'enum': 'KeyValueKind', 'data': [ 'number', 'qcode' ] }                                (983-984)
{ 'struct': 'IntWrapper', 'data': { 'data': 'int' } }  /  { 'struct': 'QKeyCodeWrapper', 'data': { 'data': 'QKeyCode' } } (993-994, 1003-1004)
{ 'enum': 'QKeyCode', 'prefix': 'Q_KEY_CODE', 'data': [ 'unmapped', 'shift', 'shift_r', 'alt', 'alt_r', 'ctrl',
  'ctrl_r', 'menu', 'esc', '1', ... 'ret', ... 'spc', ... 'f1'..'f12', ... 'left','up','down','right', ...
  'meta_l', 'meta_r', ... 'f13'..'f24' ] }                                                (952-976)
```
Absolute coordinates range 0..0x7fff (1135-1136). Examples (1278-1310):
```json
{"execute":"input-send-event","arguments":{"device":"video0","events":[{"type":"btn","data":{"down":true,"button":"left"}}]}}
{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"ctrl"}}}]}}
{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":20000}},{"type":"abs","data":{"axis":"y","value":400}}]}}
```
Impl constraints (ui/input.c:155-189): error "VM not running" unless running or suspended (175-178); every event kind needs a registered handler for the (optional) console — "Input handler not found for event type %s" (180-189) — e.g. `abs` needs an absolute pointer device such as a tablet. Key `number` values are sent raw; `qcode` converted via `qemu_input_key_value_to_linux` (199). Also available: `send-key` `{ 'keys': ['KeyValue'], '*hold-time': 'int' }` (1048-1049), default hold 100 ms.

### `set_link`
```
{ 'command': 'set_link', 'data': {'name': 'str', 'up': 'bool'} }   (qapi/net.json:37)
```
`name` = NIC device name (e.g. `"e1000.0"`); succeeds even if the adapter does not support link status; `DeviceNotFound` otherwise (18-34).

### `query-cpus-fast`
```
{ 'command': 'query-cpus-fast', 'returns': [ 'CpuInfoFast' ] }   (qapi/machine.json:142)
{ 'union': 'CpuInfoFast',
  'base': { 'cpu-index': 'int', 'qom-type': 'str', 'qom-path': 'str', 'thread-id': 'int',
            '*props': 'CpuInstanceProperties', 'target': 'SysEmuTarget' },
  'discriminator': 'target', 'data': { 's390x': 'CpuInfoS390' } }   (96-104)
```

### `query-memory-size-summary`
```
{ 'command': 'query-memory-size-summary', 'returns': 'MemoryInfo' }                       (qapi/machine.json:1271)
{ 'struct': 'MemoryInfo', 'data': { 'base-memory': 'size', '*plugged-memory': 'size' } }  (1253-1254)
```

### `balloon` / `query-balloon` / `BALLOON_CHANGE`
```
{ 'command': 'balloon', 'data': {'value': 'int'} }                    (qapi/machine.json:1120)
{ 'command': 'query-balloon', 'returns': 'BalloonInfo' }              (1154)
{ 'struct': 'BalloonInfo', 'data': {'actual': 'int' } }               (1132)
{ 'event': 'BALLOON_CHANGE', 'data': { 'actual': 'int' } }            (1176-1177)
```
`value` = target logical VM size in bytes (`balloon_size = vm_ram_size - value`); errors `KVMMissingCap`, `DeviceNotActive` if no balloon device; request only (1092-1106). `BALLOON_CHANGE` is rate-limited (1166).

---

## 10. Events a manager should subscribe to

| Event | Data | Citation / notes |
|---|---|---|
| `SHUTDOWN` | `{ 'guest': 'bool', 'reason': 'ShutdownCause' }` | qapi/run-state.json:161. With `-no-shutdown` QEMU does not exit and a `STOP` follows (149-151). Emitted from system/runstate.c:857-861. `quit` gives `reason:"host-qmp-quit"`. |
| `POWERDOWN` | none | qapi/run-state.json:176; emitted when powerdown is delivered to the guest (system/runstate.c:851-855). |
| `RESET` | `{ 'guest': 'bool', 'reason': 'ShutdownCause' }` | qapi/run-state.json:198; system/runstate.c:569. |
| `STOP` | none | qapi/run-state.json:212; system/cpus.c:310. |
| `RESUME` | none | qapi/run-state.json:226; system/cpus.c:794. |
| `SUSPEND` / `SUSPEND_DISK` / `WAKEUP` | none | qapi/run-state.json:241, 260, 275. |
| `WATCHDOG` | `{ 'action': 'WatchdogAction' }`, `['reset','shutdown','poweroff','pause','debug','none','inject-nmi']` | qapi/run-state.json:298-299, 325-327; rate-limited. |
| `GUEST_PANICKED` | `{ 'action': 'GuestPanicAction', '*info': 'GuestPanicInformation' }`; action `['pause','poweroff','run']`; info union discriminated by `type` in `['hyper-v','s390','tdx','sev']` | qapi/run-state.json:443-444, 493-494, 511-529; emitted at system/runstate.c:675-683. Guest ends in RunState `guest-panicked` when action is pause. |
| `GUEST_CRASHLOADED` | same shape as GUEST_PANICKED | qapi/run-state.json:463-464 |
| `GUEST_PVSHUTDOWN` | none | qapi/run-state.json:478 |
| `DEVICE_DELETED` | `{ '*device': 'str', 'path': 'str' }` | qapi/qdev.json:143-144; safe to reuse the ID afterwards (125-128); emitted from hw/core/qdev.c:704-711. |
| `DEVICE_UNPLUG_GUEST_ERROR` | `{ '*device': 'str', 'path': 'str' }` | qapi/qdev.json:165-166 |
| `DEVICE_TRAY_MOVED` | `{ 'device': 'str', 'id': 'str', 'tray-open': 'bool' }` | qapi/block.json:412-413 |
| `BLOCK_IO_ERROR` | `{ 'qom-path': 'str', 'device': 'str', '*node-name': 'str', 'operation': 'IoOperationType', 'action': 'BlockErrorAction', '*nospace': 'bool', 'reason': 'str' }`; `IoOperationType = ['read','write']`; `BlockErrorAction = ['ignore','report','stop']` | qapi/block-core.json:5761-5765; qapi/common.json:21-22; qapi/block-core.json:5663-5664. A `STOP` follows when action is `stop`; rate-limited except for `stop` (5743-5746). |
| `BLOCK_IMAGE_CORRUPTED` | `{ 'device': 'str', '*node-name': 'str', 'msg': 'str', '*offset': 'int', '*size': 'int', 'fatal': 'bool' }` | qapi/block-core.json:5706-5712 |
| `JOB_STATUS_CHANGE` | `{ 'id': 'str', 'status': 'JobStatus' }` | qapi/job.json:129-131 |
| `MIGRATION` | `{ 'status': 'MigrationStatus' }` | qapi/migration.json:1114-1115; requires `events` capability (migration/migration.c:499-504). |
| `MIGRATION_PASS` | `{ 'pass': 'int' }` | qapi/migration.json:1132-1133 |
| `BALLOON_CHANGE` | `{ 'actual': 'int' }` | qapi/machine.json:1176-1177 |
| `VNC_CONNECTED` | `{ 'server': 'VncServerInfo', 'client': 'VncBasicInfo' }` (before auth) | qapi/ui.json:737-740, `'if': 'CONFIG_VNC'` |
| `VNC_INITIALIZED` | `{ 'server': 'VncServerInfo', 'client': 'VncClientInfo' }` (after auth) | qapi/ui.json:764-767 |
| `VNC_DISCONNECTED` | `{ 'server': 'VncServerInfo', 'client': 'VncClientInfo' }` | qapi/ui.json:790-793 |

VNC info structs (qapi/ui.json:486-524, 571-575):
```
{ 'struct': 'VncBasicInfo',  'data': { 'host': 'str', 'service': 'str', 'family': 'NetworkAddressFamily', 'websocket': 'bool' } }
{ 'struct': 'VncServerInfo', 'base': 'VncBasicInfo', 'data': { '*auth': 'str' } }
{ 'struct': 'VncClientInfo', 'base': 'VncBasicInfo', 'data': { '*x509_dname': 'str', '*sasl_username': 'str' } }
{ 'struct': 'VncInfo', 'data': {'enabled': 'bool', '*host': 'str', '*family': 'NetworkAddressFamily',
           '*service': 'str', '*auth': 'str', '*clients': ['VncClientInfo']} }
{ 'command': 'query-vnc', 'returns': 'VncInfo', 'if': 'CONFIG_VNC' }   (683-684)
```

---

## 11. Related CLI knobs verified

- `-no-shutdown`: "Don't exit QEMU on guest shutdown, but instead only stop the emulation" (qemu-options.hx:5219-5225) -> RunState `shutdown`, `SHUTDOWN` then `STOP`.
- `-no-reboot` (5212-5216); `-action reboot=reset|shutdown, shutdown=poweroff|pause, panic=pause|shutdown|exit-failure|none, watchdog=...` (5228-5236); QMP `set-action` with `{'*reboot','*shutdown','*panic','*watchdog'}` (qapi/run-state.json:419-424).
- `-loadvm [tag|id]` starts from a saved internal snapshot (qemu-options.hx:5253-5259); applied in `qmp_x_exit_preconfig` via `load_snapshot(loadvm, NULL, false, NULL, ...)` then resumes to `running` if autostart (system/vl.c:2827-2831).
- `-S` (5051-5057) sets `autostart = 0` (system/vl.c:3174-3175); with no `-incoming`, `qmp_cont` is called automatically only when autostart (2849-2851).

---

## 12. Quick sequence recipes (all derived from the citations above)

1. **Connect**: read greeting -> `{"execute":"qmp_capabilities"}` -> events start flowing (docs/interop/qmp-spec.rst:336-349).
2. **Graceful shutdown**: `system_powerdown` -> wait `SHUTDOWN{guest:true, reason:"guest-shutdown"}` (process exits unless `-no-shutdown`).
3. **Force off**: `quit` -> expect EOF; `SHUTDOWN{reason:"host-qmp-quit"}` may or may not be read.
4. **Internal snapshot**: `query-named-block-nodes` -> pick writable qcow2 `node-name`s -> `snapshot-save{job-id,tag,vmstate:<node>,devices:[<nodes>]}` -> track `JOB_STATUS_CHANGE` to `concluded` -> `query-jobs` (check `error`) -> `job-dismiss{id}`.
5. **Save to file**: `migrate-set-capabilities{events:true}` -> `migrate{uri:"file:/path/state.bin"}` (or `channels` form with `offset`) -> `MIGRATION{status:"completed"}` / `query-migrate` -> `quit`.
6. **Restore**: launch with `-incoming file:/path/state.bin` (optionally `-S`) -> runstate `inmigrate` -> auto `vm_start` when done (or `cont`).
7. **USB passthrough**: `device_add{driver:"usb-host", id, vendorid, productid}` (or `hostbus`+`hostaddr` for immediate bind) -> `device_del{id}` -> `DEVICE_DELETED`.


## Open questions
- Whether auto-generated block node names (the '#blockNNN' style returned by query-named-block-nodes for -drive-created nodes) are accepted by bdrv_find_node in snapshot-save.devices was not verified in this pass; using explicit -blockdev node-name values is the safe path.
- The exact string value of TYPE_USB_BUS (used for default bus naming like 'usb-bus.0') lives in include/hw/usb.h and was not read; the naming rule itself (hw/core/bus.c:111-125) is verified.
- No documentation sentence explicitly stating 'multiple QMP monitors are allowed' was found; the conclusion rests on the compat_monitorNNN counter semantics in qemu-options.hx:4974-4977 and the unbounded mon_list in monitor/monitor.c:606-618.
- query-usbhost does not exist in the QAPI schema; the only host-USB enumeration path is HMP 'info usbhost' via human-monitor-command, whose output format is explicitly unstable (qapi/misc.json:228-232). A client that needs host USB enumeration should use libusb/IOKit directly rather than QEMU.
- Whether this particular QEMU build has CONFIG_PNG (for screendump format=png) and CONFIG_VNC (for VNC_* events / query-vnc) depends on the build configuration, not the source tree; check query-commands / query-qmp-schema at runtime.

## Reviewer corrections (unapplied)
- **Claim:** Section 9: "Also available: send-key { 'keys': ['KeyValue'], '*hold-time': 'int' } (1048-1049), default hold 100 ms."
  - **Problem:** The 100 ms figure comes from the QAPI doc comment (qapi/ui.json:1032-1033 "Defaults to 100"), but the implementation does not use it. qmp_send_key sets hold_time = 0 /* use default */ when absent (ui/input.c:699-700), and qemu_input_event_send_key_delay() substitutes kbd_default_delay_ms, which is 10 (ui/input.c:47 `static uint32_t kbd_default_delay_ms = 10;`, ui/input.c:437 `delay_ms ? delay_ms : kbd_default_delay_ms`).
  - **Correction:** Effective default hold-time is 10 ms in QEMU 11.1.1 (ui/input.c:47, ui/input.c:437, ui/input.c:699-700); the schema doc's "100" (qapi/ui.json:1032-1033) is stale. Pass hold-time explicitly if a specific delay matters.
- **Claim:** Section 9 (input-send-event impl constraints): "Key `number` values are sent raw; `qcode` converted via qemu_input_key_value_to_linux (199)."
  - **Problem:** Both KeyValue kinds go through qemu_input_key_value_to_linux() (ui/input.c:199 calls it unconditionally). Inside it, KEY_VALUE_KIND_NUMBER is translated with qemu_input_key_number_to_linux() → qemu_input_map_qnum_to_linux[nr] (ui/input-keymap.c:45-57, 37-43), i.e. a "number" is a QEMU/AT-set1 'qnum' scancode that is mapped to a Linux keycode, not a raw value. Out-of-range numbers become KEY_RESERVED (ui/input-keymap.c:39-41).
  - **Correction:** `{"type":"number","data":N}` is interpreted as a QEMU qnum (PC AT set-1 style) code and mapped via qemu_input_map_qnum_to_linux (ui/input-keymap.c:37-43, 48-49); `qcode` is mapped via qemu_input_map_qcode_to_linux (ui/input-keymap.c:51-52). Neither is passed through raw. Prefer `qcode` for a C client.
- **Claim:** Section 3 (`quit`): "requests shutdown with cause host-qmp-quit (monitor/qmp-cmds.c:44-48), which forces exit even with -no-shutdown (system/runstate.c:845-847)"
  - **Problem:** system/runstate.c:845-847 only sets the static `force_shutdown = true`. That flag is consumed solely by qemu_force_shutdown_requested() (system/runstate.c:436-438), whose only caller is hw/block/vhost-user-blk.c:238 — it has nothing to do with the main loop's -no-shutdown handling. The reason `quit` exits despite -no-shutdown is that qmp_quit sets `shutdown_action = SHUTDOWN_ACTION_POWEROFF` (monitor/qmp-cmds.c:46); main_loop_should_exit() only pauses (vm_stop(RUN_STATE_SHUTDOWN)) when shutdown_action == SHUTDOWN_ACTION_PAUSE, otherwise it returns true and QEMU exits (system/runstate.c:897-908).
  - **Correction:** `quit` overrides -no-shutdown because monitor/qmp-cmds.c:46 sets shutdown_action = SHUTDOWN_ACTION_POWEROFF before qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_QMP_QUIT) (monitor/qmp-cmds.c:47); the exit decision is at system/runstate.c:897-908. Drop the citation to runstate.c:845-847 (force_shutdown is unrelated).
- **Missing:** device_del is also refused during an active migration: qdev_unplug() errors "device_del not allowed while migrating" unless dev->allow_unplug_during_migration (system/qdev-monitor.c:925-928), after a qdev_hotunplug_allowed() check (system/qdev-monitor.c:921-923). The USB sync-unplug path is hotplug_handler_unplug() followed by object_unparent() because USBBus defines no unplug_request (system/qdev-monitor.c:939-947; hw/usb/bus.c:29-38).
- **Missing:** stop and cont both fail with "There is a dump in process, please wait." while a guest memory dump is running (monitor/qmp-cmds.c:52-57 for stop, monitor/qmp-cmds.c:72-77 for cont).
- **Missing:** snapshot-load's internal qemu_system_reset(SHUTDOWN_CAUSE_SNAPSHOT_LOAD) (migration/savevm.c:3519) does NOT emit a RESET QMP event: qemu_system_reset() skips the event for SHUTDOWN_CAUSE_SUBSYSTEM_RESET and SHUTDOWN_CAUSE_SNAPSHOT_LOAD (system/runstate.c:565-567). A manager watching RESET must not expect one during snapshot-load; only STOP/RESUME and JOB_STATUS_CHANGE are observable.
- **Missing:** migrate with a plain `file:` URI does not require the mapped-ram or multifd capability: migration_channels_and_transport_compatible() (migration/migration.c:223-252) only demands a seekable transport when mapped-ram is enabled (226-230) and multi-channel/extra-fd transports when multifd/direct-io are enabled (232-243); the only hard refusal for `file:` is cpr-transfer mode ("Migration requires streamable transport (eg unix)", 245-249). So a save-to-file needs no capability other than `events` for the MIGRATION event.
- **Missing:** The `-qmp unix:PATH,server=on,wait=off` short form is confirmed by code, not just -serial docs: monitor_parse() (system/vl.c:1253-1280) calls qemu_chr_parse_compat(), whose "unix:" branch sets backend=socket and parses the remainder with implied key "path" (chardev/char.c:521-527); -qmp is dispatched at system/vl.c:3233-3236 (mode "control").
- **Missing:** query-usbhost is correctly reported NOT FOUND; for completeness the only QMP USB query is the unstable `x-query-usb` (qapi/machine.json:1798-1810, returns HumanReadableText) which lists guest-side USB devices, not host devices.
- **Missing:** WATCHDOG event: when action is reset/shutdown/pause the WATCHDOG event is followed by RESET/SHUTDOWN/STOP respectively (qapi/run-state.json:284-286); the event is rate-limited (qapi/run-state.json:288).
- **Claim:** Section 4, `stop`: "Emits `STOP` (system/cpus.c:310)" (and recipe text implying a STOP always follows).
  - **Problem:** STOP is emitted only when the previous runstate was live (running/suspended). `stop` on an already-paused VM returns success and emits nothing. `vm_shutdown()` also passes send_stop=false, so the final stop at process exit never emits STOP.
  - **Correction:** system/cpus.c:296-311 `do_vm_stop`: `if (runstate_is_live(oldstate)) { ... if (send_stop) qapi_event_send_stop(); }`; include/system/runstate.h:95-98 `runstate_is_live` = RUNNING || SUSPENDED; system/cpus.c:326-331 `vm_shutdown()` -> `do_vm_stop(RUN_STATE_SHUTDOWN, false)`. Client code must not block waiting for STOP after `stop` when `query-status.running` was already false.
- **Claim:** Section 4, `cont`: "Emits `RESUME` (system/cpus.c:794)".
  - **Problem:** RESUME is only emitted on an actual transition. `cont` while running returns success with no event (`vm_prepare_start` returns -1 early); `cont` in `inmigrate` only sets `autostart` and emits nothing until the incoming migration completes. Edge case: if a vmstop request is pending while running, `vm_prepare_start` emits a STOP+RESUME pair.
  - **Correction:** system/cpus.c:766-770 (`if (runstate_is_running() && requested == RUN_STATE__MAX) return -1;`), 772-780 (STOP+RESUME pair), 793-794 (RESUME); monitor/qmp-cmds.c:103-104 (`inmigrate` -> `autostart = 1` only).
- **Claim:** Section 4, `system_reset`: "Hard reset ... Emits `RESET` with guest:false, reason:"host-qmp-system-reset" (system/runstate.c:569)".
  - **Problem:** Only true with the default `reboot=reset` action. With `-no-reboot` / `-action reboot=shutdown`, `qemu_system_reset_request` converts the request into a shutdown: no RESET event, instead SHUTDOWN{guest:false, reason:"host-qmp-system-reset"} and QEMU exits (or pauses in runstate `shutdown` with `-no-shutdown`).
  - **Correction:** system/runstate.c:737-748 `qemu_system_reset_request`: `if (reboot_action == REBOOT_ACTION_SHUTDOWN && reason != SHUTDOWN_CAUSE_SUBSYSTEM_RESET) shutdown_requested = reason; ... else reset_requested = reason;`; SHUTDOWN emission system/runstate.c:856-860; `-no-reboot` qemu-options.hx:5212-5216.
- **Claim:** Section 2: "Therefore `wait=off` must be passed explicitly or QEMU blocks at startup until a client connects."
  - **Problem:** The blocking behaviour itself is stated without a citation (only the default of `wait` is cited).
  - **Correction:** chardev/char-socket.c:1238-1241 `qmp_chardev_open_socket_server`: `if (is_waitconnect) { tcp_chr_accept_server_sync(chr); } else { qio_net_listener_set_client_func_full(...tcp_chr_accept...); }` — `tcp_chr_accept_server_sync` (987-997) blocks in accept.
- **Claim:** Section 9, `input-send-event`: "e.g. `abs` needs an absolute pointer device such as a tablet".
  - **Problem:** Stated without citation.
  - **Correction:** ui/input.c:180-189: every event kind is checked with `qemu_input_find_handler(1 << event->type, con)` -> "Input handler not found for event type %s"; the handler set is whatever input devices are registered — the note is correct in substance but the citation should point at input.c:180-189 rather than be asserted bare.
- **Missing:** RESTORE LANDS IN `paused` WHEN THE VM WAS PAUSED AT SAVE TIME: the source records its runstate in `migration_stop_vm` via `global_state_store()` (migration/migration.c:279-287; global_state.c:53-56). On the destination, `vm_start()` is only called when `runstate_is_live(migration_get_target_runstate())` (migration.c:162-175, 697-716); a non-live saved state (e.g. `paused` after `stop`) makes the destination do `runstate_set(global_state_get_runstate())` (migration.c:717-719) regardless of `-S`/autostart. A `stop` -> `migrate file:` -> `-incoming file:` flow therefore requires an explicit `cont` after `MIGRATION completed` / `query-migrate.status == completed`.
- **Missing:** `MIGRATION` EVENTS ON THE RESTORE (DESTINATION) SIDE ALSO REQUIRE THE `events` CAPABILITY ON THAT PROCESS: `migrate_generate_event` consults the local `MigrationState` (migration/migration.c:499-504; options.c:339-344) and the incoming state change to `completed` goes through it (migration.c:728-729). With a non-`defer` `-incoming` the migration starts inside `qemu_init` (system/vl.c:2836-2848) before a client can issue `migrate-set-capabilities`. Options: `-incoming defer` + `migrate-set-capabilities` + `migrate-incoming` (qapi/migration.json:1532-1535), or preset it on the command line with `-global migration.x-events=on` — TYPE_MIGRATION deliberately derives from TYPE_DEVICE so `-global` works (migration/migration.c:4074-4085) and the capability is exposed as property `x-events` (migration/options.c:84-85, 198; note the `x-` unstable prefix). Otherwise poll `query-migrate`/`query-status`.
- **Missing:** `snapshot-save`/`snapshot-load` PRECONDITIONS NOT LISTED: both first call `migrate_can_snapshot()` which fails with "Snapshots are not compatible with multifd" if the `multifd` capability is on (migration/options.c:536-540, 547-564; migration/savevm.c:3273-3275, 3465-3467). If the manager enables `multifd`+`mapped-ram` for file migration it must switch `multifd` off again before internal snapshots. `save_snapshot` additionally fails when any migration blocker is registered or `-only-migratable` blocks a device: `migration_is_blocked(errp)` (savevm.c:3277-3279; migration/migration.c:1939-1953), and when record/replay forbids it (3281-3285).
- **Missing:** JOB-ID RULES FOR snapshot-* JOBS: `job_create` rejects ids that are not `id_wellformed` ("Invalid job ID '%s'") or already in use ("Job ID '%s' already in use") (job.c:404-410); `id_wellformed` = first char alphabetic, rest alphanumeric or `-._` (util/id.c:17-30). The id is freed only after `job-dismiss`, so a manager reusing a fixed id must dismiss first.
- **Missing:** WHICH NODES MAY GO IN `devices`/`vmstate`: `query-named-block-nodes` returns both the qcow2 format node and its `file` protocol child, and both report `ro:false`. Only the format node (`drv == "qcow2"`) is acceptable; listing the `file` child fails with "Device '%s' is writable but does not support snapshots" because protocol drivers have no `.bdrv_snapshot_create` and no fallback child (block/snapshot.c:158-193 `bdrv_snapshot_fallback_child` requires a primary child; 195-214 `bdrv_can_snapshot`; 532-563). Filter on `drv`, not on `ro`. Fallback exists only for filter-like nodes whose sole data/metadata child supports snapshots (158-181).
- **Missing:** `snapshot-load` EMITS NO `RESET` EVENT: it calls `qemu_system_reset(SHUTDOWN_CAUSE_SNAPSHOT_LOAD)` (migration/savevm.c:3519) and `qemu_system_reset` skips `qapi_event_send_reset` for that cause (system/runstate.c:563-570). Also, the job restores the run state captured before `vm_stop(RUN_STATE_RESTORE_VM)`: if the VM was paused before `snapshot-load` it stays paused afterwards (savevm.c:3610-3626, `orig_state`).
- **Missing:** ONE CLIENT PER QMP SOCKET CHARDEV: on accept the listener callback is cleared (chardev/char-socket.c:917-920 `qio_net_listener_set_client_func_full(s->listener, NULL, ...)`) and only re-armed when the client disconnects (461-471 `tcp_chr_disconnect_locked`). A second connection sits in the listen backlog until the first closes. Every (re)connection restarts capability negotiation and re-sends the greeting (monitor/qmp.c:617-626) and the previous connection's queued requests are discarded (630-637). For concurrent clients define several `-chardev socket`+`-mon mode=control` pairs.
- **Missing:** SOCKET PATH LIFECYCLE: a stale unix socket file is unlinked before bind (util/qemu-sockets.c:1005-1009), so leftovers from a crashed QEMU do not block startup. On clean exit `qemu_cleanup` -> `qemu_chr_cleanup()` (system/runstate.c:1006, 1047) finalizes the listener and the listening fd's path is unlinked (io/channel-socket.c:449-462, 995-1000; util/qemu-sockets.c:1314-1333); after SIGKILL the file remains. The manager must tolerate both.
- **Missing:** GUEST-LOCKED TRAY BEHAVIOUR FOR `eject` / `blockdev-change-medium`: without `force`, if the guest has locked the tray the command sends an eject request to the guest and then FAILS with "Device '%s' is locked and force was not specified, wait for tray to open and try again" (block/qapi-system.c:104-116 `do_open_tray` returns -EINPROGRESS; propagated by `qmp_blockdev_change_medium` 367-371 and `qmp_eject` 400-416). The client must wait for `DEVICE_TRAY_MOVED{tray-open:true}` and retry, or pass `force:true`. Other errors: "Device '%s' is not removable" (88-91), "does not have a tray" (-ENOSYS, ignored for tray-less devices, 93-96, 368-369). `blockdev-change-medium` opens the new image (`bdrv_open`) BEFORE touching the tray (362-366), so a bad `filename`/`format` fails without ejecting the current medium.
- **Missing:** `cont` FAILURE MODES: `runstate_needs_reset()` is true for `internal-error` and `shutdown` (system/runstate.c:263-267), so after a guest shutdown under `-no-shutdown` (or `-action shutdown=pause`) `cont` fails with "Resetting the Virtual Machine is required" and `system_reset` must be issued first (monitor/qmp-cmds.c:79-81). After `postmigrate`, `cont` calls `migration_block_activate()` to re-acquire the images and propagates its error (e.g. image locks held by a restored instance) (qmp-cmds.c:105-115). Both `stop` and `cont` are refused while a guest memory dump is running: "There is a dump in process, please wait." (qmp-cmds.c:53-56, 73-76).
- **Missing:** DEFAULT PANIC ACTION IS `shutdown`, NOT `pause`: `-action panic=` defaults to shutdown (qemu-options.hx:5232-5233). With that default `GUEST_PANICKED` carries `action:"poweroff"`, the VM is stopped in runstate `guest-panicked`, then a shutdown with cause `guest-panic` is requested and QEMU exits (SHUTDOWN{guest:true, reason:"guest-panic"}) (system/runstate.c:673-683; `shutdown_caused_by_guest` include/system/runstate.h:86-89). `action:"pause"` only occurs with `-action panic=pause` (or panic=shutdown combined with shutdown=pause) (runstate.c:673-676); `-action panic=exit-failure` makes the process exit non-zero (runstate.c:902-907). A manager that wants to inspect a panicked guest must pass `-action panic=pause`.
- **Missing:** `system_powerdown` SEQUENCE: the `POWERDOWN` event is emitted from the main loop when the request is delivered (system/runstate.c:851-855, 938-940) BEFORE any guest-driven `SHUTDOWN`; and with `-no-shutdown`/`shutdown=pause` the guest shutdown yields SHUTDOWN then `vm_stop(RUN_STATE_SHUTDOWN)` -> STOP, runstate `shutdown` (runstate.c:898-901). Recipe 2 should wait on SHUTDOWN, treating POWERDOWN as an acknowledgement only.
- **Missing:** `device_del` RESTRICTIONS: refused while a migration is running ("device_del not allowed while migrating", system/qdev-monitor.c:922-925) and for non-hotpluggable devices ("Device '%s' does not support hotplugging", hw/core/qdev-hotplug.c:38-41; `qdev_hotunplug_allowed` 87-91). `DEVICE_DELETED` is armed by `dev->pending_deleted_event = true` in `qdev_unrealize` (hw/core/qdev.c:602-605) and fires from finalize after `object_unparent` (qdev-monitor.c:944-946; qdev.c:704-711); for USB it can arrive before or after the `device_del` reply.
- **Missing:** `device_add usb-host` BUS SELECTION AND AVAILABILITY: with `bus` omitted, `qdev_find_default_bus` takes the FIRST `usb-bus` found by `qbus_find_recursive(sysbus_get_default(), NULL, dc->bus_type)` — with several controllers (e.g. xhci plus UHCI/OHCI companions) this may not be the intended one; errors "No 'usb-bus' bus found for device 'usb-host'" when no USB controller exists and "A 'usb-bus' bus was found but is full" (system/qdev-monitor.c:633-650). `usb-host` is built as a loadable module `hw-usb-host` (hw/usb/meson.build:84-88), so on modular builds a missing module gives "'usb-host' is not a valid device model name" (system/qdev-monitor.c:256).
- **Missing:** `usb-host` AUTOSCAN DETAILS: after `device_add` with vendorid/productid/hostport the scan is repeated by a 2000 ms `QEMU_CLOCK_REALTIME` timer (hw/usb/host-libusb.c:1912-1920) and on transition to running (1827-1832); after 3 consecutive `usb_host_open` failures (e.g. EACCES on the host) the filter is skipped (`errcount >= 3`, 1881-1892) until the device disappears from the bus (`seen == 0` resets `errcount`, 1898-1904). No QMP event signals actual attachment; poll `human-monitor-command` "info usbhost"/"info usb" (hw/usb/host-libusb.c:1923ff).
- **Missing:** `migrate-set-capabilities` IS REFUSED WHILE A MIGRATION IS RUNNING ("There's a migration process in progress", migration/options.c:781-784), and `migrate` with `mapped-ram` enabled requires a seekable (`file:`) transport ("Migration requires seekable transport (e.g. file)", migration/migration.c:225-229, 192-195). `migrate_cancel` after postcopy started errors "Postcopy migration in progress, cannot cancel." (migration.c:2157-2168).
- **Missing:** USB HOTPLUG COMPLETION ON `device_del` IS SYNCHRONOUS BUT `device_add` FAILURES ARE DRAINED: `qmp_device_add` calls `drain_call_rcu()` on failure so a failed add is fully torn down before the reply, allowing immediate id reuse (system/qdev-monitor.c:868-885).
