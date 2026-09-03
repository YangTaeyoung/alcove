# QEMU 11.1.1 notes: build-and-patching
Source tree: build/qemu-src (tag v11.1.1). Every claim cites path:line. Produced by parallel research agents and checked by two skeptical reviewers; reviewer corrections could NOT be applied automatically (session limit) and are listed verbatim at the end — treat them as overriding the body where they conflict.

# QEMU 11.1.1 build-system facts for an out-of-tree macOS patch series (Alcove)

Source tree: `/Users/giraffewithcode/dev/personal/alcove/build/qemu-src`, `VERSION:1` = `11.1.1`. All paths below are relative to that root; every claim is cited `path:line`. "NOT FOUND" means I looked and the thing is not in this tree.

---

## 1. Feature option → `CONFIG_*` define + meson dependency + summary (the `cocoa` pattern)

### 1.1 The four pieces (docs recipe)

`docs/devel/build-system.rst:349-360` lists the canonical steps for a new dependency: (1) add a Meson option to `meson_options.txt`, (2) perform the feature check, (3) put the status in `config-host.h` via `config_host_data.set`, (4) print it in the configure summary. The worked example there is `sdl_image` (`docs/devel/build-system.rst:363-389`), and it ends with: "For the configure script to parse the new option, the ``scripts/meson-buildoptions.sh`` file must be up-to-date; ``make update-buildoptions`` (or just ``make``) will take care of updating it." (`docs/devel/build-system.rst:391-393`).

### 1.2 Exact cocoa pattern in this tree

**Option** (`meson_options.txt:157-158`):
```meson
option('cocoa', type : 'feature', value : 'auto',
       description: 'Cocoa user interface (macOS only)')
```

**Dependency probe** (`meson.build:1223-1225`) — an Apple framework dependency; `required: get_option('cocoa')` makes `auto` silently fall back to not-found and `enabled` error out:
```meson
cocoa = dependency('appleframeworks',
                   modules: ['Cocoa', 'CoreVideo', 'QuartzCore'],
                   required: get_option('cocoa'))
```

**CONFIG define** (`meson.build:2437`):
```meson
config_host_data.set('CONFIG_COCOA', cocoa.found())
```

**Summary line** (`meson.build:4897-4900`, in the "User interface" section that is closed at `meson.build:4921`):
```meson
# UI
summary_info = {}
if host_os == 'darwin'
  summary_info += {'Cocoa support':           cocoa}
endif
```

**Source hookup** (`ui/meson.build:73`):
```meson
system_ss.add(when: cocoa, if_true: files('cocoa.m'))
```

**QAPI hookup** (`qapi/ui.json:1529` and `:1565`):
```json
    { 'name': 'cocoa', 'if': 'CONFIG_COCOA' },
...
      'cocoa': { 'type': 'DisplayCocoa', 'if': 'CONFIG_COCOA' },
```

Objective-C is enabled as a project language only on darwin: `meson.build:89-93` (`add_languages('objc', required: true, native: false)`), and ObjC warning/common flags are applied at `meson.build:784-787`. So `.m` files added to a sourceset compile without further setup.

### 1.3 The alternative "boolean feature" pattern (`dbus_display`)

When the feature is not a library but a gate combining other deps, QEMU converts the feature option to a plain bool with `.require(...).allowed()` (`meson.build:2318-2323`):
```meson
dbus_display = get_option('dbus_display') \
  .require(gio.version().version_compare('>=2.64'),
           error_message: '-display dbus requires glib>=2.64') \
  .require(gdbus_codegen.found(),
           error_message: gdbus_codegen_error.format('-display dbus')) \
  .allowed()
```
and then `config_host_data.set('CONFIG_DBUS_DISPLAY', dbus_display)` (`meson.build:2554`), `summary_info += {'D-Bus display': dbus_display}` (`meson.build:4902`), and `if dbus_display` guards in `ui/meson.build:65-67,118`.

Other UI `CONFIG_*` lines to mirror: `CONFIG_GTK` `meson.build:2459`, `CONFIG_SDL` `:2486`, `CONFIG_OPENGL` `:2480`, `CONFIG_CURSES` `:2456`, `CONFIG_PIXMAN` `:2492`, `CONFIG_VNC` `:2517`, `CONFIG_VNC_JPEG` `:2518`, `CONFIG_VNC_SASL` `:2519`, `CONFIG_PNG` `:2516`, `CONFIG_SPICE` `:2552`, `CONFIG_SPICE_PROTOCOL` `:2546`, `CONFIG_GIO` `:2458`, `CONFIG_VTE` `:2460`, `CONFIG_X11` `:2553`.

### 1.4 Template for an `alcove` option (derived from the above)

```meson
# meson_options.txt (place near 'cocoa', meson_options.txt:157)
option('alcove', type : 'feature', value : 'auto',
       description: 'Alcove display backend (macOS only)')

# meson.build, next to cocoa (meson.build:1223)
alcove = not_found
if host_os == 'darwin'
  alcove = dependency('appleframeworks',
                      modules: ['Cocoa', 'CoreVideo', 'QuartzCore'],   # whatever Alcove links
                      required: get_option('alcove'))
elif get_option('alcove').enabled()
  error('alcove requires macOS')
endif

# meson.build, next to CONFIG_COCOA (meson.build:2437)
config_host_data.set('CONFIG_ALCOVE', alcove.found())

# meson.build, in the UI summary block (meson.build:4899-4901)
if host_os == 'darwin'
  summary_info += {'Cocoa support':           cocoa}
  summary_info += {'Alcove support':          alcove}
endif

# ui/meson.build, next to line 73
system_ss.add(when: alcove, if_true: files('alcove.m'))
```
Note on `dependency('appleframeworks', ...)`: on non-darwin hosts Meson's appleframeworks dependency is not found; `required: get_option('alcove')` with `auto` then yields not-found without an error, which is exactly how `cocoa` behaves on Linux (`meson.build:1223-1225` has no `host_os` guard).

---

## 2. `configure` ↔ meson options; regenerating `scripts/meson-buildoptions.sh`

### 2.1 How `--enable-X/--disable-X` reach meson

- `configure` sources the generated shell fragment: `. "$source_path/scripts/meson-buildoptions.sh"` (`configure:571`).
- Anything of the form `--*` not explicitly handled by configure falls through to `meson_option_parse "$opt" "$optarg"` (`configure:749-751`), comment: "everything else has the same name in configure and meson". `-D*` is passed through verbatim with `meson_option_add "$opt"` (`configure:752-753`).
- `meson_option_parse` (`configure:580-586`):
```sh
meson_option_parse() {
  meson_options="$meson_options $(_meson_option_parse "$@")"
  if test $? -eq 1; then
    echo "ERROR: unknown option $1"
    echo "Try '$0 --help' for more information"
    exit 1
  fi
}
```
- The generated `_meson_option_parse` (`scripts/meson-buildoptions.sh:235`) is a `case` whose cocoa entries are:
```sh
    --enable-cocoa) printf "%s" -Dcocoa=enabled ;;
    --disable-cocoa) printf "%s" -Dcocoa=disabled ;;
```
(`scripts/meson-buildoptions.sh:279-280`), ending with `*) return 1 ;;` (`scripts/meson-buildoptions.sh:591`). The help text for cocoa is at `scripts/meson-buildoptions.sh:109`.
- The accumulated `$meson_options` are `eval`'d into `meson setup` (`configure:1954-1957`); configure also appends `-Dauto_features=disabled` when `--without-default-features` was given (`configure:244,1935`; help text `configure:864`).

### 2.2 The generator

`scripts/meson-buildoptions.sh:1`: `# This file is generated by meson-buildoptions.py, do not edit!`

`scripts/meson-buildoptions.py` reads `meson introspect --buildoptions` JSON on stdin (`:253-255`), keeps user-section options plus a whitelist of builtins (`:152-158`, `BUILTIN_OPTIONS` `:65-81`), maps `_`→`-` for the CLI name (`cli_option`, `:166-170`, with overrides in `OPTION_NAMES` `:37-48`), and emits the `case` arms (`print_parse`, `:226-249`). A `feature` option arrives from introspection as type `combo` with choices `auto/enabled/disabled`, so it takes the `combo` arms at `:241-244` producing `--enable-X → -DX=enabled` and `--disable-X → -DX=disabled`; booleans produce `-DX=true/false` (`:237-239`).

### 2.3 Regenerating (Makefile rule)

`Makefile:131-135`:
```make
.PHONY: update-buildoptions
all update-buildoptions: $(SRC_PATH)/scripts/meson-buildoptions.sh
$(SRC_PATH)/scripts/meson-buildoptions.sh: $(SRC_PATH)/meson_options.txt $(SRC_PATH)/scripts/meson-buildoptions.py
	$(MESON) introspect --buildoptions $(SRC_PATH)/meson.build | $(PYTHON) \
	  scripts/meson-buildoptions.py > $@.tmp && mv $@.tmp $@
```
Facts:
- The rule sits inside `ifneq ($(MESON),)` (`Makefile:110` … `endif` at `:136`), so it only exists in a configured build directory. `MESON` is written to `config-host.mak` by configure (`configure:1749`), pointing at `pyvenv/bin/meson` created by `python/scripts/mkvenv.py` (`configure:940-970`).
- `all` depends on the `.sh`, and the `.sh` depends on `meson_options.txt` — so a plain `make` regenerates it whenever `meson_options.txt` is newer (`Makefile:132-133`); `make update-buildoptions` does it explicitly.
- `config-host.mak` depends on `scripts/meson-buildoptions.sh` (`Makefile:81-82`), so after regeneration `make` re-runs `./config.status` (`Makefile:83-88`).
- Manual equivalent: `<build>/pyvenv/bin/meson introspect --buildoptions meson.build | python3 scripts/meson-buildoptions.py > scripts/meson-buildoptions.sh` (same command as `Makefile:134-135`). Note it introspects `meson.build` from source, so it works before a full configure as long as meson is available.
- A CI/test that fails when `meson-buildoptions.sh` is stale: NOT FOUND (`grep` over `.gitlab-ci.d/`, `scripts/`, `tests/` for `meson-buildoptions` hit only the generator and its output).

### 2.4 Does configure reject `--enable-alcove` if the `.sh` is stale? Yes.

`--enable-alcove` goes to `configure:750` → `meson_option_parse` → `_meson_option_parse` hits `*) return 1` (`scripts/meson-buildoptions.sh:591`) → `ERROR: unknown option --enable-alcove` and `exit 1` (`configure:583-585`). Escape hatch: `../configure ... -Dalcove=enabled` is passed straight to meson (`configure:752-753`), and meson validates it against `meson_options.txt` itself. Your patch series must therefore carry the regenerated `scripts/meson-buildoptions.sh` hunk (two `case` arms + one help line) alongside the `meson_options.txt` hunk.

---

## 3. `ui/meson.build` — how every backend's sources are added

Full file (`ui/meson.build:1-200`), annotated:

```meson
# ui/meson.build:1-18 — keymap pairs turned into input-keymap-*.c.inc
keymaps = [ ['atset1', 'linux'], ['linux', 'qcode'], ... ['osx', 'linux'] ]

# ui/meson.build:20-33 — generated with keycodemapdb subproject; outputs appended to genh
if have_system or xkbcommon.found()
  keycodemapdb_proj = subproject('keycodemapdb', required: true)
  foreach e : keymaps
    output = 'input-keymap-@0@-to-@1@.c.inc'.format(e[0], e[1])
    genh += custom_target(output, output: output, capture: true,
                  input: keycodemapdb_proj.get_variable('keymaps_csv'),
                  command: [python, keycodemapdb_proj.get_variable('keymap_gen').full_path(),
                            'code-map', '--lang', 'glib2',
                            '--varname', 'qemu_input_map_@0@_to_@1@'.format(e[0], e[1]),
                            '@INPUT0@', e[0], e[1]])
  endforeach
endif

# ui/meson.build:35-54 — core UI library (also used by tools)
libui_sources = files('clipboard.c','console.c','cursor.c','dmabuf.c','display-surface.c',
    'input-keymap.c','kbd-state.c','keymaps.c','qemu-pixman.c','spice-module.c','vgafont.c')
if pixman.found()
  libui_sources += files('cp437.c', 'vt100.c')
endif
libui = static_library('qemuui', libui_sources + genh,
  dependencies: [pixman, spice_headers], build_by_default: false)
ui = declare_dependency(objects: libui.extract_all_objects(recursive: false), dependencies: [pixman])

# ui/meson.build:55-73 — system-emulator-only sources
system_ss.add(png)
system_ss.add(files('input-barrier.c','input.c','ui-hmp-cmds.c','ui-qmp-cmds.c','util.c'))
system_ss.add(ui)
system_ss.add(when: pixman, if_true: files('console-vc.c'), if_false: files('console-vc-stubs.c'))
if dbus_display
  system_ss.add(files('dbus-module.c'))
endif
system_ss.add(when: spice_protocol, if_true: files('vdagent.c'))
if host_os == 'linux'
  system_ss.add(files('input-linux.c', 'udmabuf.c'))
endif
system_ss.add(when: cocoa, if_true: files('cocoa.m'))          # <-- Cocoa: line 73

# ui/meson.build:75-91 — VNC (always linked in, not a module)
vnc_ss = ss.source_set()
vnc_ss.add(files('vnc.c','vnc-enc-zlib.c','vnc-enc-hextile.c','vnc-enc-tight.c','vnc-palette.c',
  'vnc-enc-zrle.c','vnc-auth-vencrypt.c','vnc-ws.c','vnc-jobs.c','vnc-clipboard.c'))
vnc_ss.add(zlib, jpeg, png)
vnc_ss.add(when: sasl, if_true: files('vnc-auth-sasl.c'))
system_ss.add_all(when: [vnc, pixman], if_true: vnc_ss)
system_ss.add(when: vnc, if_true: files('vnc-system.c'), if_false: files('vnc-stubs.c'))

# ui/meson.build:93-99 — modules dictionary; curses
ui_modules = {}
if curses.found()
  curses_ss = ss.source_set()
  curses_ss.add(when: [curses, iconv], if_true: [files('curses.c'), pixman])
  ui_modules += {'curses' : curses_ss}
endif

# ui/meson.build:101-115 — OpenGL + egl-headless
system_ss.add(opengl)
if opengl.found()
  opengl_ss = ss.source_set()
  opengl_ss.add(gbm, pixman)
  opengl_ss.add(when: [opengl], if_true: files('shader.c','console-gl.c','egl-helpers.c','egl-context.c'))
  ui_modules += {'opengl' : opengl_ss}
endif
if opengl.found()
  egl_headless_ss = ss.source_set()
  egl_headless_ss.add(when: [opengl, pixman], if_true: [files('egl-headless.c'), gbm])
  ui_modules += {'egl-headless' : egl_headless_ss}
endif

# ui/meson.build:117-148 — D-Bus display (bool guard, gdbus-codegen step)
dbus_display1 = files()
if dbus_display
  dbus_ss = ss.source_set()
  env = environment()
  env.set('HOST_OS', host_os)
  xml = custom_target('dbus-display preprocess', input: 'dbus-display1.xml',
                      output: 'dbus-display1.xml', env: env, command: [xml_pp, '@INPUT@', '@OUTPUT@'])
  dbus_display1 = custom_target('dbus-display gdbus-codegen',
                                output: ['dbus-display1.h', 'dbus-display1.c'], input: xml,
                                command: [gdbus_codegen, '@INPUT@', '--glib-min-required', '2.64',
                                          '--output-directory', meson.current_build_dir(),
                                          '--interface-prefix', 'org.qemu.', '--c-namespace', 'QemuDBus',
                                          '--generate-c-code', '@BASENAME@'])
  dbus_display1_h = declare_dependency(dependencies: [gio], sources: dbus_display1[0])
  dbus_ss.add(when: gio,
              if_true: [files('dbus-chardev.c','dbus-clipboard.c','dbus-console.c','dbus-error.c',
                              'dbus-listener.c','dbus.c'), opengl, gbm, pixman, dbus_display1])
  ui_modules += {'dbus' : dbus_ss}
endif

# ui/meson.build:150-162 — GTK
if gtk.found()
  if host_os == 'windows'
    system_ss.add(files('win32-kbd-hook.c'))
  endif
  gtk_ss = ss.source_set()
  gtk_ss.add(gtk, vte, pixman, files('gtk.c'))
  gtk_ss.add(files('gtk-clipboard.c'))
  gtk_ss.add(when: x11, if_true: files('x_keymap.c'))
  gtk_ss.add(when: opengl, if_true: files('gtk-gl-area.c'))
  gtk_ss.add(when: [x11, opengl], if_true: files('gtk-egl.c'))
  ui_modules += {'gtk' : gtk_ss}
endif

# ui/meson.build:164-174 — SDL
if sdl.found()
  sdl_ss = ss.source_set()
  sdl_ss.add(sdl, sdl_image, pixman, glib, files('sdl2-2d.c','sdl2-input.c','sdl2.c'))
  sdl_ss.add(when: opengl, if_true: files('sdl2-gl.c'))
  sdl_ss.add(when: x11, if_true: files('x_keymap.c'))
  ui_modules += {'sdl' : sdl_ss}
endif

# ui/meson.build:176-190 — SPICE
if spice.found()
  spice_core_ss = ss.source_set()
  spice_core_ss.add(spice, pixman, files('spice-core.c','spice-input.c','spice-display.c'))
  ui_modules += {'spice-core' : spice_core_ss}
  if gio.found()
    spice_ss = ss.source_set()
    spice_ss.add(spice, gio, pixman, files('spice-app.c'))
    ui_modules += {'spice-app': spice_ss}
  endif
endif

# ui/meson.build:192-200
subdir('shader')
if have_system
  subdir('icons')
  install_data('qemu.desktop', install_dir: qemu_desktopdir)
endif
modules += {'ui': ui_modules}
```

How the two styles differ:
- **Direct `system_ss.add(when: <dep>, if_true: files(...))`** (cocoa `ui/meson.build:73`, vnc `:90-91`): sourceset `when:` accepts dependency objects or config symbols; the files (and the dep's link flags) are included only if the dependency is found. Sourceset semantics are described in `docs/devel/build-system.rst:220-256`.
- **`ui_modules += {'name': ss}`** (gtk/sdl/spice/dbus/curses/opengl) → `modules += {'ui': ui_modules}` (`ui/meson.build:200`) → top-level loop `meson.build:3902-3943`: if `enable_modules`, each becomes `shared_module(..., install: true, install_dir: qemu_moddir)` (`meson.build:3918-3923`); otherwise `system_ss.add_all(module_ss)` (`meson.build:3941`) — i.e. linked into the binary exactly like the direct style. `enable_modules` is `get_option('modules')` (default `'disabled'`, `meson_options.txt:52-53`) with `.require(host_os != 'windows')` and `.require(not prefer_static)` (`meson.build:260-265`). So on macOS, unless you pass `--enable-modules`, both styles produce the same statically linked result. For a bundle, keep modules disabled (no `lib/qemu/ui-*.dylib` to relocate).
- For an `alcove.m` backend, mirroring cocoa (`system_ss.add(when: alcove, if_true: files('alcove.m'))`) is the least invasive. If you want a `-display alcove` that shares GL helper code, note that `opengl` sources (`shader.c`, `console-gl.c`) live in the `opengl` module (`ui/meson.build:102-108`), which links in only if `opengl` (epoxy) is found.

---

## 4. QAPI codegen after editing `qapi/ui.json`

### 4.1 What gets generated and how ninja tracks it

- `qapi/meson.build:74-78`: the `ui` module is part of `qapi_all_modules` when `have_system or have_tools`.
- Per module (`qapi/meson.build:95-114`) the outputs are `qapi-types-ui.c/.h`, `qapi-visit-ui.c/.h`, and (system/tools) `qapi-events-ui.c/.h`, `qapi-commands-ui.c/.h`, `qapi-commands-ui.trace-events`. Non-module outputs (`qapi/meson.build:80-93`) include `qapi-introspect.c/.h`, `qapi-types.h`, `qapi-visit.h`, `qapi-commands.h`, `qapi-events.h`, `qapi-emit-events.*`, and `qapi-builtin-types/visit.*`.
- All of them come out of one `custom_target` (`qapi/meson.build:116-120`):
```meson
qapi_files = custom_target('shared QAPI source files',
  output: qapi_outputs,
  input: [ files('qapi-schema.json') ],
  command: [ qapi_gen, '-o', 'qapi', '-b', '@INPUT0@' ],
  depend_files: [ qapi_inputs, qapi_gen_depends ])
```
`qapi_inputs` is every module `.json` (`qapi/meson.build:96-97`), and `qapi_gen_depends` is the full list of `scripts/qapi/*.py` plus `scripts/qapi-gen.py` (`meson.build:3494-3510`; `qapi_gen = find_program('scripts/qapi-gen.py')` at `meson.build:3493`). Because `qapi/ui.json` is in `depend_files`, **ninja regenerates all QAPI outputs automatically** after you edit it — no manual step. The `.h` outputs are added to `genh` (`qapi/meson.build:123-126`) so everything that includes them rebuilds; the `.c` files go into `util_ss` (`:130`). `subdir('qapi')` is at `meson.build:3735`.

### 4.2 The definitions you will touch

`DisplayType` enum (`qapi/ui.json:1522-1533`) — every backend is a conditional longhand member:
```json
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
Its doc comment (`qapi/ui.json:1486-1520`) documents each value with `@name:`; later additions carry `(Since X.Y)` inline, e.g. `@dbus: Start a D-Bus service for the display.  (Since 7.0)` (`:1517`), and the definition-level `Since: 2.12` (`:1519`).

`DisplayOptions` union (`qapi/ui.json:1556-1571`): base has `'type': 'DisplayType'`, `discriminator: 'type'`, and each branch repeats the same `if` as the enum member:
```json
  'data'    : {
      'gtk': { 'type': 'DisplayGTK', 'if': 'CONFIG_GTK' },
      'cocoa': { 'type': 'DisplayCocoa', 'if': 'CONFIG_COCOA' },
      'curses': { 'type': 'DisplayCurses', 'if': 'CONFIG_CURSES' },
      'egl-headless': { 'type': 'DisplayEGLHeadless', 'if': 'CONFIG_OPENGL' },
      'dbus': { 'type': 'DisplayDBus', 'if': 'CONFIG_DBUS_DISPLAY' },
      'sdl': { 'type': 'DisplaySDL', 'if': 'CONFIG_SDL' }
  }
```
Branch structs to copy: `DisplayCocoa` (`qapi/ui.json:1425-1460`, definition `Since: 7.0` at `:1451`, members added later annotated `(Since 8.2)` / `(Since 9.0)` at `:1445,1448`), `DisplayDBus` (`:1371-1392`, `Since: 7.0`). `query-display-options` returns `DisplayOptions` (`:1580-1582`).

### 4.3 Schema rules (from `docs/devel/qapi-code-gen.rst`)

- Enum syntax incl. longhand `{ 'name', '*if', '*features' }`: `:198-212`; names must be distinct `:214-216`; C constants `PREFIX_NAME`, `PREFIX__MAX` `:229-237`.
- Union syntax: `:325-338`; "Member 'discriminator' must name a non-optional enum-typed member of the base struct" `:343-345`; "The BRANCH's STRING name … must be a value of the discriminator enum type" `:349-350`; branch type "must a struct type" `:352-354`; "The branches need not cover all possible enum values" `:374-375`.
- Conditions: COND grammar `:786-796`; per-member `if` requires longhand `:815-835`; "A union's discriminator may not be conditional" `:823` (enforced in `scripts/qapi/schema.py:780-783`); "you are responsible to ensure that the C code will compile with an arbitrary combination of conditions, since the generator is unable to check it" `:847-849`; conditions also gate introspection `:851-853`.
- Features: `:682-700`; special `deprecated`/`unstable` `:717-727`.
- **Do enum-member and union-branch `if`s have to match?** A generator check that a branch's `if` equals its enum value's `if` was NOT FOUND in `scripts/qapi/schema.py` (branch validation at `:755-795` checks name membership, non-optional and non-conditional discriminator, and fills uncovered values with `q_empty`, `:785-791`). It is nevertheless a practical requirement per `:847-849`: a branch guarded weaker than its enum value would emit code referencing a non-existent enum constant in some configurations. Every branch in `ui.json` mirrors its enum value's condition (`:1522-1571`).
- Naming: enum values / member names are lower-case with `-`; `scripts/qapi/schema.py:134` raises `"name of %s must not use uppercase or '_'"`. So the value is `alcove`, and the C constant becomes `DISPLAY_TYPE_ALCOVE`.

### 4.4 Doc-comment rules (enforced because `qapi/pragma.json:4` sets `'doc-required': true`)

- "Definition documentation, if present, must immediately precede the definition it documents." `:981-982`; with `doc-required` "every definition must have documentation" `:984-985`.
- Structure: description naming the definition, then a `@name:` description for each member/value/branch, then `Features:`, then tagged sections `:987-992`; `@name:` continuation lines indented 4 `:994-997`.
- "Extensions added after the definition was first released carry a '(since x.y.z)' comment." `:1003-1004` — this is the rule for a **new enum member**: add `@alcove: ... (Since 11.1)`-style text inside the existing `DisplayType` doc (as `@dbus` does at `:1517`), not a new `Since:` section. New **definitions** (`DisplayAlcove` struct) get a `Since: x.y` tagged section `:1037-1038`.
- Tagged sections: `Since:`, `Returns:`, `Errors:`, `TODO:` `:1014-1016`; case-sensitive, need a trailing colon, and are only recognised after a blank line `:1160-1174` (regex in `scripts/qapi/parser.py:592-595`; duplicate `Since` is an error `scripts/qapi/parser.py:786-790`).
- Member descriptions require a colon `:1176-1184`; blank line required between list items and paragraphs `:1141-1149`; indentation matters `:1151-1158`; wrap at 70 columns, two spaces between sentences `:973-975`; `` `Foo` `` cross-references a definition, `@foo` references a member `:928-938`.
- Rendering check: "When you change documentation comments, please check the generated documentation comes out as intended!" `:1190-1191` (docs build is `option('docs', feature, auto)` `meson_options.txt:46-47`).

---

## 5. Install layout and runtime data-dir discovery

### 5.1 Directory variables and baked-in paths

`meson.build:44-50`:
```meson
qemu_confdir = get_option('sysconfdir') / get_option('qemu_suffix')
qemu_datadir = get_option('datadir') / get_option('qemu_suffix')
qemu_moddir = get_option('libdir') / get_option('qemu_suffix')
qemu_desktopdir = get_option('datadir') / 'applications'
qemu_icondir = get_option('datadir') / 'icons'
```
with `qemu_suffix` default `'qemu'` (`meson_options.txt:5-6`) and `qemu_firmwarepath` default `['share/qemu-firmware']` (`meson_options.txt:9-10`). Compiled-in absolute paths (`meson.build:2380-2397`): `CONFIG_BINDIR`, `CONFIG_PREFIX`, `CONFIG_QEMU_CONFDIR`, `CONFIG_QEMU_DATADIR` (= prefix/share/qemu), `CONFIG_QEMU_FIRMWAREPATH` (comma-separated quoted list, `:2386-2390`), `CONFIG_QEMU_HELPERDIR`, `CONFIG_QEMU_ICONDIR`, `CONFIG_QEMU_LOCALEDIR`, `CONFIG_QEMU_MODDIR`. `CONFIG_RELOCATABLE` from `option('relocatable', boolean, true)` (`meson.build:2484`, `meson_options.txt:116-117`). The configure summary prints these under "Directories" (`meson.build:4658-4676`).

### 5.2 What `ninja install` puts under `$prefix`

| Installed path | Rule |
|---|---|
| `bin/qemu-system-aarch64` | `meson.build:4413-4418` names it `'qemu-system-' + target_name`; on darwin the `executable()` is built and installed as `qemu-system-aarch64-unsigned` (`:4445-4457`, `install: true`), then `meson.add_install_script(entitlement, '--install', bindir/qemu-system-aarch64, [bindir/qemu-system-aarch64-unsigned, pc-bios/qemu.rsrc, accel/hvf/entitlements.plist])` (`:4459-4477`) runs `scripts/entitlement.sh`, which `cd`s to `$MESON_INSTALL_DESTDIR_PREFIX` (`:21`), ad-hoc codesigns with the entitlements (`codesign --entitlements "$ENTITLEMENT" --force -s - "$SRC"`, `:24-26`), appends the icon with `Rez`/`SetFile` (`:29-30`) and `mv -f`s the unsigned file onto the final name (`:32`). The entitlement is `com.apple.security.hypervisor` (`accel/hvf/entitlements.plist:5-6`), added only when `CONFIG_HVF` is in the target config (`meson.build:4466-4470`). **Re-signing for a bundle must preserve this entitlement.** |
| `bin/qemu-img`, `bin/qemu-io`, `bin/qemu-nbd` | `meson.build:4515-4526` (`install: true`), only `if have_tools` (`:4515`; `option('tools', feature, auto)` `meson_options.txt:64-65`). `qemu-storage-daemon` via `subdir('storage-daemon')` `:4528`; `qemu-edid` `:4539-4541`. |
| `bin/qemu-keymap` | `meson.build:4511-4512`, `install: have_tools`, requires xkbcommon. |
| `share/qemu/edk2-aarch64-code.fd` (+ arm/x86/riscv/loongarch variants) | `pc-bios/meson.build:2-28`: each `.fd.bz2` is decompressed with `bzip2 -dc` at build time (`:19-26`), `install: get_option('install_blobs')`, `install_dir: qemu_datadir`. Only when a target in `edk2_targets` (includes `aarch64-softmmu`) is built and `bzip2` is found (`meson.build:170-178`). `option('install_blobs', boolean, true)` `meson_options.txt:56-57`. |
| `share/qemu/<blobs>` (bios.bin, vgabios-*.bin, efi-*.rom, pxe-*.rom, openbios-*, slof.bin, opensbi-*, `edk2-licenses.txt`, …) | `pc-bios/meson.build:30-90`, `install_data(blobs, install_dir: qemu_datadir, install_mode: 'rw-r--r--')`. |
| `share/qemu/firmware/60-edk2-aarch64.json` etc. | `pc-bios/descriptors/meson.build:1-18`: `configure_file(... configuration: {'DATADIR': get_option('prefix') / qemu_datadir}, install_dir: qemu_datadir / 'firmware')` — **the descriptor JSON gets the absolute prefix baked in** (`:14`); it is not relocated at runtime (no qemu-system code reads these; grep for consumers in `system/ util/ hw/ include/` returned nothing — they are for external tools per `docs/interop/firmware.json`). |
| `share/qemu/keymaps/*` | `pc-bios/keymaps/meson.build:43-60`: generated with `qemu-keymap` when xkbcommon is available (`install: have_system`, `install_dir: qemu_datadir / 'keymaps'`, `:46-51`), else `install_data(keymaps.keys(), ...)` (`:55`); `sl`, `sv` always (`:58-60`). |
| `share/qemu/dtb/*.dtb` | `pc-bios/dtb/meson.build:10-25`. |
| `share/icons/hicolor/<size>/apps/qemu.png`, `qemu.bmp`, `qemu.svg` | `ui/icons/meson.build:1-13`. |
| `share/applications/qemu.desktop` | `ui/meson.build:197`. |
| `lib/qemu/*.so` modules | only if `--enable-modules` (`meson.build:3918-3923`, `qemu_moddir`). |

QEMU sets no `install_rpath`/`build_rpath` anywhere: NOT FOUND in `meson.build`.

### 5.3 How the binary finds `share/qemu` at runtime

1. `qemu_init_exec_dir(argv[0])` is called early in `qemu_init` (`system/vl.c:2899`). On macOS it uses `_NSGetExecutablePath` + `realpath` (`util/cutils.c:1096-1105`; header `<mach-o/dyld.h>` at `:42-44`), falling back to `realpath(argv0)` (`:1121-1124`) and finally `CONFIG_BINDIR` (`:1126-1130`). Signature: `void qemu_init_exec_dir(const char *argv0)` (`util/cutils.c:1033`).
2. `char *get_relocated_path(const char *dir)` (`util/cutils.c:1134-1200`) does, in order:
   - if `<exec_dir>/qemu-bundle` exists, return `<exec_dir>/qemu-bundle/<dir>` (absolute `dir` appended verbatim on POSIX) (`:1144-1168`). `build/qemu-bundle` is a symlink farm created at configure time by `scripts/symlink-install-tree.py` (hooked at `meson.build:18`; `bundle_dest = destdir_join('qemu-bundle', dest)` `scripts/symlink-install-tree.py:21`), which is how the build-tree binary finds data files.
   - else if `CONFIG_RELOCATABLE` and both `dir` and `CONFIG_BINDIR` start with `CONFIG_PREFIX` (`starts_with_prefix`, `:999-1013`), compute `exec_dir` + one `/..` per remaining bindir component + the remaining `dir` components (`:1171-1194`).
   - else return `dir` unchanged (`:1197`).
   Relocatability is disabled with a warning if `bindir` is not inside `prefix` (`meson.build:5056-5071`).
3. `qemu_add_default_firmwarepath()` (`util/datadir.c:89-105`) adds `get_relocated_path()` of each `CONFIG_QEMU_FIRMWAREPATH` entry and then of `CONFIG_QEMU_DATADIR`; it is called from `qemu_process_early_options` (`system/vl.c:2634`). `-L <dir>` prepends via `qemu_add_data_dir` (`system/vl.c:3164-3170`; `util/datadir.c:70-87`, max 16 dirs `:30`). `qemu_find_file(QemuFileType type, const char *name)` (`util/datadir.c:33-68`; header `include/qemu/datadir.h:4-31`) tries `name` as a path first, then `<dir>/` (BIOS), `<dir>/dtb/`, `<dir>/keymaps/`. `-L help` lists the dirs (`vl.c:3165-3166`, `qemu_list_data_dirs` `util/datadir.c:107-113`). The default config file is also relocated: `get_relocated_path(CONFIG_QEMU_CONFDIR "/qemu.conf")` (`system/vl.c:2337`).

**Bundling consequence.** With default `--bindir=bin --datadir=share`, a binary at `Foo.app/Contents/MacOS/qemu-system-aarch64` will look for `Foo.app/Contents/MacOS/../share/qemu` = `Foo.app/Contents/share/qemu`. If you prefer `Contents/Resources`, configure with `--bindir=MacOS --datadir=Resources` (both relative, both inside prefix, `meson.build:5058-5059`); then `CONFIG_QEMU_DATADIR = <prefix>/Resources/qemu` relocates to `<exec_dir>/../Resources/qemu`. Alternatively drop a `qemu-bundle/` directory next to the binary mirroring the absolute prefix tree (`util/cutils.c:1144-1168`). Note `CONFIG_QEMU_FIRMWAREPATH` default (`share/qemu-firmware`) is also relocated and searched first (`util/datadir.c:98-101`).

---

## 6. Runtime dynamic-library dependencies on macOS

### 6.1 Unconditional link dependencies
- **glib-2.0** ≥ 2.66 (`meson.build:1058-1060`, `required: true`); **gmodule-2.0** only if modules or plugins are enabled (`:1062-1068`), otherwise `not_found`. glib is added as a project-wide dependency (`:1112-1113`).
- **zlib** (`meson.build:1160`, `required: true`).
- Apple frameworks (system, nothing to bundle): CoreFoundation, IOKit (`:854-855`), Cocoa/CoreVideo/QuartzCore for cocoa (`:1223-1225`), Hypervisor for hvf (`:905-906`), CoreAudio (`:1767-1768`), vmnet (`:1227`), ParavirtualizedGraphics/Metal for pvg (`:857-858`; only used for `CONFIG_MAC_PVG` targets that support HVF, `:3394-3398`; sources `hw/display/meson.build:65-66`).

### 6.2 Optional dependencies (each has a `feature` option, default `auto`)

| Library (Homebrew formula) | Option (`meson_options.txt`) | Probe (`meson.build`) | Define | Notes |
|---|---|---|---|---|
| pixman (`pixman`) | `pixman` `:241` | `:1154-1158` (`have_system or have_tools`) | `CONFIG_PIXMAN` `:2492` | GTK/VNC/SPICE `.require(pixman.found())` (`:1922-1924, 1955-1957, 1362-1364`). `cocoa.m` is not pixman-guarded in `ui/meson.build:73`; whether it compiles without pixman: NOT VERIFIED. Treat as required. |
| libslirp (`libslirp`) | `slirp` `:243` | `:1281-1282` | `CONFIG_SLIRP` `:2494` | needed for `-netdev user`. |
| libfdt (`dtc`) | `fdt` combo `disabled/enabled/auto/system/internal` `:322-324` | `:2042-2068` | `CONFIG_FDT` `:2439` | `aarch64-softmmu` sets `TARGET_NEED_FDT=y` (`configs/targets/aarch64-softmmu.mak:6`) → build error if missing (`meson.build:3334-3341, 3444-3446`). `--enable-fdt=internal` builds the `dtc` subproject **static** (`default_library=static`, `:2062-2067`) → no dylib to bundle. |
| gnutls (`gnutls` → also libtasn1, nettle, hogweed, gmp, p11-kit, libidn2, libunistring) | `gnutls` `:181` | `:1797-1799` (≥3.7.5) | `CONFIG_GNUTLS` `:2530` | TLS for VNC/NBD/migration. If disabled, crypto falls back to `hash-glib.c`/`pbkdf-stub.c` (`crypto/meson.build:43-44`) and `random-platform.c` (`:73`). |
| nettle / libgcrypt | `nettle` `:183`, `gcrypt` `:185` | `:1831-1849` | `CONFIG_NETTLE` `:2535`, `CONFIG_GCRYPT` `:2534` | only probed if gnutls-crypto is not used (`:1829`). |
| libusb (`libusb`) | `libusb` `:197` | `:2105-2106` | `CONFIG_USB_LIBUSB` `:2503` | USB passthrough. |
| libssh (`libssh`) | `libssh` `:193` | `:1699-1701` | `CONFIG_LIBSSH` `:2469` | block driver only (`have_block`). |
| zstd (`zstd`) | `zstd` `:267` | `:1387-1389` | `CONFIG_ZSTD` `:2540` | migration/qcow2 compression. |
| capstone (`capstone`) | `capstone` `:320` | `:1891-1893` | `CONFIG_CAPSTONE` `:2436` | disassembler for `-d in_asm`/monitor. |
| lzo (`lzo`), snappy (`snappy`) | `:205`, `:225` | `:2009-2012`, `:1993-1996` | `CONFIG_LZO` `:2445`, `CONFIG_SNAPPY` `:2495` | dump compression. |
| libjpeg (`jpeg-turbo`), libpng (`libpng`), sasl2 (system) | `vnc_jpeg` `:259`, `png` `:255`, `vnc_sasl` `:261` | `:1959-1962`, `:1945-1948` | `CONFIG_VNC_JPEG` `:2518`, `CONFIG_PNG` `:2516`, `CONFIG_VNC_SASL` `:2519` | VNC extras; `vnc` itself is a dummy dependency (`:1958`). |
| curl, bzip2, lzfse, libnfs, libiscsi, rbd | `:159,149,203,169,167,209` | `:1437-1442, 1704-1712, 1184-1187, 1379-1382, 1647` | `CONFIG_CURL` `:2455` … | block drivers (`have_block`). |
| gtk+3/vte, sdl2/sdl2_image, spice-server/spice-protocol, gio (dbus display), epoxy (opengl), ncurses, xkbcommon, libcbor, brlapi, usbredir, libcacard, virglrenderer | `:215,263,217,219,227,229,161,120,211,177,265,179,147,235,223,251` | `:1920-1938, 1621-1638, 1353-1367, 1115-1140, 1771-1779, 1510, 1272-1277, 1787-1790, 1602, 1417-1421` | see §1.3 | all off if not found or disabled. |

The complete Homebrew set QEMU's own macOS CI installs is `PKGS=` in `.gitlab-ci.d/macos-14.vars:14` (`bzip2 capstone … dtc … glib gnutls gtk+3 gtk-vnc jemalloc jpeg-turbo json-c libcbor libepoxy libffi libgcrypt libiscsi libnfs libpng libslirp libssh libtasn1 libusb … lzo … ncurses nettle … pixman … sdl2 sdl2_image snappy … spice-protocol … usbredir vde vte3 … zlib zstd`), used by `.gitlab-ci.d/macos.yml:24` with `--target-list=aarch64-softmmu,...` (`:43`).

### 6.3 Deriving a bundle-friendly configure line

`--without-default-features` sets `-Dauto_features=disabled` (`configure:244, 1935`; help `configure:864`), turning every `auto` feature off so you opt in explicitly. `tcg` defaults to `enabled` (`meson_options.txt:90`) and `fdt` is a combo (unaffected). A minimal line derived from the tables above:
```
../configure --target-list=aarch64-softmmu \
  --without-default-features \
  --enable-cocoa --enable-hvf --enable-coreaudio [--enable-vmnet] \
  --enable-pixman --enable-vnc --enable-slirp --enable-fdt=internal \
  --enable-tools \
  [--enable-alcove]
```
Resulting Homebrew dylibs (expected from the probes): glib (+ its own deps: pcre2, libintl/gettext, libffi — general knowledge), pixman, zlib (system libz on macOS), libslirp. Everything else (gnutls chain, libusb, libssh, zstd, capstone, lzo, snappy, jpeg, png, curl, gtk, sdl, spice, epoxy…) stays out. Verify the actual list with `otool -L` on the built binary; the meson probes above are the source of truth for what *can* be linked, not proof of what *is*.

### 6.4 Relocating dylibs (general knowledge, not from the tree)

QEMU does not set any rpath (NOT FOUND in `meson.build`), so Homebrew libraries are linked by absolute install name (`/opt/homebrew/opt/.../lib/*.dylib`). The standard approach: copy each dylib into `Foo.app/Contents/Frameworks/`, rewrite the executable with `install_name_tool -change <old> @rpath/<lib>.dylib` and `install_name_tool -add_rpath @executable_path/../Frameworks`, rewrite each dylib's own id (`-id @rpath/<lib>.dylib`) and its inter-dylib references, then re-`codesign` everything (dylibs first, then the executable with `accel/hvf/entitlements.plist`, since `scripts/entitlement.sh:25` only ad-hoc signs). Tools like `dylibbundler` or `macpack` automate this. This paragraph is general macOS practice, not verified against QEMU sources.

---

## 7. Licensing

- Project-wide: "The QEMU emulator as a whole is released under the GNU General Public License, version 2." (`LICENSE:8-9`); "Parts of the QEMU emulator have specific licenses which are compatible with the GNU General Public License, version 2. Hence each source file contains its own licensing information. Source files with no licensing information are released under the GNU General Public License, version 2 or (at your option) any later version." (`LICENSE:11-15`); GPLv2-only contributions accepted only for `bsd-user/`, `linux-user/`, `hw/vfio/`, `hw/xen/xen_pt*` (`LICENSE:17-19`); TCG mostly BSD/MIT (`LICENSE:21-23`); QEMU is a trademark of Fabrice Bellard (`LICENSE:25`). `COPYING` is GPL v2 text (`COPYING:1-2`); `COPYING.LIB` is LGPL 2.1 (`COPYING.LIB:1-2`). `docs/about/license.rst:8-11` and `README.rst:30-31` repeat this.
- Firmware files are separate programs with separate licenses (`LICENSE:1-4`); `pc-bios/edk2-licenses.txt` is installed alongside the edk2 blobs (`pc-bios/meson.build:77`) — ship it in the bundle.
- File headers in `ui/`:
  - `ui/cocoa.m:1-23`: MIT ("Permission is hereby granted, free of charge…"), Copyright (c) 2008 Mike Kronenberg.
  - `ui/dbus.c:1-23`: MIT, Copyright (c) 2021 Marc-André Lureau; `ui/dbus.h:1-12` and `ui/dbus-console.c:1-12` likewise MIT.
  - `ui/dbus-module.c:1-18`: GPL "version 2 or (at your option) version 3", Red Hat 2021.
  - `ui/gtk.c:9-20`: GPL v2 or later (with LGPL-derived portions noted `:22-27`).
  - `ui/sdl2.c:1-23`, `ui/console.c:1-23`, `ui/vnc.c:1-25`, `util/datadir.c:1-23`: MIT.
  - SPDX tags already present in `ui/`: 10 files `GPL-2.0-or-later`, 5 files `MIT` (grep over `ui/*.c ui/*.h`).
- Policy for **new** files (enforced by `scripts/checkpatch.pl`, the project's patch checker):
  - New `.c/.h/.py/.pl/.sh/.json/.inc/.rs` and Makefiles MUST carry `SPDX-License-Identifier` (`scripts/checkpatch.pl:1503-1511`), and MUST NOT contain boilerplate license text, only the SPDX line, unless copied from existing code (`:1517-1523`; boilerplate patterns `:368-380`).
  - Preferred identifier is `GPL-2.0-or-later` (`:1378`); also accepted: `GPL-2.0-only`, `LGPL-2.1-only`, `LGPL-2.1-or-later`, `BSD-2-Clause`, `BSD-3-Clause`, `MIT` (`:1379-1385`); any other → ERROR (`:1400-1403`); a non-preferred but valid one → WARN "preferred for new files unless the code is derived from a source file with an existing declared license that must be retained. Please explain the license choice in the commit message." (`:1405-1410`).
  - Contributions require a DCO `Signed-off-by` (`docs/devel/code-provenance.rst:11-57`).
- So a new `ui/alcove.m` (and `include/ui/alcove.h`) can be `SPDX-License-Identifier: GPL-2.0-or-later` (preferred) or `MIT` (accepted; matches `ui/cocoa.m`/`ui/dbus.c` if you derive from them). Either way the linked `qemu-system-aarch64` is distributed under GPLv2 as a whole (`LICENSE:8-9`), so shipping it in an app means complying with GPLv2 for the binary (corresponding source offer), independent of the license you pick for your own files. (That last sentence is a reading of `LICENSE`, not legal advice.)

---

## Quick index of files you will patch

- `meson_options.txt:157` (add `alcove` option), `meson.build:1223` (probe), `:2437` (`CONFIG_ALCOVE`), `:4899` (summary), `scripts/meson-buildoptions.sh` (regenerate via `Makefile:131-135`), `ui/meson.build:73` (source), `qapi/ui.json:1522-1533` (enum member with `'if': 'CONFIG_ALCOVE'` and `@alcove: ... (Since 11.1)`), `:1556-1571` (union branch with the same `if`), plus a `DisplayAlcove` struct with `Since:`, modelled on `:1425-1460`.


## Open questions
- Whether ui/cocoa.m (and therefore an alcove.m modelled on it) compiles with pixman disabled was not verified; ui/meson.build:73 has no pixman guard but VNC/GTK/SPICE hard-require pixman, so the minimal configure line above enables pixman.
- The exact set of Homebrew dylibs linked by the minimal configure line was derived from meson probes, not from an actual build; confirm with `otool -L` on the produced qemu-system-aarch64.
- No generator-level check was found that a union branch's 'if' must equal its enum value's 'if' (scripts/qapi/schema.py:755-795); the match is a practical requirement per docs/devel/qapi-code-gen.rst:847-849 and ui.json convention, but if a stricter check exists elsewhere in scripts/qapi it was not located.
- No CI job that fails on a stale scripts/meson-buildoptions.sh was found in .gitlab-ci.d/ or scripts/; upstream may enforce it through a different mechanism not present in the release tarball.
