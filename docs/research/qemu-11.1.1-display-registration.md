# QEMU 11.1.1 notes: display-registration
Source tree: build/qemu-src (tag v11.1.1). Every claim cites path:line. Produced by parallel research agents and checked by two skeptical reviewers; reviewer corrections could NOT be applied automatically (session limit) and are listed verbatim at the end — treat them as overriding the body where they conflict.

# Adding a new display backend ("alcove") to QEMU 11.1.1

All paths are relative to `/Users/giraffewithcode/dev/personal/alcove/build/qemu-src` unless prefixed `qemu-build/` (that is the sibling build dir `/Users/giraffewithcode/dev/personal/alcove/build/qemu-build`, used only to show *generated* code and the *actual* configuration of this build). Version confirmed: `VERSION` = `11.1.1`.

Important API naming note: in this tree the listener registration function is **`qemu_console_register_listener()`**, not `register_displaychangelistener()`. `grep -rn register_displaychangelistener` over `*.c *.h *.m` returns nothing — NOT FOUND. Use the names below.

---

## 1. `QemuDisplay`, registration and the init lifecycle

### 1.1 The struct and API (`include/ui/console.h`)

```c
/* include/ui/console.h:400-416 */
typedef struct QemuDisplay QemuDisplay;

struct QemuDisplay {
    DisplayType type;
    void (*early_init)(DisplayOptions *opts);
    void (*init)(DisplayState *ds, DisplayOptions *opts);
    void (*cleanup)(void);
    const char *vc;
};

void qemu_display_register(QemuDisplay *ui);
bool qemu_display_find_default(DisplayOptions *opts);
void qemu_display_early_init(DisplayOptions *opts);
void qemu_display_init(DisplayState *ds, DisplayOptions *opts);
const char *qemu_display_get_vc(DisplayOptions *opts);
void qemu_display_cleanup(void);
void qemu_display_help(void);
```

Field semantics, from the implementation in `ui/console.c`:

| Field | Required? | Where used |
|---|---|---|
| `type` | yes; must be `< DISPLAY_TYPE__MAX` (assert at `ui/console.c:1389`) | index into `static QemuDisplay *dpys[DISPLAY_TYPE__MAX]` (`ui/console.c:1385`) |
| `early_init` | optional (NULL-checked at `ui/console.c:1438`) | called from `qemu_display_early_init()` before any device/console exists |
| `init` | **required** — called unconditionally, no NULL check (`ui/console.c:1449`) | called from `qemu_display_init()` after the machine and its consoles exist |
| `cleanup` | optional (NULL-checked at `ui/console.c:1457`) | called from `qemu_display_cleanup()` for **every** registered backend, not only the selected one (`ui/console.c:1452-1465`) |
| `vc` | optional | overrides the default chardev spec for `-serial vc` etc.: default is `"vc:80Cx24C"` when `CONFIG_PIXMAN`, else NULL (`ui/console.c:1467-1479`); dbus sets `.vc = "vc"` (`ui/dbus.c:697`) |

### 1.2 Implementation (`ui/console.c:1385-1507`)

```c
/* ui/console.c:1385-1390 */
static QemuDisplay *dpys[DISPLAY_TYPE__MAX];

void qemu_display_register(QemuDisplay *ui)
{
    assert(ui->type < DISPLAY_TYPE__MAX);
    dpys[ui->type] = ui;
}
```

- `qemu_display_find_default()` (`ui/console.c:1392-1421`): priority list is `DISPLAY_TYPE_GTK` / `DISPLAY_TYPE_SDL` / `DISPLAY_TYPE_COCOA`, each under `#if defined(CONFIG_GTK|CONFIG_SDL|CONFIG_COCOA)` (`:1394-1404`). For each, if `dpys[prio[i]] == NULL` it tries `ui_module_load(DisplayType_str(prio[i]), ...)` (`:1411`). A new type is **not** auto-selected as default unless you add it to this array.
- `qemu_display_early_init()` (`ui/console.c:1423-1441`): returns immediately for `DISPLAY_TYPE_NONE`; if `dpys[type] == NULL` it tries `ui_module_load(DisplayType_str(type))` (`:1433`); if still NULL: `error_report("Display '%s' is not available.", ...)` and `exit(1)` (`:1436-1439`); then calls `early_init` if non-NULL.
- `qemu_display_init()` (`ui/console.c:1443-1450`): `assert(dpys[opts->type] != NULL); dpys[opts->type]->init(ds, opts);`.
- `qemu_display_help()` (`ui/console.c:1481-1507`): prints `"Available display backend types:"`, `none`, then each `DisplayType_str()` for which `dpys[idx]` is non-NULL (after attempting `ui_module_load`).

### 1.3 When each callback runs — call order in `system/vl.c`

1. `qemu_init()` (`system/vl.c:2854`) → `module_call_init(MODULE_INIT_OPTS)` (`:2896`) → `qemu_init_subsystems()` (`:2909`), which calls `module_call_init(MODULE_INIT_QOM)` (`system/runstate.c:986`). **This is where every `type_init()` function runs, i.e. where `qemu_display_register()` is called** for built-in backends.
2. Command-line parsing: `case QEMU_OPTION_display: parse_display(optarg);` (`system/vl.c:3011-3013`) fills the static `DisplayOptions dpy` (`system/vl.c:189`).
3. `qemu_setup_display()` (`system/vl.c:3792` → `:1377-1393`): resolves `DISPLAY_TYPE_DEFAULT` via `qemu_display_find_default()`, falls back to VNC `localhost:0,to=99,id=default` or `NONE`, then calls **`qemu_display_early_init(&dpy)`** (`:1392`). → **`early_init` runs here**, before default devices and before the machine is created.
4. `qemu_create_default_devices()` (`:3793`) calls `qemu_display_get_vc(&dpy)` (`:1398`) → `vc` field consulted.
5. `qemu_create_early_backends()` (`:3794` → `:2034-2062`): warns `"window-close is only valid for GTK and SDL"` unless type is GTK/SDL (`:2048-2051`), calls `qemu_console_early_init()` (`:2053`; registers the `TYPE_CHARDEV_VC` class, `ui/console-vc.c:352-358`), and exits if `gl=` was requested but `display_opengl == 0` (`:2055-2062`).
6. `qmp_x_exit_preconfig()` (`:3862` → `:2814-2825`): `qemu_init_board()` → devices create consoles via `qemu_graphic_console_create()` (`ui/console.c:1129-1160`).
7. `qemu_init_displays()` (`:3864` → `:2697-2716`): `ds = init_displaystate(); qemu_display_init(ds, &dpy);` (`:2702-2703`) → **`init` runs here**, with all consoles created and numbered (`init_displaystate()` hooks consoles into QOM, `ui/console.c:1102-1116`). Then VNC servers are started via `qemu_opts_foreach(qemu_find_opts("vnc"), vnc_init_func, ...)` (`:2710-2711`).
8. `cleanup` runs from `qemu_display_cleanup()` (`ui/console.c:1452`) at shutdown.

### 1.4 The `type_init` / module-init pattern

```c
/* include/qemu/module.h:57 */
#define type_init(function) module_init(function, MODULE_INIT_QOM)
```
`module_init` (`include/qemu/module.h:28-40`) expands to a `__attribute__((constructor))` function that calls `register_module_init()` (built-in) or `register_dso_module_init()` when `BUILD_DSO` is defined (`:21-32`).

Every backend uses exactly this shape:

```c
/* ui/cocoa.m:2055-2066 */
static QemuDisplay qemu_display_cocoa = {
    .type       = DISPLAY_TYPE_COCOA,
    .init       = cocoa_display_init,
    .cleanup    = cocoa_display_cleanup,
};

static void register_cocoa(void)
{
    qemu_display_register(&qemu_display_cocoa);
}

type_init(register_cocoa);
```

```c
/* ui/dbus.c:692-709 */
static QemuDisplay qemu_display_dbus = {
    .type       = DISPLAY_TYPE_DBUS,
    .early_init = early_dbus_init,
    .init       = dbus_init,
    .cleanup    = dbus_cleanup,
    .vc         = "vc",
};

static void register_dbus(void)
{
    qemu_dbus_display = (struct QemuDBusDisplayOps) {
        .add_client = dbus_display_add_client,
    };
    type_register_static(&dbus_display_info);
    qemu_display_register(&qemu_display_dbus);
}

type_init(register_dbus);

#ifdef CONFIG_OPENGL
module_dep("ui-opengl");
#endif
```

Other instances: `ui/egl-headless.c:271-284`, `ui/curses.c:819-829`, `ui/sdl2.c:1030-1036`, `ui/gtk.c:2910-2916`, `ui/spice-app.c:226-232`.

**VNC is not a `QemuDisplay`.** `grep qemu_display_register ui/vnc.c` → nothing. `system/vl.c:1122-1139` special-cases `-display vnc=...` with the comment `"vnc isn't a (local) DisplayType but a protocol for remote display access."` and calls `vnc_parse()`. VNC registers a `QemuOptsList` via `opts_init(vnc_register_config)` (`ui/vnc.c:4357-4361`) and is started from `vnc_init_func` (`ui/vnc.c:4335-4346`). Do not copy VNC's pattern for alcove.

`module_dep("ui-opengl")` / `module_obj()` are `modinfo()` annotations (`include/qemu/module.h:117-173`) that only expand when `QEMU_MODINFO` is defined by `scripts/modinfo-collect.py`; they matter only for the `.so` module build.

### 1.5 Module (`.so`) vs built-in

- Display sources are placed in one of two places in `ui/meson.build`:
  - **Built-in always**: `system_ss.add(when: cocoa, if_true: files('cocoa.m'))` (`ui/meson.build:73`). cocoa is *never* a module.
  - **Module-capable**: added to the `ui_modules` dictionary (`ui/meson.build:93`), e.g. `ui_modules += {'dbus' : dbus_ss}` (`:147`), `{'gtk' : gtk_ss}` (`:161`), `{'sdl' : sdl_ss}` (`:173`), `{'curses' : curses_ss}` (`:98`), `{'egl-headless' : egl_headless_ss}` (`:114`), `{'opengl' : opengl_ss}` (`:107`), spice (`:183,188`). Exported at the end: `modules += {'ui': ui_modules}` (`:200`).
- Top-level `meson.build:3902-3945` iterates `modules`: **if `enable_modules`**, each entry becomes `static_library(d + '-' + m, ...)` then `shared_module(sl.name(), name_prefix: '', ..., install: true, install_dir: qemu_moddir)` (`:3911-3923`) → file name `ui-<name>` + `CONFIG_HOST_DSOSUF`; **otherwise** `system_ss.add_all(module_ss)` (`:3941`) → linked into the executable.
- `enable_modules = get_option('modules').require(host_os != 'windows').require(not prefer_static).allowed()` (`meson.build:260-265`); `option('modules', type : 'feature', value : 'disabled', ...)` (`meson_options.txt:52-53`); `config_host_data.set('CONFIG_MODULES', enable_modules)` (`meson.build:2473`).
- Loading: `#define ui_module_load(lib, errp) module_load("ui-", lib, errp)` (`include/qemu/module.h:66`). `module_load()` (`util/module.c:202-315`) builds `module_name = prefix + name` (`:227`), searches `$QEMU_MODULE_DIR`, `get_relocated_path(CONFIG_QEMU_MODDIR)` (`:235-239`) for `"%s/%s%s"` with `CONFIG_HOST_DSOSUF` (`:280-281`), resolves `modinfo->deps` first (`:250-273`). The name passed is `DisplayType_str(type)`, so the module file must be `ui-<qapi-enum-name>.<dsosuf>` (e.g. `ui-alcove.dylib`).
- dbus keeps a tiny always-built-in stub `ui/dbus-module.c` (`ui/meson.build:65-67`; file `ui/dbus-module.c:24-35`: `int using_dbus_display;` and `struct QemuDBusDisplayOps qemu_dbus_display` with a stub `add_client` that errors "D-Bus display isn't enabled") so the core can reference symbols even when the real code is in the module.
- **This build**: `qemu-build/config-host.h:228` `#undef CONFIG_MODULES`, `:172` `#define CONFIG_HOST_DSOSUF ".dylib"`, `:78` `#define CONFIG_COCOA`, `:94` `#define CONFIG_DBUS_DISPLAY`, `:164` `#undef CONFIG_GTK`, `:320` `#undef CONFIG_SDL`, `:240` `#undef CONFIG_OPENGL`, `:246` `#define CONFIG_PIXMAN`, `:410` `#define CONFIG_VNC`, `:300` `CONFIG_QEMU_MODDIR "/Users/giraffewithcode/dev/personal/alcove/build/qemu-install/lib/qemu"`. So everything, including dbus, is built in here. `cocoa.m` is compiled with the `objc_COMPILER` rule into `libsystem.a.p/ui_cocoa.m.o` (`qemu-build/build.ninja:6549`).

Recommendation for alcove: follow the cocoa path (`system_ss.add(when: alcove, if_true: files('alcove.m'))`) — built-in, no modinfo/stub work, and `qemu_display_early_init` finds it without `ui_module_load`.

---

## 2. `qapi/ui.json` — `DisplayType`, `DisplayOptions`, per-backend structs

### 2.1 Existing declarations

```json
/* qapi/ui.json:1523-1534 */
{ 'enum'    : 'DisplayType',
  'data'    : [
    { 'name': 'default' },
    { 'name': 'none' },
    { 'name': 'gtk', 'if': 'CONFIG_GTK' },
    { 'name': 'sdl', 'if': 'CONFIG_SDL' },
    { 'name': 'egl-headless', 'if': 'CONFIG_OPENGL' },
    { 'name': 'curses', 'if': 'CONFIG_CURSES' },
    { 'name': 'cocoa', 'if': 'CONFIG_COCOA' },
    { 'name': 'spice-app', 'if': 'CONFIG_SPICE' },
    { 'name': 'dbus', 'if': 'CONFIG_DBUS_DISPLAY' }
  ]
}
```

```json
/* qapi/ui.json:1556-1572 */
{ 'union'   : 'DisplayOptions',
  'base'    : { 'type'           : 'DisplayType',
                '*full-screen'   : 'bool',
                '*window-close'  : 'bool',
                '*show-cursor'   : 'bool',
                '*gl'            : 'DisplayGLMode' },
  'discriminator' : 'type',
  'data'    : {
      'gtk': { 'type': 'DisplayGTK', 'if': 'CONFIG_GTK' },
      'cocoa': { 'type': 'DisplayCocoa', 'if': 'CONFIG_COCOA' },
      'curses': { 'type': 'DisplayCurses', 'if': 'CONFIG_CURSES' },
      'egl-headless': { 'type': 'DisplayEGLHeadless',
                        'if': 'CONFIG_OPENGL' },
      'dbus': { 'type': 'DisplayDBus', 'if': 'CONFIG_DBUS_DISPLAY' },
      'sdl': { 'type': 'DisplaySDL', 'if': 'CONFIG_SDL' }
  }
}
```

Per-backend structs (none of them carries its own `'if'`; the condition lives on the enum member and the union branch):

```json
/* qapi/ui.json:1349-1356 */
{ 'struct'  : 'DisplayGTK',
  'data'    : { '*clipboard'         : 'bool',
                '*grab-on-hover'     : 'bool',
                '*zoom-to-fit'       : 'bool',
                '*show-tabs'         : 'bool',
                '*show-menubar'      : 'bool',
                '*keep-aspect-ratio' : 'bool',
                '*scale'             : 'number'  } }

/* qapi/ui.json:1368-1369 */
{ 'struct'  : 'DisplayEGLHeadless',
  'data'    : { '*rendernode' : 'str' } }

/* qapi/ui.json:1388-1392 */
{ 'struct'  : 'DisplayDBus',
  'data'    : { '*rendernode' : 'str',
                '*addr': 'str',
                '*p2p': 'bool',
                '*audiodev': 'str' } }

/* qapi/ui.json:1453-1460 */
{ 'struct': 'DisplayCocoa',
  'data': {
      '*left-command-key': 'bool',
      '*full-grab': 'bool',
      '*swap-opt-cmd': 'bool',
      '*zoom-to-fit': 'bool',
      '*zoom-interpolation': 'bool'
  } }
```

Each is preceded by a `##`-doc block (`DisplayGTK` doc at `:1318-1348`, `DisplayCocoa` doc at `:1427-1452`, `DisplayType` doc at `:1486-1522`, `DisplayOptions` doc at `:1537-1555`). `qapi/pragma.json:4` sets `{ 'pragma': { 'doc-required': true } }`, so a definition without a doc comment is rejected by the generator; members are documented as `# @name: ...` lines and enum members are documented inside the enum's doc block (see `# @cocoa: The Cocoa user interface.` at `:1512`). `query-display-options` (`:1580-1581`) returns `DisplayOptions`, so the new branch is automatically exposed via QMP.

### 2.2 Generated C (from `qemu-build/qapi/qapi-types-ui.h`, produced by `scripts/qapi/types.py`)

```c
/* qemu-build/qapi/qapi-types-ui.h:525-550 */
typedef enum DisplayType {
    DISPLAY_TYPE_DEFAULT,
    DISPLAY_TYPE_NONE,
#if defined(CONFIG_GTK)
    DISPLAY_TYPE_GTK,
#endif /* defined(CONFIG_GTK) */
    ...
#if defined(CONFIG_COCOA)
    DISPLAY_TYPE_COCOA,
#endif /* defined(CONFIG_COCOA) */
    ...
    DISPLAY_TYPE__MAX,
} DisplayType;

/* qemu-build/qapi/qapi-types-ui.h:1144-1155 */
struct DisplayCocoa {
    bool has_left_command_key;
    bool left_command_key;
    ...
};

/* qemu-build/qapi/qapi-types-ui.h:1180-1209 */
struct DisplayOptions {
    DisplayType type;
    bool has_full_screen;
    bool full_screen;
    bool has_window_close;
    bool window_close;
    bool has_show_cursor;
    bool show_cursor;
    bool has_gl;
    DisplayGLMode gl;
    union { /* union tag is @type */
#if defined(CONFIG_GTK)
        DisplayGTK gtk;
#endif /* defined(CONFIG_GTK) */
#if defined(CONFIG_COCOA)
        DisplayCocoa cocoa;
#endif /* defined(CONFIG_COCOA) */
        ...
#if defined(CONFIG_OPENGL)
        DisplayEGLHeadless egl_headless;
#endif /* defined(CONFIG_OPENGL) */
        ...
    } u;
};
```

Generator rules that matter:
- `gen_variants()` (`scripts/qapi/types.py:227-248`) emits `union { ... } u;` with each branch wrapped in `var.ifcond.gen_if()/gen_endif()`; the C member name is `c_name(var.name)` (dashes → underscores, hence `egl_headless`).
- `gen_struct_members()` (`scripts/qapi/types.py:139-153`) emits `bool has_X;` only when `memb.need_has()`; `need_has_if_optional()` returns `not self.c_type().endswith(POINTER_SUFFIX)` (`scripts/qapi/schema.py:361-364`). **A `str` member is `char *` so it gets NO `has_` flag** — see `struct DisplayDBus { char *rendernode; char *addr; bool has_p2p; bool p2p; char *audiodev; }` (`qemu-build/qapi/qapi-types-ui.h:1126-1132`). Absent → `NULL`.
- `'if'` conditions become `#if defined(CONFIG_X)`; `CONFIG_X` must be defined in `config-host.h` (see §3).

### 2.3 Exact JSON to add for `alcove` with a string option `socket`

Insert a struct (e.g. after `DisplayCocoa`, before `# @HotKeyMod:` at `qapi/ui.json:1462`):

```json
##
# @DisplayAlcove:
#
# Alcove display options.
#
# @socket: Path of the UNIX socket the Alcove host application listens
#     on.  Defaults to no socket (display output is discarded).
#
# Since: 11.1
##
{ 'struct': 'DisplayAlcove',
  'data': { '*socket': 'str' } }
```

Add an enum member and its doc line to `DisplayType` (`qapi/ui.json:1486-1534`):

```json
# @alcove: The Alcove user interface.  (Since 11.1)
...
    { 'name': 'dbus', 'if': 'CONFIG_DBUS_DISPLAY' },
    { 'name': 'alcove', 'if': 'CONFIG_ALCOVE' }
```

Add a union branch to `DisplayOptions` (`qapi/ui.json:1563-1571`):

```json
      'sdl': { 'type': 'DisplaySDL', 'if': 'CONFIG_SDL' },
      'alcove': { 'type': 'DisplayAlcove', 'if': 'CONFIG_ALCOVE' }
```

Resulting generated C (by the rules above):

```c
#if defined(CONFIG_ALCOVE)
    DISPLAY_TYPE_ALCOVE,
#endif
...
struct DisplayAlcove {
    char *socket;          /* no has_socket: pointer type */
};
...
struct DisplayOptions {
    ...
    union { /* union tag is @type */
        ...
#if defined(CONFIG_ALCOVE)
        DisplayAlcove alcove;
#endif /* defined(CONFIG_ALCOVE) */
    } u;
};
```

Use in C: `opts->u.alcove.socket` (NULL when not given), guarded by the fact your file is only compiled when `CONFIG_ALCOVE` is set. `DisplayType_str(DISPLAY_TYPE_ALCOVE)` yields `"alcove"` (`qemu-build/qapi/qapi-types-ui.h:552-553`, macro defined by `scripts/qapi/types.py:111-112`). `qapi/meson.build:76` already lists `'ui'` as a QAPI module, so no meson change is needed for the schema.

Optional cosmetic: add a `#if defined(CONFIG_ALCOVE) "-display alcove[,socket=<path>]\n" #endif` line to the `-display` help text in `qemu-options.hx:2241-2270` (pattern at `:2260-2264` for cocoa).

---

## 3. Build system: `meson_options.txt`, `meson.build`, `ui/meson.build`

### 3.1 How cocoa and dbus are wired today

`meson_options.txt`:
```meson
option('cocoa', type : 'feature', value : 'auto',
       description: 'Cocoa user interface (macOS only)')      # meson_options.txt:157-158
option('dbus_display', type: 'feature', value: 'auto',
       description: '-display dbus support')                  # meson_options.txt:120-121
```

`meson.build`:
```meson
# meson.build:89-93 — Objective-C is enabled on darwin
if host_os == 'darwin' and \
   add_languages('objc', required: true, native: false)
  all_languages += ['objc']
  objc = meson.get_compiler('objc')
endif

# meson.build:1223-1225 — dependency object 'cocoa'
cocoa = dependency('appleframeworks',
                   modules: ['Cocoa', 'CoreVideo', 'QuartzCore'],
                   required: get_option('cocoa'))

# meson.build:2318-2323 — boolean 'dbus_display'
dbus_display = get_option('dbus_display') \
  .require(gio.version().version_compare('>=2.64'),
           error_message: '-display dbus requires glib>=2.64') \
  .require(gdbus_codegen.found(),
           error_message: gdbus_codegen_error.format('-display dbus')) \
  .allowed()

# meson.build:2437 / :2554 — CONFIG_ symbols for config-host.h (and thus QAPI 'if')
config_host_data.set('CONFIG_COCOA', cocoa.found())
config_host_data.set('CONFIG_DBUS_DISPLAY', dbus_display)

# meson.build:4900 / :4902 — configure summary
  summary_info += {'Cocoa support':           cocoa}
summary_info += {'D-Bus display':     dbus_display}
```
Objective-C warning flags: `meson.build:784-787`.

`ui/meson.build`:
```meson
# ui/meson.build:65-67  (stub always built in)
if dbus_display
  system_ss.add(files('dbus-module.c'))
endif
# ui/meson.build:73  (cocoa: built-in, dependency-gated)
system_ss.add(when: cocoa, if_true: files('cocoa.m'))
# ui/meson.build:117-148 (dbus: module-capable)
if dbus_display
  dbus_ss = ss.source_set()
  ...
  dbus_ss.add(when: gio,
              if_true: [files(
                'dbus-chardev.c', 'dbus-clipboard.c', 'dbus-console.c',
                'dbus-error.c', 'dbus-listener.c', 'dbus.c',
              ), opengl, gbm, pixman, dbus_display1])
  ui_modules += {'dbus' : dbus_ss}
endif
```
`system_ss.add(when: <dep>, if_true: ...)` is the meson `sourceset` idiom used throughout (`ui/meson.build:64, 73, 90, 97`); the `when:` dependency gates the sources and (per meson's sourceset module — not verifiable in-tree) is also attached as a link dependency.

The configure front-end: `scripts/meson-buildoptions.sh` is **generated** from `meson_options.txt` by `scripts/meson-buildoptions.py` (`Makefile:132-135`, target `update-buildoptions`, which `all` depends on; the file header says "This file is generated by meson-buildoptions.py, do not edit!" `scripts/meson-buildoptions.py:261`). `configure` sources it (`configure:571`). The cocoa entries there are `scripts/meson-buildoptions.sh:109` (help text) and `:279-280` (`--enable-cocoa) printf "%s" -Dcocoa=enabled`).

### 3.2 Minimal edits to add `ui/alcove.m` gated by a new option `alcove`

1. `meson_options.txt` (next to `cocoa`, `:157`):
```meson
option('alcove', type : 'feature', value : 'auto',
       description: 'Alcove display backend (macOS only)')
```

2. `meson.build` after the cocoa dependency (`:1225`):
```meson
alcove = dependency('appleframeworks',
                    modules: ['Cocoa', 'CoreVideo', 'QuartzCore'],
                    required: get_option('alcove'))
```
   (If alcove needs no Apple frameworks, use the boolean style of `dbus_display`: `alcove = get_option('alcove').require(host_os == 'darwin', error_message: 'alcove is macOS only').allowed()` and then `if alcove ... system_ss.add(files('alcove.m')) endif` in `ui/meson.build`.)

3. `meson.build` next to `CONFIG_COCOA` (`:2437`):
```meson
config_host_data.set('CONFIG_ALCOVE', alcove.found())
```
   This is what makes `'if': 'CONFIG_ALCOVE'` in `qapi/ui.json` resolve.

4. `meson.build` summary (near `:4900`): `summary_info += {'Alcove display': alcove}` (optional).

5. `ui/meson.build` after line 73:
```meson
system_ss.add(when: alcove, if_true: files('alcove.m'))
```
   Or module-capable, mirroring dbus (`:117-148`):
```meson
if alcove.found()
  alcove_ss = ss.source_set()
  alcove_ss.add(alcove, pixman, files('alcove.m'))
  ui_modules += {'alcove' : alcove_ss}
endif
```
   With `-Dmodules=enabled` this would build `ui-alcove.dylib` into `qemu_moddir` (`meson.build:3911-3923`, `qemu_moddir = get_option('libdir') / get_option('qemu_suffix')` at `:47`); with modules disabled it is linked in (`:3941`).

6. Run `make update-buildoptions` (or just `make`) so `scripts/meson-buildoptions.sh` gains `--enable-alcove/--disable-alcove` (`Makefile:132-135`). Then `configure --enable-alcove` or `meson configure -Dalcove=enabled`.

Because `.m` files are compiled by the `objc` compiler (`meson.build:89-93`), `ui/alcove.m` needs no extra language setup on darwin.

---

## 4. `ui/cocoa.m` as the reference implementation

### 4.1 `DisplayChangeListenerOps` — the contract (`include/ui/console.h:167-230`)

```c
typedef struct DisplayChangeListenerOps {
    const char *dpy_name;
    /* optional */ void (*dpy_refresh)(DisplayChangeListener *dcl);
    /* optional */ void (*dpy_gfx_update)(DisplayChangeListener *dcl, int x, int y, int w, int h);
    /* optional */ void (*dpy_gfx_switch)(DisplayChangeListener *dcl, struct DisplaySurface *new_surface);
    /* optional */ bool (*dpy_gfx_check_format)(DisplayChangeListener *dcl, pixman_format_code_t format);
    /* optional */ void (*dpy_text_cursor)(DisplayChangeListener *dcl, int x, int y);
    /* optional */ void (*dpy_text_resize)(DisplayChangeListener *dcl, int w, int h);
    /* optional */ void (*dpy_text_update)(DisplayChangeListener *dcl, int x, int y, int w, int h);
    /* optional */ void (*dpy_mouse_set)(DisplayChangeListener *dcl, int x, int y, bool on);
    /* optional */ void (*dpy_cursor_define)(DisplayChangeListener *dcl, QEMUCursor *cursor);
    /* required if GL */ void (*dpy_gl_scanout_disable)(DisplayChangeListener *dcl);
    /* required if GL */ void (*dpy_gl_scanout_texture)(DisplayChangeListener *dcl, uint32_t backing_id,
                                   bool backing_y_0_top, uint32_t backing_width, uint32_t backing_height,
                                   uint32_t x, uint32_t y, uint32_t w, uint32_t h, void *d3d_tex2d);
    /* optional */ bool (*dpy_has_dmabuf)(DisplayChangeListener *dcl);
    /* optional */ void (*dpy_gl_scanout_dmabuf)(DisplayChangeListener *dcl, QemuDmaBuf *dmabuf);
    /* optional */ void (*dpy_gl_cursor_dmabuf)(DisplayChangeListener *dcl, QemuDmaBuf *dmabuf, bool have_hot, uint32_t hot_x, uint32_t hot_y);
    /* optional */ void (*dpy_gl_cursor_position)(DisplayChangeListener *dcl, uint32_t pos_x, uint32_t pos_y);
    /* optional */ void (*dpy_gl_release_dmabuf)(DisplayChangeListener *dcl, QemuDmaBuf *dmabuf);
    /* required if GL */ void (*dpy_gl_update)(DisplayChangeListener *dcl, uint32_t x, uint32_t y, uint32_t w, uint32_t h);
} DisplayChangeListenerOps;

/* include/ui/console.h:232-239 */
struct DisplayChangeListener {
    uint64_t update_interval;
    const DisplayChangeListenerOps *ops;
    DisplayState *ds;
    QemuConsole *con;
    QLIST_ENTRY(DisplayChangeListener) next;
};
```

Cocoa's instance implements five of them (no GL, no text ops, no `dpy_gfx_check_format`):

```objc
/* ui/cocoa.m:89-98 */
static const DisplayChangeListenerOps dcl_ops = {
    .dpy_name          = "cocoa",
    .dpy_gfx_update = cocoa_update,
    .dpy_gfx_switch = cocoa_switch,
    .dpy_refresh = cocoa_refresh,
    .dpy_mouse_set = cocoa_mouse_set,
    .dpy_cursor_define = cocoa_cursor_define,
};
static DisplayChangeListener dcl;
static QKbdState *kbd;
```

The op implementations (`ui/cocoa.m:1899-1962`):

```objc
static void cocoa_update(DisplayChangeListener *dcl, int x, int y, int w, int h)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSRect rect = NSMakeRect(x, [cocoaView gscreen].height - y - h, w, h);
        [cocoaView setNeedsDisplayInRect:rect];
    });
}                                                              /* :1899-1908 */

static void cocoa_switch(DisplayChangeListener *dcl, DisplaySurface *surface)
{
    pixman_image_t *image = surface->image;
    // The DisplaySurface will be freed as soon as this callback returns.
    // We take a reference to the underlying pixman image here ...
    pixman_image_ref(image);
    dispatch_async(dispatch_get_main_queue(), ^{ [cocoaView switchSurface:image]; });
}                                                              /* :1910-1926 */

static void cocoa_refresh(DisplayChangeListener *dcl)
{
    ...
    qemu_console_hw_update(dcl->con);           /* ask the GPU model to render */
    ... /* clipboard polling */
}                                                              /* :1928-1947 */

static void cocoa_mouse_set(DisplayChangeListener *dcl, int x, int y, bool on)   /* :1949-1954 */
static void cocoa_cursor_define(DisplayChangeListener *dcl, QEMUCursor *cursor)  /* :1956-1962 */
{
    dispatch_async(dispatch_get_main_queue(), ^{
        BQL_LOCK_GUARD();
        [cocoaView setCursor:qemu_console_get_cursor(dcl->con)];
    });
}
```

Key facts for writing your own ops:
- All ops are invoked on QEMU's main-loop thread with the BQL held; cocoa hops to the AppKit main thread with `dispatch_async` and uses `with_bql()` (`ui/cocoa.m:116-126`) when calling back into QEMU.
- `dpy_gfx_switch` receives the new `DisplaySurface`; the previous surface is freed right after the fan-out (`qemu_console_set_surface`, `ui/console.c:763-799`: `dpy_gfx_destroy_texture(con, old_surface); qemu_free_displaysurface(old_surface);`). Read pixels with `surface_data()/surface_stride()/surface_width()/surface_height()/surface_format()` (`include/ui/surface.h:51-74`); `DisplaySurface` is `{ pixman_image_t *image; uint8_t flags; [uint32_t texture;] qemu_pixman_shareable share_handle; uint32_t share_handle_offset; }` (`include/ui/surface.h:17-25`).
- `dpy_gfx_update` fan-out: `qemu_console_update()` (`ui/console.c:730-753`) clamps the rect and calls only listeners whose `dcl->con == con`.
- If `dpy_gfx_check_format` is NULL, only the native 32-bpp format is accepted (`ui/console.c:801-823`: `format != qemu_default_pixman_format(32, true)` → false). VNC uses `qemu_pixman_check_format` (`ui/vnc.c:3417`; prototype `include/ui/qemu-pixman.h:88`).
- `dpy_refresh` presence is what creates the GUI timer: `gui_setup_refresh()` (`ui/console.c:125-144`) only allocates `ds->gui_timer` when some listener has `dpy_refresh`. `gui_update()` (`:99-123`) runs `dpy_refresh` for all listeners, then picks the minimum of each `dcl->update_interval` (default `GUI_REFRESH_INTERVAL_DEFAULT` = 30 ms, `include/ui/console.h:39`; idle 3000 ms `:40`). Change your interval with `qemu_console_listener_set_refresh(dcl, ms)` (`ui/console.c:654-663`; cocoa uses it at `:548-549` to match the display's refresh rate).
- Inside `dpy_refresh`, call `qemu_console_hw_update(dcl->con)` (`ui/console.c:153-160`) so the display device renders into its surface before you read it.

### 4.2 How the listener is registered and which console it uses

```objc
/* ui/cocoa.m:2019-2021 */
    qemu_console_register_listener(qemu_console_lookup_default(),
                                   &dcl, &dcl_ops);
    kbd = qkbd_state_init(dcl.con);
```

`qemu_console_register_listener()` (`ui/console.c:631-652`):
```c
void qemu_console_register_listener(QemuConsole *con,
                                    DisplayChangeListener *dcl,
                                    const DisplayChangeListenerOps *ops)
{
    assert(!dcl->ds);
    dcl->con = con;
    dcl->ops = ops;
    trace_displaychangelistener_register(dcl, dcl->ops->dpy_name);
    dcl->ds = get_alloc_displaystate();
    QLIST_INSERT_HEAD(&dcl->ds->listeners, dcl, next);
    gui_setup_refresh(dcl->ds);
    displaychangelistener_display_console(dcl, &error_fatal);
    if (QEMU_IS_GRAPHIC_CONSOLE(dcl->con)) {
        dcl_set_graphic_cursor(dcl, QEMU_GRAPHIC_CONSOLE(dcl->con));
    } else if (QEMU_IS_TEXT_CONSOLE(dcl->con)) {
        qemu_text_console_update_size(QEMU_TEXT_CONSOLE(dcl->con));
    }
    vt100_update_cursor();
}
```
`displaychangelistener_display_console()` (`ui/console.c:273-311`) immediately calls your `dpy_gfx_switch` with the console's current surface and then `dpy_gfx_update(0,0,w,h)` (`displaychangelistener_gfx_switch`, `:236-249`); if `con` is NULL or incompatible (`console_compatible_with`, `:568-596`: GL/DMABUF requirements), it substitutes a 640x480 placeholder surface with text "This VM has no graphic display device.". Cursor is pushed via `dcl_set_graphic_cursor` (`:610-618`). Unregister with `qemu_console_unregister_listener(dcl)` (`ui/console.c:665-676`; no-op if `dcl->ds == NULL`). Tracepoints: `ui/trace-events:16-17`.

Console lookup:
```c
/* ui/console.c:1189-1210 */
QemuConsole *qemu_console_lookup_default(void)   /* first QEMU_IS_GRAPHIC_CONSOLE, else first console */
QemuConsole *qemu_console_lookup_by_index(unsigned int index)  /* NULL past the end */
```
Also `qemu_console_lookup_by_device(dev, head)` (`:1213-1232`) and `qemu_console_lookup_by_device_name(id, head, errp)` (`:1235-1255`, used by VNC's `display=`/`head=` options at `ui/vnc.c:4253-4265`).

### 4.3 Multiple consoles in cocoa

- One static `dcl` attached to one console at a time. At init it enumerates consoles to build the View menu: `while (qemu_console_lookup_by_index(index) != NULL)` (`ui/cocoa.m:1707-1712`, menu tag = index).
- Switching: menu action `displayConsole:` (`:1376-1381`) → `with_bql(^{ [cocoaView selectConsoleLocked:[sender tag]]; })` → `selectConsoleLocked:` (`:293-305`):
```objc
    QemuConsole *con = qemu_console_lookup_by_index(index);
    if (!con) return;
    qemu_console_unregister_listener(&dcl);
    qkbd_state_switch_console(kbd, con);
    qemu_console_register_listener(con, &dcl, &dcl_ops);
    [self notifyMouseModeChange];
    [self updateUIInfo];
```
- Cocoa does **not** handle console hot-plug. Backends that do use one listener per console plus a notifier: egl-headless loops `for (idx = 0;; idx++) { con = qemu_console_lookup_by_index(idx); if (!con || !qemu_console_is_graphic(con)) break; ... qemu_console_register_listener(con, &edpy->dcl, &egl_ops); }` (`ui/egl-headless.c:218-243`); dbus loops the same way (`ui/dbus.c:298-306`) and then `dd->console_notifier.notify = dbus_console_notify; qemu_console_add_notifier(&dd->console_notifier);` (`:313-314`) handling `QEMU_CONSOLE_ADDED/REMOVED` (`:232-251`); gtk likewise (`ui/gtk.c:2473-2486`, `:2766-2767`, `:2560-2566`). Notifier API: `include/ui/console.h:420-434` (`QemuConsoleEvent { type; con; }`, `qemu_console_add_notifier`, `qemu_console_remove_notifier`); events emitted by `qemu_graphic_console_create` (`ui/console.c:1158`) and `qemu_graphic_console_close` (`:1173`).

### 4.4 How `cocoa_display_init` consumes `DisplayOptions`

```objc
/* ui/cocoa.m:1964-2037 (excerpt) */
static void cocoa_display_init(DisplayState *ds, DisplayOptions *opts)
{
    ...
    if (opts->has_full_screen && opts->full_screen) { [[cocoaView window] toggleFullScreen: nil]; }        /* :1982 */
    if (opts->u.cocoa.has_full_grab && opts->u.cocoa.full_grab) { [controller setFullGrab: nil]; }       /* :1985 */
    if (opts->has_show_cursor && opts->show_cursor) { cursor_hide = 0; }                                  /* :1989 */
    if (opts->u.cocoa.has_swap_opt_cmd) { swap_opt_cmd = opts->u.cocoa.swap_opt_cmd; }                    /* :1992 */
    if (opts->u.cocoa.has_left_command_key && !opts->u.cocoa.left_command_key) { left_command_key_enabled = 0; } /* :1996 */
    if (opts->u.cocoa.has_zoom_to_fit && opts->u.cocoa.zoom_to_fit) { ... }                               /* :2000 */
    if (opts->u.cocoa.has_zoom_interpolation && opts->u.cocoa.zoom_interpolation) { ... }                 /* :2004 */
    create_initial_menus();
    add_console_menu_entries();
    addRemovableDevicesMenuItems();
    qemu_console_register_listener(qemu_console_lookup_default(), &dcl, &dcl_ops);                        /* :2019 */
    kbd = qkbd_state_init(dcl.con);                                                                       /* :2021 */
    qemu_add_mouse_mode_change_notifier(&mouse_mode_change_notifier);                                     /* :2022 */
    ...
    qemu_main = cocoa_main;                                                                               /* :2036 */
}
```
Base-struct options (`full_screen`, `show_cursor`, `gl`, `window_close`) come with `has_` flags because they are `bool`/enum (`qemu-build/qapi/qapi-types-ui.h:1181-1189`). The `DisplayState *ds` argument is opaque (`struct DisplayState` is private to `ui/console.c:66-75`); cocoa ignores it.

Cleanup (`ui/cocoa.m:2039-2053`): `qemu_console_unregister_listener(&dcl); g_clear_pointer(&kbd, qkbd_state_free); qemu_remove_mouse_mode_change_notifier(...); qemu_clipboard_peer_unregister(...)`.

Main-thread handling: `extern int (*qemu_main)(void);` (`include/qemu-main.h:21`). On darwin it defaults to `os_darwin_cfrunloop_main` (`system/main.c:60-67`), and `main()` (`system/main.c:69-96`) spawns `qemu_default_main` on a detached thread and runs `qemu_main()` on the initial thread when it is non-NULL. cocoa replaces it with `cocoa_main` = `[NSApp run]` (`ui/cocoa.m:1887-1894`). A backend that needs no AppKit run loop can leave `qemu_main` alone (the CFRunLoop keeps running on the main thread) or set it to NULL to run QEMU's loop on the main thread.

Input helpers used by cocoa (for an input-capable backend): `qkbd_state_init/free/key_event/switch_console/lift_all_keys` (`include/ui/kbd-state.h:38-113`), `qemu_input_queue_btn/rel/abs`, `qemu_input_event_sync`, `qemu_input_is_absolute` (`include/ui/input.h:72-85`), `qemu_add_mouse_mode_change_notifier` (`:104`).

### 4.5 Minimal skeleton derived from the above (curses/cocoa shape)

```c
/* ui/alcove.m (built only when CONFIG_ALCOVE) */
#include "qemu/osdep.h"
#include "qemu/module.h"
#include "ui/console.h"
#include "ui/surface.h"

static DisplayChangeListener dcl;

static void alcove_gfx_update(DisplayChangeListener *dcl, int x, int y, int w, int h) { /* push rect from surface */ }
static void alcove_gfx_switch(DisplayChangeListener *dcl, DisplaySurface *new_surface) { /* new size/format; ref image if kept */ }
static void alcove_refresh(DisplayChangeListener *dcl) { qemu_console_hw_update(dcl->con); }

static const DisplayChangeListenerOps dcl_ops = {
    .dpy_name       = "alcove",
    .dpy_gfx_update = alcove_gfx_update,
    .dpy_gfx_switch = alcove_gfx_switch,
    .dpy_refresh    = alcove_refresh,
};

static void alcove_display_init(DisplayState *ds, DisplayOptions *opts)
{
    const char *socket = opts->u.alcove.socket;   /* NULL if not given */
    ...
    qemu_console_register_listener(qemu_console_lookup_default(), &dcl, &dcl_ops);
}

static void alcove_display_cleanup(void) { qemu_console_unregister_listener(&dcl); }

static QemuDisplay qemu_display_alcove = {
    .type    = DISPLAY_TYPE_ALCOVE,
    .init    = alcove_display_init,
    .cleanup = alcove_display_cleanup,
};

static void register_alcove(void) { qemu_display_register(&qemu_display_alcove); }
type_init(register_alcove);
```
(Compare `ui/curses.c:793-829` — the simplest in-tree backend: `dcl = g_new0(DisplayChangeListener, 1); qemu_console_register_listener(qemu_console_lookup_default(), dcl, &dcl_ops);`.)

---

## 5. How `-display type,opt=val` is parsed

- Option definition: `DEF("display", HAS_ARG, QEMU_OPTION_display, ...)` (`qemu-options.hx:2241`), with per-backend help lines under `#if defined(CONFIG_...)` (`:2242-2270`).
- `system/vl.c:3011-3013`:
```c
            case QEMU_OPTION_display:
                parse_display(optarg);
                break;
```
- `parse_display()` (`system/vl.c:1115-1142`):
```c
static void parse_display(const char *p)
{
    if (is_help_option(p)) {
        qemu_display_help();
        exit(0);
    }
#ifdef CONFIG_VNC
    const char *opts;
    if (strstart(p, "vnc", &opts)) {
        /* vnc isn't a (local) DisplayType but a protocol for remote display access. */
        if (*opts == '=') { vnc_parse(opts + 1); display_remote++; }
        else { error_report("VNC requires a display argument vnc=<display>"); exit(1); }
        return;
    }
#endif
    parse_display_qapi(p);
}
```
- `parse_display_qapi()` (`system/vl.c:1096-1108`):
```c
static void parse_display_qapi(const char *str)
{
    DisplayOptions *opts;
    Visitor *v;

    v = qobject_input_visitor_new_str(str, "type", &error_fatal);
    visit_type_DisplayOptions(v, NULL, &opts, &error_fatal);
    QAPI_CLONE_MEMBERS(DisplayOptions, &dpy, opts);
    qapi_free_DisplayOptions(opts);
    visit_free(v);
}
```
- `qobject_input_visitor_new_str()` (`qapi/qobject-input-visitor.c:749-776`): if the string starts with `{` it is parsed as JSON; otherwise `keyval_parse(str, implied_key /* "type" */, NULL, errp)` turns `alcove,socket=/tmp/a.sock` into `{"type":"alcove","socket":"/tmp/a.sock"}` (the first bare word is assigned to the implied key `type`), and a keyval input visitor is created. `visit_type_DisplayOptions` (generated from the union in §2) then validates `type` against `DisplayType` and dispatches the remaining keys to the `alcove` branch; unknown type or unknown key is fatal via `&error_fatal`.
- Result lands in the static `DisplayOptions dpy` (`system/vl.c:189`), which `qmp_query_display_options()` (`:1110-1113`) also returns. `-nographic` forces `dpy.type = DISPLAY_TYPE_NONE` (`:3014-3018`); `-full-screen` sets `dpy.has_full_screen/full_screen` (`:3379-3382`).
- `-display help` → `qemu_display_help()` (`ui/console.c:1481-1507`).

So for alcove: `-display alcove,socket=/tmp/alcove.sock` → `dpy.type == DISPLAY_TYPE_ALCOVE`, `dpy.u.alcove.socket == "/tmp/alcove.sock"`, and `qemu_display_early_init/qemu_display_init` dispatch to your `QemuDisplay` (§1.3).

---

## 6. `scripts/entitlement.sh` and the HVF entitlement on macOS

`meson.build`:
```meson
# meson.build:4253-4255
if host_os == 'darwin'
  entitlement = find_program('scripts/entitlement.sh')
endif

# meson.build:4444-4482 (per emulator executable)
  foreach exe: execs
    exe_name = exe['name']
    if host_os == 'darwin'
      exe_name += '-unsigned'
    endif

    emulator = executable(exe_name, exe['sources'], install: true, ...)

    if host_os == 'darwin'
      icon = 'pc-bios/qemu.rsrc'
      build_input = [emulator, files(icon)]
      install_input = [
        get_option('bindir') / exe_name,
        meson.current_source_dir() / icon
      ]
      if 'CONFIG_HVF' in config_target
        entitlements = 'accel/hvf/entitlements.plist'
        build_input += files(entitlements)
        install_input += meson.current_source_dir() / entitlements
      endif

      emulators += {exe['name'] : custom_target(exe['name'],
                   input: build_input,
                   output: exe['name'],
                   build_by_default: true,
                   command: [entitlement, '@OUTPUT@', '@INPUT@'])
      }

      meson.add_install_script(entitlement, '--install',
                               get_option('bindir') / exe['name'],
                               install_input)
    else
      emulators += {exe['name']: emulator}
    endif
```
So on darwin the linker produces `qemu-system-<arch>-unsigned`, and a custom target runs `scripts/entitlement.sh qemu-system-<arch> qemu-system-<arch>-unsigned pc-bios/qemu.rsrc accel/hvf/entitlements.plist` (the plist argument only when the target has `CONFIG_HVF`; in this build `qemu-build/aarch64-softmmu-config-target.h:8` has `#define CONFIG_HVF 1`). At install time the same script runs with `--install` inside `$MESON_INSTALL_DESTDIR_PREFIX`.

The script (`scripts/entitlement.sh:1-33`):
```sh
#!/bin/sh -e
in_place=:
if [ "$1" = --install ]; then
  shift
  in_place=false
fi

DST="$1"
SRC="$2"
ICON="$3"
ENTITLEMENT="$4"

if $in_place; then
  trap 'rm "$DST.tmp"' exit
  cp -pPf "$SRC" "$DST.tmp"
  SRC="$DST.tmp"
else
  cd "$MESON_INSTALL_DESTDIR_PREFIX"
fi

if test -n "$ENTITLEMENT"; then
  codesign --entitlements "$ENTITLEMENT" --force -s - "$SRC"
fi

# Add the QEMU icon to the binary on Mac OS
Rez -append "$ICON" -o "$SRC"
SetFile -a C "$SRC"

mv -f "$SRC" "$DST"
trap '' exit
```
Exact codesign command: **`codesign --entitlements accel/hvf/entitlements.plist --force -s - <binary>`** (`scripts/entitlement.sh:25`; ad-hoc identity `-`). `Rez`/`SetFile` (`:29-30`) come from Xcode command-line tools.

The plist (`accel/hvf/entitlements.plist:1-8`):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.hypervisor</key>
    <true/>
</dict>
</plist>
```
HVF detection: `hvf = dependency('appleframeworks', modules: 'Hypervisor', required: get_option('hvf'))` (`meson.build:903-907`), option `hvf` (`meson_options.txt:80-81`).

Practical consequence for alcove: if you ever ship `qemu-system-*` yourself (or re-link it), re-run that exact `codesign` line, otherwise HVF fails to start. If alcove is built as a `.dylib` module, the module is not signed by this script (only the executables go through `entitlement.sh`), which is fine for ad-hoc signing but is another reason to prefer the built-in path.

---

## Checklist to add "alcove"

1. `qapi/ui.json`: add `DisplayAlcove` struct (+doc), `{ 'name': 'alcove', 'if': 'CONFIG_ALCOVE' }` in `DisplayType`, `'alcove': { 'type': 'DisplayAlcove', 'if': 'CONFIG_ALCOVE' }` in `DisplayOptions` (§2.3).
2. `meson_options.txt`: `option('alcove', type: 'feature', value: 'auto', ...)`; `meson.build`: `alcove = dependency(...)`/boolean, `config_host_data.set('CONFIG_ALCOVE', ...)`, summary line (§3.2).
3. `ui/meson.build`: `system_ss.add(when: alcove, if_true: files('alcove.m'))` (§3.2).
4. `ui/alcove.m`: `DisplayChangeListenerOps`, `QemuDisplay { .type = DISPLAY_TYPE_ALCOVE, .init, .cleanup }`, `type_init(register_alcove)` (§1.4, §4.5).
5. Optional: `-display` help line in `qemu-options.hx:2241-2270`; add to `qemu_display_find_default()` priority list (`ui/console.c:1394-1404`) if it should be the default.
6. `make update-buildoptions` / reconfigure; verify with `qemu-system-aarch64 -display help` (`ui/console.c:1481-1507`) and `-display alcove,socket=/tmp/x.sock`.


## Open questions
- Meson sourceset semantics for `system_ss.add(when: <dependency>, if_true: ...)` (that the dependency is also attached as a link dependency) come from meson's sourceset module, which is not in the QEMU tree; the in-tree usage at ui/meson.build:64,73,90,97 is consistent with that, but it was not verified against meson's own source.
- The QAPI parser's exact behaviour for *member*-level documentation (whether an undocumented struct member is a hard error vs. only definition-level docs being enforced by qapi/pragma.json:4 'doc-required': true) was not traced through scripts/qapi/parser.py; the safe course is to document every member as the existing DisplayCocoa block does (qapi/ui.json:1427-1460).
- Whether alcove should be added to the default-display priority list in qemu_display_find_default() (ui/console.c:1392-1421) is a product decision; without it `-display default` never picks alcove.

## Reviewer corrections (unapplied)
- **Claim:** §1.1/§1.2 line citations in ui/console.c for the QemuDisplay API: early_init NULL check at :1438; init called at :1449 (function :1443-1450); cleanup NULL check at :1457 (function :1452-1465); vc default at :1467-1479; qemu_display_help at :1481-1507; qemu_display_find_default at :1392-1421 with prio[] at :1394-1404; qemu_display_early_init at :1423-1441 with error_report/exit at :1436-1439
  - **Problem:** Every cited line in this block is 1-9 lines too early; the quoted code exists but not at the cited lines.
  - **Correction:** ui/console.c: qemu_display_find_default :1393-1423 (prio[] :1395-1405, ui_module_load :1411); qemu_display_early_init :1425-1446 (ui_module_load :1433, error_report+exit :1439-1441, early_init NULL check :1443-1445); qemu_display_init :1448-1456 (DISPLAY_TYPE_NONE early return :1451-1453, assert :1454, ->init call :1455); qemu_display_cleanup :1458-1471 (NULL check :1463, call :1464); qemu_display_get_vc :1475-1487 ("vc:80Cx24C" :1478); qemu_display_help :1490-1516.
- **Claim:** qemu_console_listener_set_refresh at ui/console.c:654-663; qemu_console_unregister_listener at ui/console.c:665-676
  - **Problem:** Off by a few lines (a doc comment sits between the two functions).
  - **Correction:** qemu_console_listener_set_refresh is ui/console.c:653-662; qemu_console_unregister_listener is ui/console.c:673-682 (trace at :676, `if (!ds) return;` at :677-679).
- **Claim:** qemu_graphic_console_create() at ui/console.c:1129-1160 emitting QEMU_CONSOLE_ADDED at :1158; qemu_graphic_console_close emitting QEMU_CONSOLE_REMOVED at :1173
  - **Problem:** Line numbers drifted.
  - **Correction:** qemu_graphic_console_create is ui/console.c:1127-1161 with qemu_console_notify(QEMU_CONSOLE_ADDED, s) at :1159; qemu_graphic_console_close is :1167-1187 with qemu_console_notify(QEMU_CONSOLE_REMOVED, con) at :1176.
- **Claim:** ui/dbus.c:692-709 for `static QemuDisplay qemu_display_dbus` … type_init(register_dbus), and `.vc = "vc"` at ui/dbus.c:697
  - **Problem:** Cited range is shifted; :697 is `static void register_dbus(void)`, not the .vc field.
  - **Correction:** ui/dbus.c: `static QemuDisplay qemu_display_dbus = {` :689-695, `.vc = "vc"` :694, `static void register_dbus(void)` :697-704, `type_init(register_dbus);` :706, `#ifdef CONFIG_OPENGL module_dep("ui-opengl")` :708-710.
- **Claim:** Other QemuDisplay instances: ui/egl-headless.c:271-284, ui/curses.c:819-829, ui/sdl2.c:1030-1036, ui/gtk.c:2910-2916, ui/spice-app.c:226-232
  - **Problem:** Ranges start after the struct definitions and partly miss the QemuDisplay struct they are meant to cite.
  - **Correction:** ui/egl-headless.c: struct :270-275, register_egl :277-280, type_init :282, module_dep("ui-opengl") :284. ui/curses.c: struct :818-822, register_curses :824-827, type_init :829. ui/sdl2.c: struct :1021-1026, register_sdl1 :1028-1031, type_init :1033. ui/gtk.c: struct :2900-2906 (.vc = "vc" :2905), register_gtk :2908-2911, type_init :2913. ui/spice-app.c: struct :216-222 (.vc = "vc" :221), register_spice_app :224-227, type_init :229.
- **Claim:** `enable_modules = get_option('modules').require(host_os != 'windows').require(not prefer_static).allowed()` (meson.build:260-265)
  - **Problem:** Misquoted: there is no bare `prefer_static` variable in that expression.
  - **Correction:** meson.build:260-265 reads: `enable_modules = get_option('modules') \ .require(host_os != 'windows', error_message: 'Modules are not available for Windows') \ .require(not get_option('prefer_static'), error_message: 'Modules are incompatible with static linking') \ .allowed()`.
- **Claim:** `qemu_input_queue_btn/rel/abs`, `qemu_input_event_sync`, `qemu_input_is_absolute` (include/ui/input.h:72-85)
  - **Problem:** `qemu_input_event_sync` is not declared in that range.
  - **Correction:** include/ui/input.h: qemu_input_event_sync :59, qemu_input_queue_btn :72, qemu_input_is_absolute :76, qemu_input_queue_rel :80, qemu_input_queue_abs :81-82, qemu_add_mouse_mode_change_notifier :104.
- **Claim:** `displaychangelistener_display_console()` (ui/console.c:273-311) immediately calls your dpy_gfx_switch with the console's current surface and then dpy_gfx_update(0,0,w,h)
  - **Problem:** The follow-up dpy_gfx_update is conditional: for a real console it is only issued when `con->scanout.kind == SCANOUT_SURFACE`; for a texture/dmabuf scanout the GL ops are called instead. Unconditional update happens only for the 640x480 placeholder path.
  - **Correction:** ui/console.c:294-295: `displaychangelistener_gfx_switch(dcl, con->surface, con->scanout.kind == SCANOUT_SURFACE);` followed by :297-311 dispatching to dpy_gl_scanout_dmabuf / dpy_gl_scanout_texture when the scanout is DMABUF/TEXTURE. Placeholder path :283-290 passes TRUE.
- **Claim:** `hvf = dependency('appleframeworks', modules: 'Hypervisor', required: get_option('hvf'))` (meson.build:903-907)
  - **Problem:** Slightly inaccurate quote/lines; the dependency call is nested in a guard and what it drives is a per-target accelerator symbol.
  - **Correction:** meson.build:903 `hvf = not_found`, :904 `if get_option('hvf').allowed()`, :905-906 the dependency() call, :907-909 `if hvf.found() accelerators += 'CONFIG_HVF' endif`. CONFIG_HVF lands in <target>-config-target.h (qemu-build/aarch64-softmmu-config-target.h:8), which is why meson.build:4466 tests `'CONFIG_HVF' in config_target`.
- **Claim:** DisplayType enum at qapi/ui.json:1523-1534; new DisplayAlcove struct goes before `# @HotKeyMod:` at qapi/ui.json:1462
  - **Problem:** Off by one.
  - **Correction:** `{ 'enum'    : 'DisplayType',` is qapi/ui.json:1522 (block :1522-1534); `# @HotKeyMod:` is qapi/ui.json:1463 (the `##` opening the doc block is :1462).
- **Missing:** After a device installs a real surface, the listener receives ONLY dpy_gfx_switch and no follow-up dpy_gfx_update: qemu_console_set_surface() calls `displaychangelistener_gfx_switch(dcl, new_surface, surface ? FALSE : TRUE)` (ui/console.c:791-796), i.e. the full-rect update after switch is issued only for the NULL/placeholder case. An alcove dpy_gfx_switch must therefore treat the switch itself as a full invalidation (the device driver will send its own dpy_gfx_update rects later).
- **Missing:** Where `cleanup` is actually invoked: qemu_display_cleanup() is called from qemu_cleanup() in system/runstate.c:1048 (after qemu_chr_cleanup() :1047, before user_creatable_cleanup() :1049); qemu_cleanup itself is system/runstate.c:1006.
- **Missing:** §3.2 step 3 (`config_host_data.set('CONFIG_ALCOVE', alcove.found())`) only works for the dependency-object variant. For the boolean `.allowed()` variant suggested as an alternative, a meson bool has no `.found()`; mirror dbus instead: `config_host_data.set('CONFIG_ALCOVE', alcove)` (pattern meson.build:2554) and gate sources with `if alcove` (pattern ui/meson.build:65-67 and :118).
- **Missing:** The QAPI generator validates `'if'` strings: scripts/qapi/expr.py:266-267 requires `re.fullmatch(r'[A-Z][A-Z0-9_]*', cond)` (error "must be a string or an object" at :277). `CONFIG_ALCOVE` conforms; lowercase or dashed names would be rejected.
- **Missing:** What the `vc` field feeds: qemu_create_default_devices() (system/vl.c:1395-1450) uses the returned string as the default chardev for serial/parallel/monitor — `add_device_config(DEV_SERIAL, vc ?: "null")` :1433, `add_device_config(DEV_PARALLEL, vc ?: "null")` :1436, `if (default_monitor && vc) monitor_parse(vc, "readline", false)` :1438-1439. gtk (ui/gtk.c:2905) and spice-app (ui/spice-app.c:221) also set `.vc = "vc"`, not only dbus. If alcove has no text-console rendering, leave `.vc` unset so the pixman default "vc:80Cx24C" (ui/console.c:1478) applies, or set it to "null"-like handling explicitly.
- **Missing:** dpy_has_dmabuf is documented in the header as `/* optional (default to true if has dpy_gl_scanout_dmabuf) */` (include/ui/console.h:210), consistent with displaychangelistener_has_dmabuf() (ui/console.c:556-566) — relevant if alcove ever exposes dmabuf.
- **Missing:** qemu_display_init() also short-circuits for DISPLAY_TYPE_NONE (ui/console.c:1451-1453) and asserts `opts->type < DISPLAY_TYPE__MAX` (:1450); qemu_display_help() iterates from DISPLAY_TYPE_NONE (ui/console.c:1496), so a registered `alcove` backend appears in `-display help` output automatically.
