# QEMU 11.1.1 notes: input-injection
Source tree: build/qemu-src (tag v11.1.1). Every claim cites path:line. Produced by parallel research agents and checked by two skeptical reviewers; reviewer corrections were applied.

# QEMU 11.1.1 — Injecting keyboard/mouse input from a display backend

Tree root: `/Users/giraffewithcode/dev/personal/alcove/build/qemu-src` (VERSION file = `11.1.1`). All `path:line` citations are relative to that root unless prefixed with `qemu-build/` (the sibling build directory `/Users/giraffewithcode/dev/personal/alcove/build/qemu-build`, where meson-generated `.c.inc` files live).

Revision note: this version re-verified every citation flagged by review against the source; corrected items are marked **(corrected)** and newly added material is marked **(added)**.

---

## 0. Executive summary (what you actually call)

| Purpose | Function | Where |
|---|---|---|
| Key press/release (Linux evdev code) | `qemu_input_event_send_key_linux(QemuConsole *src, unsigned int lnx, bool down)` | `include/ui/input.h:62-63`, `ui/input.c:398-416` |
| Key press/release (QEMU "qnum"/XT number) | `qemu_input_event_send_key_number(QemuConsole *src, int num, bool down)` | `include/ui/input.h:64`, `ui/input.c:418-422` |
| Insert delay between queued key events | `qemu_input_event_send_key_delay(uint32_t delay_ms)` | `include/ui/input.h:65`, `ui/input.c:424-439` |
| Stateful key tracking wrapper (recommended; used by cocoa/sdl2) | `qkbd_state_key_event(QKbdState *kbd, unsigned int lnx, bool down)` | `include/ui/kbd-state.h:61`, `ui/kbd-state.c:41-114` |
| Mouse button | `qemu_input_queue_btn(QemuConsole *src, InputButton btn, bool down)` | `include/ui/input.h:72`, `ui/input.c:441-452` |
| Button bitmask diff → button events | `qemu_input_update_buttons(QemuConsole *src, uint32_t *button_map, uint32_t button_old, uint32_t button_new)` | `include/ui/input.h:73-74`, `ui/input.c:454-467` |
| Absolute motion (auto-scaled to 0..0x7FFF, **not clamped**) | `qemu_input_queue_abs(QemuConsole *src, InputAxis axis, int value, int min_in, int max_in)` | `include/ui/input.h:81-82`, `ui/input.c:515-529` |
| Relative motion | `qemu_input_queue_rel(QemuConsole *src, InputAxis axis, int value)` | `include/ui/input.h:80`, `ui/input.c:502-513` |
| Flush (EV_SYN) | `qemu_input_event_sync(void)` | `include/ui/input.h:59`, `ui/input.c:389-396` |
| Is the current pointer device absolute? | `bool qemu_input_is_absolute(const QemuConsole *con)` | `include/ui/input.h:76`, `ui/input.c:469-476` |
| Mouse-mode change notification | `qemu_add_mouse_mode_change_notifier(Notifier *)` / `qemu_remove_mouse_mode_change_notifier` | `include/ui/input.h:104-105`, `ui/input.c:565-573` |
| Keyboard LED state | `qemu_input_get_leds_mask(const QemuConsole *con)`, `qemu_input_led_notifier_add(Notifier *)` | `include/ui/input.h:155-164`, `ui/input.c:478-487, 145-153` |
| Text (monitor/serial) console key input | `qemu_text_console_put_linux(QemuTextConsole *s, unsigned int lnx, bool ctrl)` | `include/ui/console.h:84-85`, `ui/console.c:344-369` |
| macOS keycode → Linux keycode table | `const guint16 qemu_input_map_osx_to_linux[256]` + `qemu_input_map_osx_to_linux_len` | `include/ui/input.h:152-153`, generated `qemu-build/ui/input-keymap-osx-to-linux.c.inc:7,130` |

**Important negative findings (verified by grep, not memory):**
- `qemu_input_event_send_key_qcode` — **NOT FOUND** anywhere in the 11.1.1 tree (`grep -rn "send_key_qcode" .` and `grep -rn "key_qcode" include ui hw docs` both return nothing except the trace-event name `input_event_key_qcode` at `ui/trace-events:130`). The key API in this version takes **Linux evdev keycodes** (`qemu_input_event_send_key_linux`) or QEMU key numbers (`qemu_input_event_send_key_number`). To send a `QKeyCode`, convert with the generated table `qemu_input_map_qcode_to_linux[qcode]` (`include/ui/input.h:122-123`; exactly what `qemu_input_key_value_to_linux` does at `ui/input-keymap.c:45-57`) and call `qemu_input_event_send_key_linux`.
- **(corrected)** `qemu_add_led_event_handler` and a `kbd_led` *handler API* — **NOT FOUND** in `include/`, `ui/`, `hw/input/`: `grep -rn "led_event_handler" include/ ui/ hw/input/` returns nothing. A grep for `kbd_led` *does* hit, but only the backends' own static `Notifier` callbacks named `kbd_leds` (`ui/vnc.c:1816`, `ui/spice-input.c:90`) and the unrelated migration hook `ps2_kbd_ledstate_post_load` (`hw/input/ps2.c:1107`) — all built on the notifier API `qemu_input_led_notifier_add` (`include/ui/input.h:163`, `ui/input.c:145-148`) described in §6, none of them the old handler API.
- A generated `osx → qcode` table does **not** exist; the only OS-X table is `osx → linux` (see §3).

---

## 1. `include/ui/input.h` and `ui/input.c`

### 1.1 Constants and types (`include/ui/input.h`)

```c
#define INPUT_EVENT_MASK_KEY   (1<<INPUT_EVENT_KIND_KEY)
#define INPUT_EVENT_MASK_BTN   (1<<INPUT_EVENT_KIND_BTN)
#define INPUT_EVENT_MASK_REL   (1<<INPUT_EVENT_KIND_REL)
#define INPUT_EVENT_MASK_ABS   (1<<INPUT_EVENT_KIND_ABS)
#define INPUT_EVENT_MASK_MTT   (1<<INPUT_EVENT_KIND_MTT)

#define INPUT_EVENT_ABS_MIN    0x0000
#define INPUT_EVENT_ABS_MAX    0x7FFF
#define INPUT_EVENT_SLOTS_MIN  0x0
#define INPUT_EVENT_SLOTS_MAX  0xa
```
(`include/ui/input.h:7-16`) — **absolute coordinate range is 0x0000..0x7FFF on both axes**. This range is also what the devices advertise to the guest, e.g. virtio-tablet's `ABS_X/ABS_Y` absinfo uses `INPUT_EVENT_ABS_MIN/MAX` (`hw/input/virtio-input-hid.c:413-423`, min/max at `:416-417, 422-423`), and the QAPI doc says "For absolute coordinates the valid range is 0 to 0x7fff" (`qapi/ui.json:1135-1136`).

**(added) `InputEventKind`** — the enum behind `QemuInputEvent.type` and the `INPUT_EVENT_MASK_*` shifts is the QAPI enum `InputEventKind` (`qapi/ui.json:1170-1185`, values `'key','btn','rel','abs','mtt'`), generated as
```c
typedef enum InputEventKind {
    INPUT_EVENT_KIND_KEY,
    INPUT_EVENT_KIND_BTN,
    INPUT_EVENT_KIND_REL,
    INPUT_EVENT_KIND_ABS,
    INPUT_EVENT_KIND_MTT,
    INPUT_EVENT_KIND__MAX,
} InputEventKind;
```
(`qemu-build/qapi/qapi-types-ui.h:458-465`). `qemu_input_event_send_impl` looks up the handler with `1 << evt->type` (`ui/input.c:351`), which is why the mask macros are defined as shifts of these values.

```c
typedef struct QemuInputKeyEvent {
    unsigned int key;      /* Linux evdev keycode (KEY_*) */
    bool down;
} QemuInputKeyEvent;

typedef struct QemuInputEvent {
    InputEventKind type;
    union {
        QemuInputKeyEvent key;
        InputBtnEvent btn;
        InputMoveEvent rel;
        InputMoveEvent abs;
        InputMultiTouchEvent mtt;
    };
} QemuInputEvent;

typedef void (*QemuInputHandlerEvent)(DeviceState *dev, QemuConsole *src,
                                      QemuInputEvent *evt);
typedef void (*QemuInputHandlerSync)(DeviceState *dev);

struct QemuInputHandler {
    const char             *name;
    uint32_t               mask;
    QemuInputHandlerEvent  event;
    QemuInputHandlerSync   sync;
};
```
(`include/ui/input.h:21-46`). Note `QemuInputKeyEvent.key` is a **Linux keycode**: `qmp_input_send_event` converts the QAPI `KeyValue` to Linux via `qemu_input_key_value_to_linux` before filling it (`ui/input.c:198-201`) and tracing converts back with `qemu_input_linux_to_qcode` (`ui/input.c:244`).

### 1.2 Handler registration (device side, for context)

```c
G_GNUC_WARN_UNUSED_RESULT
QemuInputHandlerState *qemu_input_handler_register(DeviceState *dev,
                                            const QemuInputHandler *handler);
void qemu_input_handler_activate(QemuInputHandlerState *s);
void qemu_input_handler_deactivate(QemuInputHandlerState *s);
void qemu_input_handler_unregister(QemuInputHandlerState *s);
void qemu_input_handler_bind(QemuInputHandlerState *s,
                             const char *device_id, int head,
                             Error **errp);
```
(`include/ui/input.h:48-56`)

- `qemu_input_handler_register` allocates a `QemuInputHandlerState`, appends to the global `handlers` tail queue, and fires the mouse-mode/LED notifiers (`ui/input.c:59-72`).
- `qemu_input_handler_activate` moves the handler to the **head** of the list, making it the one that receives events (`ui/input.c:74-79`); `deactivate` moves it to the tail (`ui/input.c:81-86`).
- **(corrected)** `qemu_input_handler_bind` ties a handler to a console via `QemuConsole *qemu_console_lookup_by_device_name(const char *device_id, uint32_t head, Error **errp)` (prototype `include/ui/console.h:359-360`), called as `qemu_console_lookup_by_device_name(device_id, head, &err)` at `ui/input.c:104` and propagating the error (`ui/input.c:105-108`) — this is the "input routing" used by `display=`/`head=` device properties (`ui/input.c:97-111`, `docs/multiseat.txt:40-42`). virtio-input-hid calls it from realize when `display=` is set (`hw/input/virtio-input-hid.c:169-172`).
- Lookup (`qemu_input_find_handler`, `ui/input.c:113-136`): first pass — handlers bound to exactly `con`; second pass — unbound handlers (`s->con == NULL`); first match on `mask & handler->mask` wins. **Passing `src = NULL` matches only unbound handlers** (first loop skips every entry when `con == NULL`, `ui/input.c:119`).
- Device examples of the `mask` field: keyboard `INPUT_EVENT_MASK_KEY` (`hw/input/hid.c:508-512`, `hw/input/ps2.c:1228-1232`, `hw/input/virtio-input-hid.c:249-254`); relative mouse `INPUT_EVENT_MASK_BTN | INPUT_EVENT_MASK_REL` (`hw/input/hid.c:514-519`, `hw/input/ps2.c:1248-1253`, `hw/input/virtio-input-hid.c:322-327`); absolute tablet `INPUT_EVENT_MASK_BTN | INPUT_EVENT_MASK_ABS` (`hw/input/hid.c:521-526`, `hw/input/virtio-input-hid.c:376-381`).
- USB keyboards are activated at `hid_init` (`hw/input/hid.c:533-536`); USB mouse/tablet are only *registered* there (`hw/input/hid.c:537-543`) and become active when the guest driver first polls them (`hid_pointer_activate`, `hw/input/hid.c:344-350`, called from `hid_pointer_poll` `:360` and from `hw/usb/dev-hid.c:645, 666, 749`) — so `qemu_input_is_absolute()` may flip from false to true after guest boot, which is why backends subscribe to the mouse-mode notifier. virtio-input devices activate on the guest's `DRIVER_OK` status write: `virtio_set_status` (`hw/virtio/virtio.c:2286`, class hook call `:2307-2308`) → `virtio_input_set_status` (`hw/input/virtio-input.c:192-205`) → `virtio_input_hid_change_active` → `qemu_input_handler_activate/deactivate` (`hw/input/virtio-input-hid.c:181-190`).

### 1.3 Sending events

```c
void qemu_input_event_send(QemuConsole *src, QemuInputEvent *evt);
void qemu_input_event_send_impl(QemuConsole *src, QemuInputEvent *evt);
void qemu_input_event_sync(void);
void qemu_input_event_sync_impl(void);
```
(`include/ui/input.h:57-60`)

`qemu_input_event_send` (`ui/input.c:359-370`):
1. Drops key events whose `key.key == 0` (KEY_RESERVED).
2. Drops **everything** when `!runstate_is_running() && !runstate_check(RUN_STATE_SUSPENDED)` — input is silently discarded while the VM is paused/stopped.
3. Calls `replay_input_event(src, evt)` which in normal (non-record/replay) mode calls `qemu_input_event_send_impl` (`replay/replay-input.c:91-102`).

`qemu_input_event_send_impl` (`ui/input.c:344-357`) traces, finds the handler with `qemu_input_find_handler(1 << evt->type, src)`, and calls `s->handler->event(s->dev, src, evt)`; if no handler, the event is dropped.

`qemu_input_event_sync` (`ui/input.c:389-396`) has the same runstate gate, then `replay_input_sync_event` → `qemu_input_event_sync_impl` (`replay/replay-input.c:104-113`), which calls `handler->sync(dev)` on every handler that received events since the last sync (`ui/input.c:372-387`). For virtio-input this emits `EV_SYN/SYN_REPORT` (`hw/input/virtio-input-hid.c:153-163`); for USB HID it commits the pointer event queue entry (`hid_pointer_sync`, `hw/input/hid.c:518, 525`). **Always call `qemu_input_event_sync()` after a batch of btn/rel/abs events.**

**(added) Record/replay modes.** `replay_input_event` and `replay_input_sync_event` do *nothing* when `replay_mode == REPLAY_MODE_PLAY` (`replay/replay-input.c:93-94, 106-107`) — under `-icount ...,rr=replay` all backend-originated input is discarded and the guest gets input from the replay log instead. In `REPLAY_MODE_RECORD` the event is cloned and queued for the log (`replay/replay-input.c:95-98, 108-109`); only in the default mode does it reach the device immediately (`:99-101, 110-112`).

### 1.4 Keyboard

```c
void qemu_input_event_send_key_linux(QemuConsole *src, unsigned int lnx,
                                     bool down);
void qemu_input_event_send_key_number(QemuConsole *src, int num, bool down);
void qemu_input_event_send_key_delay(uint32_t delay_ms);
int qemu_input_key_number_to_qcode(unsigned int nr);
unsigned int qemu_input_key_number_to_linux(unsigned int nr);
unsigned int qemu_input_key_value_to_linux(const KeyValue *value);
int qemu_input_linux_to_scancode(unsigned int lnx, bool down, int *codes);
int qemu_input_linux_to_qcode(unsigned int lnx);
```
(`include/ui/input.h:62-70`)

- `qemu_input_event_send_key_linux` (`ui/input.c:398-416`): builds a `INPUT_EVENT_KIND_KEY` event. If the keyboard delay queue `kbd_queue` is empty it sends immediately **and calls `qemu_input_event_sync()` itself** (`:409-411`); otherwise (a delay is pending) it appends an EVENT + SYNC item to the queue (`:412-415`), bounded by `queue_limit = 1024` (`ui/input.c:49`).
- `qemu_input_event_send_key_number` (`ui/input.c:418-422`): converts a QEMU key number via `qemu_input_key_number_to_linux` (`ui/input-keymap.c:37-43`, table `qemu_input_map_qnum_to_linux`) then calls the Linux variant.
- `qemu_input_event_send_key_delay` (`ui/input.c:424-439`): runstate-gated; lazily creates `kbd_timer` on `QEMU_CLOCK_VIRTUAL` with `QEMU_TIMER_ATTR_EXTERNAL` (`ui/input.c:430-434`); queues a DELAY item of `delay_ms` (0 → `kbd_default_delay_ms = 10`, `ui/input.c:47`). Subsequent key events are queued behind it and drained by `qemu_input_queue_process` (`ui/input.c:273-303`) from the timer callback. `qmp_send_key` uses this pattern: press all, delay, release in reverse, delay (`ui/input.c:692-716`).
- **(added) Delay-queue overflow and clock caveats.** Once a delay is pending, `qemu_input_event_send_key_linux` silently **drops** further key events when `queue_count >= queue_limit` (1024) — the `else if (queue_count < queue_limit)` branch at `ui/input.c:412-415` has no else — and `qemu_input_event_send_key_delay` likewise skips queuing a delay when full (`ui/input.c:435-438`). The drain timer runs on `QEMU_CLOCK_VIRTUAL` (`ui/input.c:431`), which does not advance while the VM is stopped, so queued keys stall until resume. Among the in-tree backends only VNC enables a per-key delay: `qkbd_state_set_delay(vd->kbd, key_delay_ms)` (`ui/vnc.c:4269`) with `key-delay-ms` defaulting to 10 (`ui/vnc.c:4128`; option text `qemu-options.hx:2788-2794`: "Keyboards are low-bandwidth devices, so this slowdown can help the device and guest to keep up and not lose events in case events are arriving in bulk"); cocoa/sdl2/gtk do not set one. The USB HID keyboard also drops keys when its own 16-entry queue is full (`hw/input/hid.c:233-236`, `trace_hid_kbd_queue_full`).
- Conversions (`ui/input-keymap.c`): `qemu_input_linux_to_qcode` (`:24-30`, table `qemu_input_map_linux_to_qcode[525]`, generated `qemu-build/ui/input-keymap-linux-to-qcode.c.inc:7`), `qemu_input_key_value_to_linux` (`:45-57`, uses `qemu_input_map_qcode_to_linux[Q_KEY_CODE__MAX]`, generated `qemu-build/ui/input-keymap-qcode-to-linux.c.inc:7`), `qemu_input_linux_to_scancode` (`:59-83`, uses `qemu_input_map_linux_to_qnum[525]`, generated `qemu-build/ui/input-keymap-linux-to-qnum.c.inc:7`; an absent entry yields scancode 0).

- **(added) Which Linux keycodes actually reach the guest.** The input layer forwards any non-zero `lnx`, but each device model has its own coverage:
  - **virtio-keyboard** advertises `EV_KEY` capability bits only for `KEY_ESC .. KEY_REPLY-1` = **1..231** (`for (i = KEY_ESC; i < KEY_REPLY; i++)`, `hw/input/virtio-input-hid.c:306-308`, bitmap size `DIV_ROUND_UP(KEY_REPLY, 8)` `:292`; `KEY_REPLY` is decimal 232 at `include/standard-headers/linux/input-event-codes.h:314`, comment "Stop before KEY_REPLY for migration compatibility" `:304`). The event is still put on the virtqueue unfiltered (`hw/input/virtio-input-hid.c:90-94`), but the guest evdev driver ignores codes it was not told the device supports. Any Linux keycode ≥ 232 is therefore effectively lost on virtio-keyboard.
  - **usb-kbd** goes through `qemu_input_linux_to_scancode` → `qemu_input_map_linux_to_qnum`; a keycode with no qnum entry becomes scancode 0 (`ui/input-keymap.c:61-62, 80`), is queued by `hid_keyboard_event` (`hw/input/hid.c:224-242`) and then discarded because `hid_usage_keys[0] == 0x00` (`hw/input/hid.c:40-41`) hits `case 0x00: return;` in `hid_keyboard_process_keycode` (`hw/input/hid.c:259-266`).
  - **PS/2** maps through `qemu_input_map_linux_to_atset1/2/3`; a zero result logs `"ps2: ignoring key %u"` (`hw/input/ps2.c:407-421` for set 1).

**Recommended wrapper — `QKbdState`** (`include/ui/kbd-state.h`, `ui/kbd-state.c`): all GUI backends (cocoa `ui/cocoa.m:98,2021`, sdl2 `ui/sdl2-input.c:45`, vnc `ui/vnc.c:4268`, dbus `ui/dbus-console.c:589`) go through it.

```c
QKbdState *qkbd_state_init(QemuConsole *con);                    /* kbd-state.h:38  */
void qkbd_state_free(QKbdState *kbd);                            /* kbd-state.h:45  */
void qkbd_state_key_event(QKbdState *kbd, unsigned int lnx, bool down); /* :61 */
void qkbd_state_set_delay(QKbdState *kbd, int delay_ms);         /* kbd-state.h:72  */
bool qkbd_state_key_get(QKbdState *kbd, unsigned int lnx);       /* kbd-state.h:82  */
bool qkbd_state_modifier_get(QKbdState *kbd, QKbdModifier mod);  /* kbd-state.h:92  */
void qkbd_state_lift_all_keys(QKbdState *kbd);                   /* kbd-state.h:102 */
void qkbd_state_switch_console(QKbdState *kbd, QemuConsole *con);/* kbd-state.h:113 */
```
`qkbd_state_key_event` (`ui/kbd-state.c:41-114`): drops `lnx >= KEY_CNT` (`:45-47`); filters key-up for keys not tracked as down (so host-hotkey-swallowed key-downs don't produce spurious ups, `:51-65`); tracks SHIFT/CTRL/ALT/ALTGR/NUMLOCK/CAPSLOCK modifier bits (`QKbdModifier`, `include/ui/kbd-state.h:14-26`, update `ui/kbd-state.c:73-105`); then, **only if `qemu_console_is_graphic(kbd->con)`**, calls `qemu_input_event_send_key_linux(kbd->con, lnx, down)` and optionally `qemu_input_event_send_key_delay` (`ui/kbd-state.c:107-113`). `qkbd_state_lift_all_keys` sends key-up for every pressed key (`ui/kbd-state.c:116-125`) — used on focus loss (`ui/cocoa.m:1110-1115, 1297-1302`).

**(added) Autorepeat is forwarded, not filtered.** `qkbd_state_key_event` deliberately passes key-down on an already-down key through as autorepeat ("key-down events on already pressed keys are *not* suspicious, those are keyboard autorepeat events", `ui/kbd-state.c:61-62`), and `ui/cocoa.m` never consults `[event isARepeat]` (grep for `isARepeat` in `ui/cocoa.m` returns nothing). The guest therefore receives host-generated repeat downs; a backend that wants guest-side typematic repeat instead must drop host repeats itself before calling `qkbd_state_key_event`.

**(added) Text consoles (monitor/serial) — `qkbd_state_key_event` sends nothing there.** Because of the `qemu_console_is_graphic()` gate (`ui/kbd-state.c:108`; `qemu_console_is_graphic(NULL)` is also false, `ui/console.c:1282-1285`), a backend must branch on `QEMU_IS_TEXT_CONSOLE(con)` / `qemu_console_is_graphic(con)` itself. The clean API for a text console is
```c
bool qemu_text_console_put_linux(QemuTextConsole *s, unsigned int lnx, bool ctrl);
void qemu_text_console_put_keysym(QemuTextConsole *s, int keysym);
```
(`include/ui/console.h:83-85`). `qemu_text_console_put_linux` (`ui/console.c:344-369`) maps a Linux keycode through the built-in `linux_to_keysym` / `ctrl_linux_to_keysym` tables (`ui/console.c:319-342`: arrows, Home/End/PgUp/PgDn, Delete, Tab, Backspace) and returns `false` for anything else — so the caller still sends printable characters via `qemu_text_console_put_keysym`. SDL2 is the reference pattern: it calls `qkbd_state_key_event` unconditionally (for modifier tracking), then on key-down for a text console sends `'\n'` for `KEY_ENTER` and otherwise `qemu_text_console_put_linux(s, lnx, qkbd_state_modifier_get(kbd, QKBD_MOD_CTRL))` (`ui/sdl2-input.c:45-60`). cocoa.m instead keeps its own hand-written `kVK_* → QEMU_KEY_*` tables in `handleMonitorInput:` (`ui/cocoa.m:662-688`) and falls back to `[event characters]` (`:701-706`) before `qemu_text_console_put_keysym` (`:708-711`); the `QEMU_KEY_*` keysym constants are at `include/ui/console.h:59-81`. Using `qemu_text_console_put_linux` avoids duplicating cocoa's tables.

### 1.5 Pointer buttons

```c
void qemu_input_queue_btn(QemuConsole *src, InputButton btn, bool down);
void qemu_input_update_buttons(QemuConsole *src, uint32_t *button_map,
                               uint32_t button_old, uint32_t button_new);
```
(`include/ui/input.h:72-74`)

- `qemu_input_queue_btn` (`ui/input.c:441-452`): sends one `INPUT_EVENT_KIND_BTN` event (no sync).
- `qemu_input_update_buttons` (`ui/input.c:454-467`): iterates `btn = 0 .. INPUT_BUTTON__MAX-1`, `mask = button_map[btn]`, and calls `qemu_input_queue_btn(src, btn, button_new & mask)` for every button whose masked state changed. Backend example with a `uint32_t bmap[INPUT_BUTTON__MAX]` indexed by `InputButton`: `ui/sdl2.c:318-330`.
- Wheel: emit a **down then up pair, each followed by sync** — cocoa `ui/cocoa.m:927-944`, sdl2 `ui/sdl2.c:575-590`, gtk `ui/gtk.c:1169-1179`. Device side: virtio-input turns the *down* half of `WHEEL_UP`/`WHEEL_DOWN` into `EV_REL REL_WHEEL +1/-1` (`hw/input/virtio-input-hid.c:97-104`; the *up* half goes through `keymap_button[]` as `EV_KEY BTN_GEAR_UP/DOWN value 0`, `:105-109`). **(corrected)** USB HID adjusts `dz` only on the *down* half and the direction is button-dependent: `INPUT_BUTTON_WHEEL_UP` → `e->dz--`, `INPUT_BUTTON_WHEEL_DOWN` → `e->dz++` (`hw/input/hid.c:145-151`); button-up does nothing to `dz` (`:152-154`). (The sign is inverted again when the report is built, "Appears we have to invert the wheel direction", `hw/input/hid.c:387-388`.)

**(added) Device-side button coverage — what the backend can usefully send:**
- USB HID mouse/tablet accept `LEFT/RIGHT/MIDDLE/SIDE/EXTRA` as report bits `0x01/0x02/0x04/0x08/0x10` (`bmap[]`, `hw/input/hid.c:114-120`); virtio mouse/tablet accept `LEFT/RIGHT/MIDDLE/WHEEL_UP/WHEEL_DOWN/SIDE/EXTRA/TOUCH` via `keymap_button[]` (`hw/input/virtio-input-hid.c:28-37`). SDL2 maps X1/X2 to `SIDE`/`EXTRA` (`ui/sdl2.c:322-323`).
- cocoa.m sends *every* `otherMouseDown:`/`otherMouseUp:` as `INPUT_BUTTON_MIDDLE` regardless of `[event buttonNumber]` (`ui/cocoa.m:1017-1020, 1051-1054`), so a new macOS backend can improve on it by mapping buttons 3/4 to `SIDE`/`EXTRA`.
- `INPUT_BUTTON_WHEEL_LEFT`/`WHEEL_RIGHT` have **no entry** in virtio's `keymap_button[]` (`hw/input/virtio-input-hid.c:28-37`) and are dropped with a `LOG_GUEST_ERROR "unmapped button"` on the down half (`:110-115`); USB HID only converts `WHEEL_UP/DOWN` into `dz` (`hw/input/hid.c:147-151`). Horizontal wheel is thus silently ignored by both device families even though cocoa emits it (`ui/cocoa.m:920-946`).

**`InputButton` enum** — QAPI `qapi/ui.json:1064-1066`: `'left', 'middle', 'right', 'wheel-up', 'wheel-down', 'side', 'extra', 'wheel-left', 'wheel-right', 'touch'`. Generated C names (`qemu-build/qapi/qapi-types-ui.h:406-417`):
```c
typedef enum InputButton {
    INPUT_BUTTON_LEFT,
    INPUT_BUTTON_MIDDLE,
    INPUT_BUTTON_RIGHT,
    INPUT_BUTTON_WHEEL_UP,
    INPUT_BUTTON_WHEEL_DOWN,
    INPUT_BUTTON_SIDE,
    INPUT_BUTTON_EXTRA,
    INPUT_BUTTON_WHEEL_LEFT,
    INPUT_BUTTON_WHEEL_RIGHT,
    INPUT_BUTTON_TOUCH,
    INPUT_BUTTON__MAX,
} InputButton;
```
`side`/`extra` = front/rear side buttons of a 5-button mouse (since 2.9), `touch` = multi-touch contact (since 8.1) (`qapi/ui.json:1056-1060`).

### 1.6 Pointer motion

```c
bool qemu_input_is_absolute(const QemuConsole *con);
int qemu_input_scale_axis(int value, int min_in, int max_in, int min_out, int max_out);
void qemu_input_queue_rel(QemuConsole *src, InputAxis axis, int value);
void qemu_input_queue_abs(QemuConsole *src, InputAxis axis, int value,
                          int min_in, int max_in);
```
(`include/ui/input.h:76-82`)

- `qemu_input_is_absolute` (`ui/input.c:469-476`): finds the current handler for `REL|ABS` on `con` and returns true iff its mask includes `INPUT_EVENT_MASK_ABS`.
- `qemu_input_queue_abs` (`ui/input.c:515-529`): scales `value` from `[min_in, max_in]` to `[INPUT_EVENT_ABS_MIN, INPUT_EVENT_ABS_MAX]` with `qemu_input_scale_axis` (`ui/input.c:489-500`: `((value - min_in) * range_out) / range_in + min_out`, 64-bit intermediate; degenerate range → midpoint) and sends `INPUT_EVENT_KIND_ABS`. **Pass raw pixel coordinates and the surface size** — do not pre-scale to 0x7FFF yourself.
- `qemu_input_queue_rel` (`ui/input.c:502-513`): sends the delta unchanged as `INPUT_EVENT_KIND_REL`.
- Neither syncs; call `qemu_input_event_sync()` after X and Y.

**(added) No clamping anywhere in the absolute path — the backend must clamp.** `qemu_input_scale_axis` is a pure linear map (`ui/input.c:489-500`) and `qemu_input_queue_abs` forwards the result without range checks (`ui/input.c:515-529`), so a `value` outside `[min_in, max_in]` yields a negative or `> 0x7FFF` coordinate. The devices forward it verbatim: virtio-tablet packs `evt->abs.value` straight into `EV_ABS` (`hw/input/virtio-input-hid.c:124-128`) beyond the `absinfo` max it advertised (`:413-423`); USB tablet stores it in `xdx/ydy` (`hw/input/hid.c:136-142`), does not clamp for `HID_TABLET` (only `HID_MOUSE` is clamped to ±127, `hw/input/hid.c:367-375`) and packs it as `dx & 0xff, dx >> 8` (`hw/input/hid.c:406-421`). GTK guards against this by returning early when `fbx/fby` is `< 0` or `>= surface_width/height` (`ui/gtk.c:1025-1030`); D-Bus rejects `x >= width || y >= height` (`ui/dbus-console.c:465-473`); cocoa.m does **not** clamp (`ui/cocoa.m:972-978`) and only relies on `mouseExited:` ungrabbing in absolute mode (`ui/cocoa.m:988-993`). A backend should clamp `x` to `[0, width-1]` and `y` to `[0, height-1]` (or drop the event) before calling `qemu_input_queue_abs`.

**`InputAxis` enum** — `qapi/ui.json:1075-1076` `'x','y'`; C: `INPUT_AXIS_X`, `INPUT_AXIS_Y`, `INPUT_AXIS__MAX` (`qemu-build/qapi/qapi-types-ui.h:425-428`).

**`InputMoveEvent`** (`qapi/ui.json:1140-1142`): `{ axis: InputAxis, value: int }`; **`InputBtnEvent`** (`qapi/ui.json:1124-1126`): `{ button: InputButton, down: bool }`.

### 1.7 Mouse-mode change notifier

```c
void qemu_add_mouse_mode_change_notifier(Notifier *notify);
void qemu_remove_mouse_mode_change_notifier(Notifier *notify);
```
(`include/ui/input.h:104-105`, `ui/input.c:565-573`). Fired (with `data == NULL`) on every handler register/activate/deactivate/unregister via `notify_input_changed` (`ui/input.c:51-57`, called at `:69, 78, 85, 94`). Cocoa registers one at init (`ui/cocoa.m:2022`) and re-evaluates `qemu_input_is_absolute` from it (`ui/cocoa.m:1777-1786` → `notifyMouseModeChange` `ui/cocoa.m:1083-1101`).

**(added) Notifier lifetime rules.** `Notifier` is an intrusive `QLIST` node — `struct Notifier { void (*notify)(Notifier *, void *); QLIST_ENTRY(Notifier) node; }` (`include/qemu/notify.h:21-25`) — and `notifier_list_add` links the caller's own struct into the list (`QLIST_INSERT_HEAD`, `util/notify.c:24-27`); `notifier_remove` unlinks it (`util/notify.c:29-32`). The struct must therefore be static or outlive the registration, and it must be removed before it is freed or the backend is torn down: cocoa `qemu_remove_mouse_mode_change_notifier(&mouse_mode_change_notifier)` in cleanup (`ui/cocoa.m:2047`, static notifier `:1784-1786`); sdl2 (`ui/sdl2.c:799`); dbus removes both LED and mouse-mode notifiers in dispose (`ui/dbus-console.c:155, 157`); vnc per-client mouse-mode notifier (`ui/vnc.c:1321-1323`) and display LED notifier (`ui/vnc.c:3506-3508`); spice (`ui/spice-input.c:270, 278`).

**(added) Notifier thread context — never touch UI-toolkit state directly from the callback.** `notifier_list_notify` runs every callback synchronously in the caller's thread (`util/notify.c:34-41`). The callers are `qemu_input_handler_register/activate/deactivate/unregister` and `qemu_input_handler_set_leds_mask` (`ui/input.c:51-57, 69, 78, 85, 94, 142`), which are invoked from:
- device realize/unrealize (`hw/input/hid.c:528-544`, `hw/input/virtio-input-hid.c:165-179`),
- guest USB traffic — `hid_pointer_activate` from `hid_pointer_poll` (`hw/input/hid.c:344-360`) via `usb_hid_handle_control`/`usb_hid_handle_data` (`hw/usb/dev-hid.c:612, 645, 666, 674`),
- guest virtio status writes — `virtio_set_status` → `virtio_input_set_status` → `virtio_input_hid_change_active` (`hw/virtio/virtio.c:2307-2308`, `hw/input/virtio-input.c:192-205`, `hw/input/virtio-input-hid.c:181-190`),
- guest LED writes — `hid_keyboard_write` (`hw/input/hid.c:474`, from `HID_SET_REPORT` `hw/usb/dev-hid.c:617-619`), `ps2_set_ledstate` (`hw/input/ps2.c:576-581`), `virtio_input_hid_handle_status` (`hw/input/virtio-input-hid.c:192-213`),
- HMP/QMP `mouse_set` (`qemu_mouse_set` → `qemu_input_handler_activate`, `ui/input.c:601-625`).

All of these run on a BQL-holding QEMU thread — the main loop or a **vCPU thread** (MMIO/PIO-triggered device code) — never on the AppKit thread. This is why cocoa's callback does nothing but `dispatch_async(dispatch_get_main_queue(), ^{ [cocoaView notifyMouseModeChange]; })` (`ui/cocoa.m:1777-1782`). Because devices typically register (and `usb-kbd` activates) before the display backend initialises, the backend must also query `qemu_input_is_absolute()` once at init rather than waiting for a notification (cocoa: `[cocoaView notifyMouseModeChange]` right after registering, `ui/cocoa.m:2023`; spice calls its notifier by hand, `ui/spice-input.c:264`).

### 1.8 Trace events (for debugging): `input_event_key_qcode`, `input_event_btn`, `input_event_rel`, `input_event_abs`, `input_event_mtt`, `input_event_sync` (`ui/trace-events:130-135`).

### 1.9 (added) Console / DisplayChangeListener lifecycle

- `qemu_console_register_listener(con, dcl, ops)` asserts `!dcl->ds` and sets `dcl->con = con`, `dcl->ops = ops` (`ui/console.c:631-651`, assert `:635`, `:637-638`); it also starts the `gui_update` refresh timer if the ops have `dpy_refresh` (`gui_setup_refresh`, `:643`, `:125-140`). `qemu_console_unregister_listener` unlinks and clears `dcl->ds` (`ui/console.c:673-683`).
- `qemu_console_lookup_default()` returns the first *graphic* console or, failing that, the first console of any kind (`ui/console.c:1189-1199`) — so `dcl.con` can be a text console (e.g. `-nographic`-style setups with only a serial/monitor VC), which is why the text-console branch in §1.4 matters. cocoa uses it at init (`ui/cocoa.m:2019-2020`), as does VNC when no `display=` is given (`ui/vnc.c:4264`).
- Switching consoles: `qemu_console_unregister_listener(&dcl)` → `qkbd_state_switch_console(kbd, con)` → `qemu_console_register_listener(con, &dcl, &dcl_ops)` → re-check mouse mode (`ui/cocoa.m:293-305`). `qkbd_state_switch_console` lifts all keys on the *old* console first, then stores the new one (`ui/kbd-state.c:127-131`).
- Cleanup order (cocoa): `qemu_console_unregister_listener`, `qkbd_state_free`, remove mouse-mode notifier (`ui/cocoa.m:2045-2047`); sdl2 does the same per console (`ui/sdl2.c:799-804`).

---

## 2. `QKeyCode` and mapping macOS virtual keycodes

### 2.1 Canonical list
`qapi/ui.json:952-976` (`{ 'enum': 'QKeyCode', 'prefix': 'Q_KEY_CODE', 'data': [ 'unmapped', 'shift', 'shift_r', 'alt', 'alt_r', 'ctrl', 'ctrl_r', 'menu', 'esc', '1'…'0', 'minus', 'equal', 'backspace', 'tab', 'q'…, 'ret', …, 'caps_lock', 'f1'…'f10', 'num_lock', 'scroll_lock', 'kp_divide', 'kp_multiply', 'kp_subtract', 'kp_add', 'kp_enter', 'kp_decimal', 'sysrq', 'kp_0'…'kp_9', 'less', 'f11', 'f12', 'print', 'home', 'pgup', 'pgdn', 'end', 'left', 'up', 'down', 'right', 'insert', 'delete', 'stop', 'again', 'props', 'undo', 'front', 'copy', 'open', 'paste', 'find', 'cut', 'lf', 'help', 'meta_l', 'meta_r', 'compose', 'pause', 'ro', 'hiragana', 'henkan', 'yen', 'muhenkan', 'katakanahiragana', 'kp_comma', 'kp_equals', 'power', 'sleep', 'wake', 'audionext', …, 'lang1', 'lang2', 'f13'…'f24' ]`). Generated C enum `typedef enum QKeyCode { Q_KEY_CODE_UNMAPPED, … Q_KEY_CODE__MAX }` at `qemu-build/qapi/qapi-types-ui.h:212-375` (e.g. `Q_KEY_CODE_ALT:216`, `Q_KEY_CODE_ALT_R:217`, `Q_KEY_CODE_CAPS_LOCK:274`, `Q_KEY_CODE_META_L:330`, `Q_KEY_CODE_META_R:331`). `'sysrq'` is a synonym for `'print'` (`qapi/ui.json:944-948`).

### 2.2 How `ui/cocoa.m` maps kVK_* → guest
Cocoa **does not go through QKeyCode at all**. It maps the macOS virtual keycode directly to a Linux keycode with the generated table and feeds `QKbdState`:

```c
static int cocoa_keycode_to_linux(int keycode)
{
    if (qemu_input_map_osx_to_linux_len <= keycode) {
        error_report("(cocoa) warning unknown keycode 0x%x", keycode);
        return 0;
    }
    return qemu_input_map_osx_to_linux[keycode];
}
```
(`ui/cocoa.m:144-151`). Index space = `[NSEvent keyCode]` = Carbon `kVK_*` virtual keycode (cocoa.m includes `<Carbon/Carbon.h>` at `ui/cocoa.m:52`; `kVK_*` names are used at `:665-674, 802-859`). Called from `NSEventTypeKeyDown`/`KeyUp` (`ui/cocoa.m:872, 908`) and then `qkbd_state_key_event(kbd, keycode, true/false)` (`ui/cocoa.m:902, 917`), only when `qemu_console_is_graphic(dcl.con)`; for text consoles it calls `handleMonitorInput:` → `qemu_text_console_put_keysym` (`ui/cocoa.m:650-712`, keysym constants `include/ui/console.h:59-81`; see §1.4 for the simpler `qemu_text_console_put_linux` alternative).

If you *do* need a `QKeyCode` (e.g. for QMP/trace), do `qemu_input_linux_to_qcode(qemu_input_map_osx_to_linux[kVK])` (`ui/input-keymap.c:24-30`).

### 2.3 Non-obvious keys **(corrected line citations)**

Values from the generated tables `qemu-build/ui/input-keymap-osx-to-linux.c.inc` (column 3 citations) and `qemu-build/ui/input-keymap-linux-to-qcode.c.inc` (column 4 citations). Every line number below was re-read from the generated files.

| macOS key (kVK) | osx code | Linux keycode (`osx-to-linux.c.inc`) | QKeyCode (`linux-to-qcode.c.inc`) |
|---|---|---|---|
| Command (`kVK_Command`) | 0x37 | `KEY_LEFTMETA` 125 (`:62`) | `meta_l` / `Q_KEY_CODE_META_L` (`:133`) |
| Right Command | 0x36 | `KEY_RIGHTMETA` 126 (`:61`) | `meta_r` (`:134`) |
| Option (`kVK_Option`) | 0x3A | `KEY_LEFTALT` 56 (`:65`) | `alt` / `Q_KEY_CODE_ALT` (`:64`) |
| Right Option | 0x3D | `KEY_RIGHTALT` 100 (`:68`) | `alt_r` (`:108`) |
| Control / Right Control | 0x3B / 0x3E | `KEY_LEFTCTRL` 29 / `KEY_RIGHTCTRL` 97 (`:66`, `:69`) | `ctrl` / `ctrl_r` |
| Shift / Right Shift | 0x38 / 0x3C | `KEY_LEFTSHIFT` 42 / `KEY_RIGHTSHIFT` 54 (`:63`, `:67`) | `shift` / `shift_r` |
| Caps Lock | 0x39 | `KEY_CAPSLOCK` 58 (`:64`) | `caps_lock` (`:66`) |
| Fn (`kVK_Function`) | 0x3F | `KEY_FN` 464 = 0x1d0 (`:70`; `include/standard-headers/linux/input-event-codes.h:530`) | **`unmapped`** (`:418`) — see note below |
| Keypad Clear (`kVK_ANSI_KeypadClear`) | 0x47 | `KEY_NUMLOCK` 69 (`:75`) | `num_lock` (`:77`) |
| Keypad 0–7 | 0x52–0x59 | `KEY_KP0`..`KEY_KP7` (`:85-92`) | `kp_0`..`kp_7` |
| Keypad 8–9 | 0x5B, 0x5C | `KEY_KP8`, `KEY_KP9` (`:94-95`; `:93` in between is F20) | `kp_8`, `kp_9` |
| Keypad `.` `*` `+` | 0x41, 0x43, 0x45 | `KEY_KPDOT` 83, `KEY_KPASTERISK` 55, `KEY_KPPLUS` 78 (`:72-74`) | `kp_decimal`, `kp_multiply`, `kp_add` |
| Keypad `/` Enter `-` | 0x4B, 0x4C, 0x4E | `KEY_KPSLASH` 98, `KEY_KPENTER` 96, `KEY_KPMINUS` 74 (`:79-81`) | `kp_divide`, `kp_enter` (`:104`), `kp_subtract` |
| Keypad `=` | 0x51 | `KEY_KPEQUAL` 117 (`:84`) | `kp_equals` (`:125`) |
| JIS Keypad Comma | 0x5F | `KEY_KPJPCOMMA` 95 (`:98`) | `unmapped` (`:103`) |
| ISO Section (`kVK_ISO_Section`) | 0x0A | `KEY_102ND` 86 (`:18`) | `less` (`:94`) |
| Delete (backspace) / ForwardDelete | 0x33 / 0x75 | `KEY_BACKSPACE` 14 (`:59`) / `KEY_DELETE` 111 (`:118`) | `backspace` / `delete` |
| 0x6E (unnamed, "Menu" on PC kbds) | 0x6E | `KEY_COMPOSE` 127 (`:112`) | `compose` (`:135`) |
| JIS Eisu / Kana | 0x66 / 0x68 | `KEY_HANJA` 123 (`:105`) / `KEY_HANGEUL` 122 (`:107`) | `lang2` (`:131`) / `lang1` (`:130`) |
| Volume Up/Down/Mute | 0x48/0x49/0x4A | `KEY_VOLUMEUP` 115, `KEY_VOLUMEDOWN` 114, `KEY_MUTE` 113 (`:76-78`) | `volumeup` (`:123`) / `volumedown` / `audiomute` (`:121`) |
| F13 / F14 / F15 / F16 | 0x69 / 0x6B / 0x71 / 0x6A | `KEY_F13` 183 (`:108`), `KEY_F14` 184 (`:110`), `KEY_F15` 185 (`:114`), `KEY_F16` 186 (`:109`) | `f13` (`:191`)..`f16` |
| F17 / F18 / F19 / F20 | 0x40 / 0x4F / 0x50 / 0x5A | `KEY_F17` 187 (`:71`), `KEY_F18` 188 (`:82`), `KEY_F19` 189 (`:83`), `KEY_F20` 190 (`:93`) | `f17`..`f20` (`:198`) |

(Previously mis-cited lines, for the record: `:60` is Escape, `:80/:81` are KeypadEnter/KeypadMinus, `:106` is F11, `:111` is F10, `:113` is F12, `:116` is Home.)

**(corrected) Fn (`kVK_Function`) effectively reaches no guest device in 11.1.1.** The table does map it to `KEY_FN` 464, and `qemu_input_event_send` only drops `key == 0` (`ui/input.c:361-363`), so the event is delivered to the active keyboard handler — but:
- **virtio-keyboard** puts `EV_KEY 464` on the virtqueue (`hw/input/virtio-input-hid.c:90-94`) yet only advertises keycodes 1..231 (`for (i = KEY_ESC; i < KEY_REPLY; i++)`, `hw/input/virtio-input-hid.c:306-308`; `KEY_REPLY` = decimal 232, `include/standard-headers/linux/input-event-codes.h:314`), so the guest evdev driver discards it.
- **usb-kbd**: `qemu_input_map_linux_to_qnum` has no `[0x1d0]` entry (grep of `qemu-build/ui/input-keymap-linux-to-qnum.c.inc` returns nothing), so `qemu_input_linux_to_scancode` yields scancode 0 (`ui/input-keymap.c:61-62`), which `hid_keyboard_process_keycode` drops via `hid_usage_keys[0] == 0x00` → `case 0x00: return;` (`hw/input/hid.c:40-41, 259-266`).
- **PS/2**: no `[0x1d0]` entry in `linux-to-atset1/atset2` either (grep returns nothing) → `"ps2: ignoring key 464"` (`hw/input/ps2.c:407-421`).

Treat Fn as **host-only** (e.g. use it for backend hotkeys) rather than forwarding it. The same reasoning applies to any Linux keycode ≥ 232 on virtio-keyboard (§1.4).

Cocoa-specific behaviour for these keys (`ui/cocoa.m`):
- **Option/Command swap**: with `-display cocoa,swap-opt-cmd=on` (`qapi/ui.json:1440-1442`, `ui/cocoa.m:101, 1992-1994`), Option toggles `KEY_LEFTMETA/RIGHTMETA` and Command toggles `KEY_LEFTALT/RIGHTALT` instead (`ui/cocoa.m:826-868`).
- **Command is only forwarded while the mouse is grabbed** (`ui/cocoa.m:846-868`); left Command additionally requires `left_command_key_enabled` (`-display cocoa,left-command-key=off` disables it, `ui/cocoa.m:100, 1996-1998`, `qapi/ui.json:1431-1433`). When not grabbed, Cmd+key combos are returned to macOS (`ui/cocoa.m:874-877`) and the matching key-up is swallowed (`ui/cocoa.m:910-914`).
- **Modifiers are driven by `NSEventTypeFlagsChanged`** (`ui/cocoa.m:800-870`): each `kVK_Shift/RightShift/Control/RightControl/Option/RightOption/Command/RightCommand` toggles its Linux key via `toggleKey:` (`ui/cocoa.m:645-647`, which flips state using `qkbd_state_key_get`). In addition, on **every** event the code checks `[event modifierFlags]` and sends key-ups for any modifier whose flag is clear (`ui/cocoa.m:772-797`) to resynchronise after the app was inactive (rationale in the comment `ui/cocoa.m:729-765`).
- **Caps Lock**: macOS reports it as a toggle state in `NSEventModifierFlagCapsLock`, so cocoa compares that flag with `qkbd_state_modifier_get(kbd, QKBD_MOD_CAPSLOCK)` and, on mismatch, sends a **KEY_CAPSLOCK down + up pair** (`ui/cocoa.m:766-770`). `QKbdState` flips its CAPSLOCK modifier bit on each key-down (`ui/kbd-state.c:92-96`).
- **Fn**: no special handling in cocoa.m (grep for `kVK_Function` in `ui/cocoa.m` returns nothing); it passes through the table as `KEY_FN` and is then lost in the device as described above.
- **Numeric keypad**: no special handling; goes through the table (entries above).
- **Autorepeat**: not filtered (no `isARepeat` in `ui/cocoa.m`; see §1.4).
- Ctrl+Option+1..9 switches console, Ctrl+Option+G ungrabs — consumed by the host, not sent (`ui/cocoa.m:881-899`).

---

## 3. Generated keycodemapdb tables (`ui/meson.build`, `subprojects/keycodemapdb`)

- The pairs generated are listed at `ui/meson.build:1-18`: `atset1→linux, linux→qcode, linux→atset1, linux→atset2, linux→atset3, qcode→linux, linux→qnum, linux→sun, qnum→linux, usb→linux, win32→linux, x11→linux, xorgkbd→linux, xorgxquartz→linux, xorgxwin→linux, osx→linux`. Each becomes `input-keymap-<from>-to-<to>.c.inc` with `--varname qemu_input_map_<from>_to_<to>` via `keymap-gen code-map --lang glib2` (`ui/meson.build:20-33`), and all are `#include`d by `ui/input-keymap.c:7-22` (osx at `:22`).
- Declaration in the public header:
  ```c
  extern const guint qemu_input_map_osx_to_linux_len;
  extern const guint16 qemu_input_map_osx_to_linux[];
  ```
  (`include/ui/input.h:152-153`). Generated definition: `const guint16 qemu_input_map_osx_to_linux[256] = { [0x0] = 0x1e, /* osx:0 (ANSI_A) -> linux:30 (KEY_A) */ … [0xff] = 0x0 };` and `const guint qemu_input_map_osx_to_linux_len = sizeof(...)/sizeof(...[0]);` (`qemu-build/ui/input-keymap-osx-to-linux.c.inc:7-8, 128-130`). **Index type: macOS virtual keycode (`kVK_*`, `[NSEvent keyCode]`, 0..255); value type: `guint16` Linux evdev keycode; unlisted indices are 0 = `KEY_RESERVED`** (which `qemu_input_event_send` silently drops, `ui/input.c:361-363`). 121 initialiser lines are present, 120 of them non-zero (the explicit `[0xff] = 0x0` at `:128` is the exception).
- **An `osx → qcode` table is NOT generated** (not in `ui/meson.build:1-18`; `find` for `input-keymap-osx-to-qcode*` returns nothing). The keycodemapdb tool *could* produce one — both `MAP_OSX = "osx"` and `MAP_QCODE = "qcode"` exist (`subprojects/keycodemapdb/tools/keymap-gen:27, 83`) and `code-map` takes arbitrary from/to names (`:1037-1047, 1126`) — but you would have to add `['osx','qcode']` to the `keymaps` list in `ui/meson.build:1-18` and an `#include` in `ui/input-keymap.c`. **The preferred, zero-new-code path is `qemu_input_map_osx_to_linux` + `qemu_input_event_send_key_linux` / `qkbd_state_key_event`**, exactly as cocoa.m does — the input layer's native key representation is the Linux keycode anyway.
- keycodemapdb source: `subprojects/keycodemapdb.wrap` (git `https://gitlab.com/qemu-project/keycodemapdb.git` rev `f5772a62ec52591ff6870b7e8ef32482371f22c6`), data `subprojects/keycodemapdb/data/keymaps.csv` (columns include `"OS-X Name","OS-X Keycode"` and `"QEMU QKeyCode"`, `keymaps.csv:1`), exposed to meson as `keymaps_csv` / `keymap_gen` (`subprojects/keycodemapdb/meson.build`).
- Other useful generated tables declared in `include/ui/input.h:107-153`: `qemu_input_map_usb_to_linux` (used by SDL2 for HID usage codes, `ui/sdl2-input.c:39-42`), `qemu_input_map_qcode_to_linux`, `qemu_input_map_linux_to_qcode`, `qemu_input_map_linux_to_qnum`.

---

## 4. Mouse modes, cocoa coordinate conversion, mouse grab

### 4.1 Absolute vs relative
- The *active* pointer handler decides: tablets (`usb-tablet` → `hid_tablet_handler` `hw/input/hid.c:521-526`; `virtio-tablet` → `virtio_tablet_handler` `hw/input/virtio-input-hid.c:376-381`) carry `INPUT_EVENT_MASK_ABS`; mice (`usb-mouse` `hw/input/hid.c:514-519`, PS/2 `hw/input/ps2.c:1248-1253`, `virtio-mouse` `hw/input/virtio-input-hid.c:322-327`) carry `INPUT_EVENT_MASK_REL`. `qemu_input_is_absolute(con)` returns whether the *first matching* handler has ABS (`ui/input.c:469-476`). QMP `query-mice` reports the same (`ui/input.c:575-599`), and `qemu_mouse_set` (HMP `mouse_set`) re-activates a specific one (`ui/input.c:601-625`).
- A device sends absolute values straight to the guest in the 0..0x7FFF range: virtio-tablet `EV_ABS` (`hw/input/virtio-input-hid.c:124-128`) with absinfo min/max = `INPUT_EVENT_ABS_MIN/MAX` (`:416-417, 422-423`); USB HID stores `evt->abs.value` in `xdx/ydy` (`hw/input/hid.c:136-142`). Neither clamps (§1.6).

### 4.2 Cocoa's decision and conversion
State (`ui/cocoa.m:181-190`): `isAbsoluteEnabled` mirrors `qemu_input_is_absolute()` ("only updated on next refresh"), `isMouseGrabbed` = whether GUI events go to the guest. `isAbsoluteEnabled` is refreshed by `notifyMouseModeChange` (`ui/cocoa.m:1083-1101`), which reads `qemu_input_is_absolute(dcl.con)` under the BQL, and — if grabbed — ungrabs when switching to absolute or re-associates the cursor for relative; it is invoked at init (`:2023`), on console switch (`:303`), and from the mouse-mode notifier (`:1777-1786`, registered `:2022`).

```objc
- (void) handleMouseEvent:(NSEvent *)event
{
    if (!isMouseGrabbed) {
        return;
    }

    with_bql(^{
        if (isAbsoluteEnabled) {
            CGFloat d = (CGFloat)screen.height / [self frame].size.height;
            NSPoint p = [event locationInWindow];

            /* Note that the origin for Cocoa mouse coords is bottom left, not top left. */
            qemu_input_queue_abs(dcl.con, INPUT_AXIS_X, p.x * d, 0, screen.width);
            qemu_input_queue_abs(dcl.con, INPUT_AXIS_Y, screen.height - p.y * d, 0, screen.height);
        } else {
            qemu_input_queue_rel(dcl.con, INPUT_AXIS_X, [event deltaX]);
            qemu_input_queue_rel(dcl.con, INPUT_AXIS_Y, [event deltaY]);
        }

        qemu_input_event_sync();
    });
}
```
(`ui/cocoa.m:965-986`). So: `d` = guest-pixels per view-point (handles zoom-to-fit); X = `p.x * d` in guest pixels; Y is **flipped** (`screen.height - p.y*d`) because AppKit's origin is bottom-left; both are passed with `min_in=0, max_in=screen.width/height` and **`qemu_input_queue_abs` does the 0..0x7FFF scaling** (`ui/input.c:522-524`). No clamping is done here (`:977-978`) — see §1.6. Relative mode passes `[event deltaX]/[event deltaY]` as-is. Buttons: `handleMouseEvent:button:down:` (`ui/cocoa.m:952-963`) queues the button under BQL and then re-sends position; left/right/other down/up map to `INPUT_BUTTON_LEFT/RIGHT/MIDDLE` (`ui/cocoa.m:1007-1054`). Scroll wheel → `WHEEL_UP/DOWN` from `deltaY`, `WHEEL_LEFT/RIGHT` from `deltaX`, as down+sync+up+sync (`ui/cocoa.m:920-946`).

Equivalent patterns in other backends: SDL2 `sdl_send_mouse_event` (`ui/sdl2.c:315-350`, uses `qemu_input_update_buttons` with a bitmask map and `surface_width/height`), GTK `gd_motion_event` (`ui/gtk.c:1015-1043`, converts widget coords to framebuffer coords through scale/offset and **rejects out-of-range absolute positions** `:1025-1030`), D-Bus `dbus_mouse_set_pos` (`ui/dbus-console.c:449-482`, uses `qemu_console_get_width/height(con, 0)` — prototypes `include/ui/console.h:368-369` — and rejects `x >= width || y >= height` `:467-473`).

### 4.3 Mouse grab concept (cocoa)
- `grabMouse` (`ui/cocoa.m:1056-1067`): sets window title hint, hides cursor, `CGAssociateMouseAndMouseCursorPosition(isAbsoluteEnabled)` (i.e. **decouples the host cursor from motion only in relative mode**), `isMouseGrabbed = TRUE` ("while isMouseGrabbed = TRUE, QemuCocoaApp sends all events to [cocoaView handleEvent:]" — `QemuApplication.sendEvent:` at `ui/cocoa.m:1583-1589`).
- `ungrabMouse` (`ui/cocoa.m:1069-1081`): restores title/cursor, re-associates, `isMouseGrabbed = FALSE`, and `raiseAllButtons` (sends button-up for LEFT/RIGHT/MIDDLE under BQL, `ui/cocoa.m:1117-1124`).
- Triggers: absolute mode auto-grabs on `mouseEntered` and ungrabs on `mouseExited` (`ui/cocoa.m:988-1000`); relative mode grabs on `mouseUp` (click into window, `ui/cocoa.m:1037-1044`); Ctrl+Option+G ungrabs (`ui/cocoa.m:893-897`); fullscreen enter/exit grabs/ungrabs (`ui/cocoa.m:1253-1262`); losing key window ungrabs and lifts all keys (`ui/cocoa.m:1297-1302`).
- **Full grab** (`-display cocoa,full-grab=on`, `qapi/ui.json:1435-1438`): installs a `CGEventTapCreate(kCGHIDEventTap, …)` tap for key down/up/flags (`ui/cocoa.m:615-643`) whose callback forwards to `handleEvent:` only while grabbed and swallows the event if handled (`ui/cocoa.m:214-225`) — this is how system combos (Cmd-Tab etc.) reach the guest; requires accessibility permission.

---

## 5. Threading / BQL requirements

- `ui/input.c` itself contains **no** `bql_locked()` assertion (grep for `bql` in `ui/input.c`, `include/ui/input.h`, `ui/console.c` returns nothing). However every path ends in device-emulation code (`s->handler->event(...)`, `ui/input.c:355`; e.g. `virtio_input_send` → virtqueue/IRQ) and `qemu_input_event_send_key_delay` creates/modifies a `QEMU_CLOCK_VIRTUAL` timer (`ui/input.c:430-437`), plus `runstate_is_running()` checks — all of which are BQL-protected global state (BQL semantics: `include/qemu/main-loop.h:258-271, 371-380`; "vCPU threads and the main loop use the BQL to serialize execution of QEMU code", `docs/devel/multiple-iothreads.rst:36-39`). **Treat all `qemu_input_*` / `qkbd_state_*` / `qemu_text_console_*` calls as requiring the BQL.**

- **(added) The Darwin default for `qemu_main`, and what it means for a new macOS backend.** `qemu_main` is a function pointer run on the initial thread; `NULL` means "QEMU's main event loop runs on the initial thread", non-NULL means "the main loop is moved to a purposely created thread and this function is invoked on the initial thread" (`include/qemu-main.h:8-21`). On `CONFIG_DARWIN` it **defaults to `os_darwin_cfrunloop_main`, which just runs `CFRunLoopRun()`** (`system/main.c:60-67`). `main()` releases the BQL and replay mutex after `qemu_init` ("On MacOS, qemu main event loop runs in a background thread, as main thread must be reserved for UI", `system/main.c:73-85`), then — if `qemu_main` is non-NULL — creates the detached `"qemu_main"` thread running `qemu_default_main` (which re-takes the BQL and runs `qemu_main_loop`, `system/main.c:44-56`) and calls `qemu_main()` on the initial thread (`system/main.c:87-91`); otherwise it runs `qemu_default_main` directly (`:92-94`). Consequently, on macOS the QEMU main loop is on the secondary thread for **any** display backend unless that backend resets `qemu_main = NULL` in its init — SDL2 does ("SDL's event polling (in dpy_refresh) must happen on the main thread", `ui/sdl2.c:1017-1018`), GTK does ("GTK's event polling must happen on the main thread", `ui/gtk.c:2820-2821`) — or installs its own, as cocoa does with `qemu_main = cocoa_main` (`ui/cocoa.m:2036`, `cocoa_main` = `[NSApp run]` `:1887-1894`). A new macOS backend must pick one of these two models:
  - **AppKit run loop on the initial thread (cocoa model)**: every DCL callback — `dpy_gfx_update`, `dpy_gfx_switch`, `dpy_refresh`, `dpy_mouse_set`, `dpy_cursor_define` (`dcl_ops`, `ui/cocoa.m:89-95`) — arrives on the `qemu_main` thread with the BQL held and must be hopped to the UI thread (`dispatch_async(dispatch_get_main_queue(), …)` in `cocoa_update` `:1904-1907`, `cocoa_switch` `:1923-1925`, `cocoa_mouse_set` `:1951-1953`, `cocoa_cursor_define` `:1958-1961` which re-takes the BQL with `BQL_LOCK_GUARD()` inside the block; `BQL_LOCK_GUARD` defined `include/qemu/main-loop.h:410-412`), and every UI-thread input call must take the BQL (`with_bql`/`bool_with_bql`, `ui/cocoa.m:113-142`).
  - **`qemu_main = NULL` (SDL/GTK model)**: UI events are pumped from QEMU's main loop on the initial thread, so `dpy_refresh` and event handlers already hold the BQL, at the cost of having to poll the toolkit from `dpy_refresh`.

- **Cocoa proves the rule**: every input call is wrapped — `handleEvent:` runs `handleEventLocked:` inside `bool_with_bql` (`ui/cocoa.m:714-719`), mouse motion/buttons use `with_bql` (`ui/cocoa.m:958-960, 971-985, 1112-1114, 1119-1123`), `qemu_input_is_absolute` is read via `bool_with_bql` (`ui/cocoa.m:1084-1086`). The helpers take the lock only if not already held (`ui/cocoa.m:113-142`, using `bql_locked()`/`bql_lock()`/`bql_unlock()`). The comment at `ui/cocoa.m:2009-2015` also notes init-time callbacks are safe only because "the second thread holds the BQL and is synchronously waiting".

- **(corrected — now with citations)** Backends that pump their UI from QEMU's main loop: SDL2 and GTK both reset `qemu_main = NULL` (`ui/sdl2.c:1018`, `ui/gtk.c:2821`), so their toolkit is driven from the initial thread by QEMU's main loop, which itself prepares/polls/dispatches the glib default `GMainContext` (`glib_pollfds_fill`/`glib_pollfds_poll`, `util/main-loop.c:257-294`) — that is how GTK's signal handlers run. They call `qemu_input_*` from `dpy_refresh`, invoked by the `gui_update` `QEMU_CLOCK_REALTIME` timer (`ui/console.c:99-123, 136-138`), i.e. on the main-loop thread with the BQL already held. VNC, D-Bus and Spice never touch `qemu_main` (grep for `qemu_main` in `ui/vnc.c`, `ui/dbus.c`, `ui/dbus-console.c`, `ui/spice-core.c` returns nothing), so their socket/GDBus/spice-server callbacks run on whichever thread runs `qemu_main_loop` — `qemu_default_main` takes the BQL around it (`system/main.c:48-52`) and the lock is "always taken except while waiting on external events (such as with select)" (`include/qemu/main-loop.h:374-376`), so those callbacks run BQL-held.

- Record/replay: `qemu_input_event_send` goes through `replay_input_event`, which in RECORD mode clones and queues the event and in PLAY mode discards it (`replay/replay-input.c:91-102`); since it is reached only through `qemu_input_event_send` from the callers above, it runs in the same BQL-held context.
- Events are dropped, not queued, when the VM is not running/suspended (`ui/input.c:365-367, 391-393, 426-428`).
- Mouse-mode / LED notifier callbacks run synchronously on the thread that changed the handler list or LED mask — main loop *or vCPU thread* — see §1.7; hop to the UI thread from them.

---

## 6. Keyboard LEDs

**(corrected)** `qemu_add_led_event_handler` / a `kbd_led` handler API — **NOT FOUND in 11.1.1** (`grep -rn "led_event_handler" include/ ui/ hw/input/` returns nothing; the only `kbd_led*` symbols are the VNC/Spice `Notifier` callbacks `kbd_leds` at `ui/vnc.c:1816` and `ui/spice-input.c:90`, and the migration hook `ps2_kbd_ledstate_post_load` at `hw/input/ps2.c:1107`). The current API (all in `include/ui/input.h:155-164`, implemented `ui/input.c:138-153, 478-487`):

```c
/**
 * qemu_input_get_leds_mask() - get the LED mask for the given console
 * @con: a QemuConsole or NULL
 *
 * If @con is NULL, returns the LED state mask for the default console.
 */
uint32_t qemu_input_get_leds_mask(const QemuConsole *con);
void qemu_input_handler_set_leds_mask(QemuInputHandlerState *s, uint32_t leds_mask);
void qemu_input_led_notifier_add(Notifier *n);
void qemu_input_led_notifier_remove(Notifier *n);
```

- Bits (`include/ui/console.h:33-36`, "identical to the ps/2 keyboard bits"):
  ```c
  #define QEMU_SCROLL_LOCK_LED (1 << 0)
  #define QEMU_NUM_LOCK_LED    (1 << 1)
  #define QEMU_CAPS_LOCK_LED   (1 << 2)
  ```
- Devices publish guest LED state with `qemu_input_handler_set_leds_mask` (asserts the handler has `INPUT_EVENT_MASK_KEY`, stores the mask, notifies `leds_notifiers`, `ui/input.c:138-143`): PS/2 (`hw/input/ps2.c:576-581`), USB HID (`hw/input/hid.c:455-478`, notify at `:474`), virtio-keyboard (`hw/input/virtio-input-hid.c:192-213`, notify at `:212`).
- The LED notifier list is also fired whenever a KEY handler is registered/activated/deactivated/unregistered (`ui/input.c:51-57`), so re-read the mask on every callback.
- `qemu_input_get_leds_mask(con)` returns the `leds_mask` of the current KEY handler for `con` (or 0) (`ui/input.c:478-487`).
- **(added) `NULL` does not mean "default console".** Despite the header comment (`include/ui/input.h:155-160`), the implementation calls `qemu_input_find_handler(INPUT_EVENT_MASK_KEY, NULL)` (`ui/input.c:482`), and with `con == NULL` the first loop matches nothing (`ui/input.c:118-125`) and the second matches only handlers with `s->con == NULL` (`:127-134`) — i.e. keyboards **not** bound with `display=`/`head=`. Spice relies on exactly this ("spice has no associated console support", `ui/spice-input.c:93-94`). The same applies to `qemu_input_is_absolute(NULL)` (`ui/input.c:469-476`). A display backend should pass its `dcl.con` (as VNC `ui/vnc.c:1819` and D-Bus `ui/dbus-console.c:378` do) so that devices bound to its console are found first.
- Backend usage pattern (display backend receiving `Notifier *notifier, void *data` with `data == NULL`): VNC `kbd_leds` (`ui/vnc.c:1816-1835`, registered `:4237-4240`, removed `:3506-3508`), Spice (`ui/spice-input.c:90-107, 253-254, 278`), D-Bus (`ui/dbus-console.c:373-381, 591-592, 155`). Minimal form:
  ```c
  static Notifier led_notifier;                       /* static: it is linked into a QLIST, §1.7 */
  static void my_leds(Notifier *n, void *data)
  {
      /* runs on a QEMU thread (main loop or vCPU) with the BQL held -- do NOT touch AppKit here */
      uint32_t leds = qemu_input_get_leds_mask(dcl.con);   /* QEMU_*_LED bits */
      dispatch_async(dispatch_get_main_queue(), ^{ /* … sync host Caps/Num/Scroll indicators … */ });
  }
  led_notifier.notify = my_leds;
  qemu_input_led_notifier_add(&led_notifier);          /* and qemu_input_led_notifier_remove() at cleanup */
  ```
- `ui/cocoa.m` does **not** use the LED API at all (no `leds`/`LED` hits in `ui/cocoa.m`); it instead re-synchronises Caps Lock from the host flag on every event (§2.3).

---

## 7. Minimal backend skeleton derived from the above

```c
#include "ui/console.h"
#include "ui/input.h"
#include "ui/kbd-state.h"
#include "qemu/main-loop.h"
#include "standard-headers/linux/input-event-codes.h"

static DisplayChangeListener dcl;      /* dcl.con set by qemu_console_register_listener, ui/console.c:637 */
static QKbdState *kbd;                 /* kbd = qkbd_state_init(dcl.con);  ui/cocoa.m:2021 */
static Notifier mouse_mode_notifier;   /* static: intrusive QLIST node, include/qemu/notify.h:21-25 */
static Notifier led_notifier;

/* keyboard: macOS kVK -> linux -> guest (must hold BQL) */
static void send_mac_key(uint16_t kvk, bool down, bool is_repeat)
{
    if (kvk >= qemu_input_map_osx_to_linux_len) return;          /* ui/cocoa.m:146 */
    unsigned lnx = qemu_input_map_osx_to_linux[kvk];              /* 0 == KEY_RESERVED, dropped by ui/input.c:361-363 */
    if (lnx == KEY_FN) return;                                    /* reaches no guest device in 11.1.1, §2.3 */
    if (is_repeat && down) return;                                /* optional: let the guest do typematic, §1.4 */
    if (qemu_console_is_graphic(dcl.con)) {
        qkbd_state_key_event(kbd, lnx, down);                     /* sends + syncs, ui/kbd-state.c:107-113 */
    } else if (QEMU_IS_TEXT_CONSOLE(dcl.con) && down) {
        qkbd_state_key_event(kbd, lnx, down);                     /* modifier tracking only */
        bool ctrl = qkbd_state_modifier_get(kbd, QKBD_MOD_CTRL);
        if (!qemu_text_console_put_linux(QEMU_TEXT_CONSOLE(dcl.con), lnx, ctrl)) {
            /* fall back to qemu_text_console_put_keysym() with the typed character, ui/sdl2-input.c:47-60 */
        }
    }
}

/* pointer: guest-pixel coords (y already top-left) or deltas (must hold BQL) */
static void send_pointer(int x, int y, int dx, int dy, int surface_w, int surface_h)
{
    if (qemu_input_is_absolute(dcl.con)) {
        if (x < 0 || y < 0 || x >= surface_w || y >= surface_h) return;   /* no clamping downstream, §1.6; ui/gtk.c:1025-1030 */
        qemu_input_queue_abs(dcl.con, INPUT_AXIS_X, x, 0, surface_w);   /* scaled to 0..0x7FFF */
        qemu_input_queue_abs(dcl.con, INPUT_AXIS_Y, y, 0, surface_h);
    } else {
        qemu_input_queue_rel(dcl.con, INPUT_AXIS_X, dx);
        qemu_input_queue_rel(dcl.con, INPUT_AXIS_Y, dy);
    }
    qemu_input_event_sync();
}

static void send_button(InputButton b, bool down)   /* LEFT/RIGHT/MIDDLE/SIDE/EXTRA all reach usb/virtio, §1.5 */
{
    qemu_input_queue_btn(dcl.con, b, down);
    qemu_input_event_sync();
}

static void send_wheel(bool up)   /* down+up pair, ui/cocoa.m:941-944; horizontal wheel is dropped by devices, §1.5 */
{
    InputButton b = up ? INPUT_BUTTON_WHEEL_UP : INPUT_BUTTON_WHEEL_DOWN;
    qemu_input_queue_btn(dcl.con, b, true);  qemu_input_event_sync();
    qemu_input_queue_btn(dcl.con, b, false); qemu_input_event_sync();
}

/* notifier callbacks: BQL-held QEMU thread (may be a vCPU thread), hop to the UI thread, ui/cocoa.m:1777-1782 */
static void on_mouse_mode(Notifier *n, void *data)
{
    dispatch_async(dispatch_get_main_queue(), ^{ /* re-read qemu_input_is_absolute(dcl.con) under BQL */ });
}
```
Init: `qemu_console_register_listener(qemu_console_lookup_default(), &dcl, &dcl_ops)`; `kbd = qkbd_state_init(dcl.con)`; `qemu_add_mouse_mode_change_notifier(&mouse_mode_notifier)`; then query `qemu_input_is_absolute(dcl.con)` once immediately (`ui/cocoa.m:2019-2023`). Wrap every call from a non-QEMU thread in `bql_lock()/bql_unlock()` (or the `with_bql` helper pattern, `ui/cocoa.m:113-142`); decide between `qemu_main = my_appkit_main` and `qemu_main = NULL` (§5); call `qkbd_state_lift_all_keys(kbd)` plus button releases on focus loss (`ui/cocoa.m:1297-1302, 1110-1124`). Cleanup: `qemu_console_unregister_listener(&dcl)`, `qkbd_state_free(kbd)`, `qemu_remove_mouse_mode_change_notifier(&mouse_mode_notifier)`, `qemu_input_led_notifier_remove(&led_notifier)` (`ui/cocoa.m:2045-2047`, `ui/dbus-console.c:155-157`).


## Open questions
- Whether `usb-kbd` / PS/2 coverage for Linux keycodes 232..464 (media keys, F13-F24 map fine, but e.g. KEY_FN does not) matters for the target guests: the notes now state which device families drop KEY_FN, but a full per-keycode coverage matrix of `qemu-build/ui/input-keymap-linux-to-qnum.c.inc` vs the osx table was not produced.
- The exact thread on which USB HID control/data packets (and thus `hid_pointer_activate` / `hid_keyboard_write` -> notifier callbacks) run depends on the host-controller device model (xhci/ehci/uhci) and whether it uses an iothread; the notes state 'a BQL-holding QEMU thread (main loop or vCPU)' which is correct in all cases but does not pin it to one thread.
- Original-note citations that were not flagged by review and not touched by the omissions (e.g. `ui/cocoa.m:729-765, 800-870, 1253-1262, 1583-1589`, `qapi/ui.json:944-976, 1056-1076, 1124-1142, 1431-1442`, `docs/multiseat.txt:40-42`, `subprojects/keycodemapdb/tools/keymap-gen:27,83,1037-1047,1126`) were carried over unchanged and not re-verified in this pass.
