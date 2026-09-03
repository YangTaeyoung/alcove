# QEMU 11.1.1 notes: surface-update-threading
Source tree: build/qemu-src (tag v11.1.1). Every claim cites path:line. Produced by parallel research agents and checked by two skeptical reviewers; reviewer corrections were applied.

# QEMU 11.1.1 — DisplaySurface / DisplayChangeListener update path and threading model

All paths are relative to the tree root (`VERSION` = `11.1.1`). Everything below was re-read from the source for this revision; claims that come from outside the tree are explicitly marked **[external]**.

## 0. IMPORTANT: API renames in this tree (old names are NOT FOUND)

The public console API was renamed. The old free-function names do **not** exist in 11.1.1 (grep of `include/ui` and `ui/` for `register_displaychangelistener`, `update_displaychangelistener`, `void dpy_gfx_update(`, `void dpy_gfx_switch(`, `int dpy_set_ui_info(`, `void graphic_hw_update(`, `void dpy_mouse_set(`, `void dpy_cursor_define(`, `bool dpy_gfx_check_format(` returns nothing — NOT FOUND). Only the `DisplayChangeListenerOps` *callback field names* still use the `dpy_*` prefix.

| Old name (pre-11.x) | 11.1.1 name | Declared at |
|---|---|---|
| `register_displaychangelistener(dcl)` | `qemu_console_register_listener(con, dcl, ops)` | include/ui/console.h:268-270 |
| `unregister_displaychangelistener(dcl)` | `qemu_console_unregister_listener(dcl)` | include/ui/console.h:273 |
| `update_displaychangelistener(dcl, interval)` | `qemu_console_listener_set_refresh(dcl, interval)` | include/ui/console.h:271-272 |
| `dpy_gfx_update(con, x,y,w,h)` | `qemu_console_update(con, x,y,w,h)` | include/ui/console.h:279 |
| `dpy_gfx_update_full(con)` | `qemu_console_update_full(con)` | include/ui/console.h:280 |
| `dpy_gfx_replace_surface(con, surface)` | `qemu_console_set_surface(con, surface)` | include/ui/console.h:281-282 |
| `dpy_mouse_set(con,x,y,on)` | `qemu_console_set_mouse(con,x,y,on)` | include/ui/console.h:286 |
| `dpy_cursor_define(con,cursor)` | `qemu_console_set_cursor(con,cursor)` | include/ui/console.h:287 |
| `dpy_gfx_check_format(con,fmt)` | `qemu_console_check_format(con,fmt)` | include/ui/console.h:288-289 |
| `dpy_set_ui_info(con,info,delay)` | `qemu_console_set_ui_info(con,info,delay)` | include/ui/console.h:277 |
| `dpy_ui_info_supported(con)` | `qemu_console_ui_info_supported(con)` | include/ui/console.h:275 |
| `dpy_get_ui_info(con)` | `qemu_console_get_ui_info(con)` | include/ui/console.h:276 |
| `graphic_hw_update(con)` | `qemu_console_hw_update(con)` | include/ui/console.h:346 |
| `graphic_hw_invalidate(con)` | `qemu_console_hw_invalidate(con)` | include/ui/console.h:348 |
| `graphic_console_init(dev, head, ops, opaque)` | `qemu_graphic_console_create(dev, head, ops, opaque)` | include/ui/console.h:338-340 |

Note also that the DCL struct field is `dcl->ops` set by `qemu_console_register_listener` (ui/console.c:638) — you pass ops as a parameter rather than pre-filling `dcl->ops`.

---

## 1. DisplaySurface

### 1.1 Struct (include/ui/surface.h)

```c
#define QEMU_ALLOCATED_FLAG     0x01
#define QEMU_PLACEHOLDER_FLAG   0x02

typedef struct DisplaySurface {
    pixman_image_t *image;
    uint8_t flags;
#ifdef CONFIG_OPENGL
    uint32_t texture;
#endif
    qemu_pixman_shareable share_handle;
    uint32_t share_handle_offset;
} DisplaySurface;
```
(include/ui/surface.h:14-25)

- `image` — the pixman image; all geometry/format is derived from it.
- `flags` — `QEMU_ALLOCATED_FLAG` means QEMU allocated the pixel memory itself (shareable memfd); `QEMU_PLACEHOLDER_FLAG` marks the "Display output is not active." / "Guest has not initialized the display (yet)." surfaces (include/ui/surface.h:41-49 accessors `surface_is_allocated`, `surface_is_placeholder`).
- `share_handle` — `qemu_pixman_shareable` = `int` fd on POSIX (`SHAREABLE_NONE` = -1) or `HANDLE` on Win32 (include/ui/qemu-pixman.h:111-121). Set when the pixels live in a memfd (see §1.4 and §5.3).
- `share_handle_offset` — byte offset of the pixel data inside the shared mapping (used by virtio-gpu when a scanout is a sub-rect of a resource: hw/display/virtio-gpu.c:731). Set via `qemu_displaysurface_set_share_handle()` (ui/display-surface.c:13-22), which **asserts `share_handle == SHAREABLE_NONE`** first (:17) — a handle can only be attached once per surface.

### 1.2 Accessors (all `static inline`, include/ui/surface.h:51-86)

```c
static inline int surface_stride(DisplaySurface *s)            /* pixman_image_get_stride  */ // :51-54
static inline void *surface_data(DisplaySurface *s)            /* pixman_image_get_data    */ // :56-59
static inline int surface_width(DisplaySurface *s)             /* pixman_image_get_width   */ // :61-64
static inline int surface_height(DisplaySurface *s)            /* pixman_image_get_height  */ // :66-69
static inline pixman_format_code_t surface_format(DisplaySurface *s) /* pixman_image_get_format */ // :71-74
static inline int surface_bits_per_pixel(DisplaySurface *s)    /* PIXMAN_FORMAT_BPP(fmt)   */ // :76-80
static inline int surface_bytes_per_pixel(DisplaySurface *s)   /* DIV_ROUND_UP(bits, 8)    */ // :82-86
```

`surface_data()` returns the first byte of row 0; row `y` starts at `surface_data + y*surface_stride` (usage pattern: ui/sdl2-2d.c:44-53, ui/dbus-listener.c:779-788).

### 1.3 Constructors / destructor

```c
DisplaySurface *qemu_create_displaysurface_from(int width, int height,
                                                pixman_format_code_t format,
                                                int linesize, uint8_t *data);   // include/ui/surface.h:27-29
DisplaySurface *qemu_create_displaysurface_pixman(pixman_image_t *image);       // :30
DisplaySurface *qemu_create_placeholder_surface(int w, int h, const char *msg); // :31-32
void qemu_displaysurface_set_share_handle(DisplaySurface *surface,
                                          qemu_pixman_shareable handle,
                                          uint32_t offset);                     // :34-36
DisplaySurface *qemu_create_displaysurface(int width, int height);              // :38
void qemu_free_displaysurface(DisplaySurface *surface);                         // :39
```

Implementations (ui/display-surface.c):

- `qemu_create_displaysurface(w, h)` → `qemu_create_displaysurface_from(w, h, PIXMAN_x8r8g8b8, w * 4, NULL)` (ui/display-surface.c:24-33). **Default format = `PIXMAN_x8r8g8b8`, stride = width*4.**
- `qemu_create_displaysurface_from(w, h, format, linesize, data)` (ui/display-surface.c:35-62):
  - `data != NULL` → plain `pixman_image_create_bits(format, w, h, data, linesize)` wrapping the caller's memory (:44-47); `flags` stays 0 (not ALLOCATED), `share_handle = SHAREABLE_NONE` (:42). **No pixman destroy function is installed** here. The caller keeps ownership/lifetime responsibility; QEMU only unrefs the pixman image on free (:105). Devices use this for guest-memory-backed framebuffers: hw/display/ramfb.c:74-77 (wraps `physical_memory_map()` memory and *does* install its own destroy function `ramfb_unmap_display_surface`, :76-77), hw/display/vga.c:1665-1667 (wraps `s->vram_ptr + start_addr*4`), hw/display/bochs-display.c:221-226 (wraps `memory_region_get_ram_ptr(&s->vram) + mode.offset`).
  - `data == NULL` → `qemu_pixman_image_new_shareable(&surface->image, &surface->share_handle, "displaysurface", format, w, h, linesize, &error_abort)` and `flags = QEMU_ALLOCATED_FLAG` (:49-57). This allocates the pixels in a **memfd** (see §1.4), so every QEMU-allocated surface is shareable by fd.
- `qemu_create_displaysurface_pixman(image)` — takes a ref on an existing pixman image, `share_handle = SHAREABLE_NONE` (ui/display-surface.c:64-73); used by virtio-gpu 2D scanout (hw/display/virtio-gpu.c:730).
- `qemu_free_displaysurface(surface)` — `qemu_pixman_image_unref(surface->image); g_free(surface)` (ui/display-surface.c:99-107).

**What a `pixman_image_ref(surface->image)` actually keeps alive** (this distinction matters for zero-copy backends):

- For `data == NULL` surfaces (memfd-backed) the pixel memory is owned by the pixman image through the destroy function installed at ui/qemu-pixman.c:347-349, and for ramfb through ramfb.c:76-77. Holding a `pixman_image_ref` therefore keeps the *pixels* alive after the `DisplaySurface` is freed — this is what cocoa does (ui/cocoa.m:1917-1921) and vnc does (ui/vnc.c:822-823).
- For `data != NULL` surfaces with caller memory and no destroy function (VGA VRAM vga.c:1665-1667, bochs-display :221-226), a pixman ref keeps only the *image header* alive; the pixels are the device's VRAM, live and mutable (the guest keeps writing to them), and are not owned by the surface at all. Treat such surfaces (`share_handle == SHAREABLE_NONE`, `!surface_is_allocated()`) as device-owned memory you may not hold beyond the device's lifetime.
- The `DisplaySurface` container itself is `g_free`d at :106, so ref the `pixman_image_t`, never the `DisplaySurface`.

### 1.4 Shareable allocation

```c
bool qemu_pixman_image_new_shareable(pixman_image_t **image,
                                     qemu_pixman_shareable *handle,
                                     const char *name,
                                     pixman_format_code_t format,
                                     int width, int height,
                                     int rowstride_bytes, Error **errp);   // include/ui/qemu-pixman.h:123-131
```
ui/qemu-pixman.c:312-352: computes size via `qemu_pixman_image_calc_size` (include/ui/qemu-pixman-helpers.h:33-47; stride rounded to a 4-byte multiple by `qemu_pixman_stride`, :15-25), allocates with `qemu_pixman_shareable_alloc` → POSIX: `qemu_memfd_alloc(name, size, 0, handle, errp)` (ui/qemu-pixman.c:274-284); Win32: `qemu_win32_map_alloc`. `qemu_memfd_alloc` (util/memfd.c:108-148) tries `memfd_create` (with, then without seals), falls back to an unlinked `mkstemp` file + `ftruncate`, then `mmap(PROT_READ|PROT_WRITE, MAP_SHARED)`; returns the fd in `*fd` (:139). The pixman image gets a destroy function that munmaps and closes the fd (ui/qemu-pixman.c:302-310, 347-349; `qemu_memfd_free` util/memfd.c:150-162 — note `close(fd)` at :158-161, so **dup the fd** before handing it to anyone who outlives the surface).

### 1.5 Pixel format and byte order

- Default guest-framebuffer format: `PIXMAN_x8r8g8b8` (ui/display-surface.c:30). `qemu_default_pixman_format(32, true)` also returns `PIXMAN_x8r8g8b8` (ui/qemu-pixman.c:68-80). `qemu_console_check_format`'s default (no `dpy_gfx_check_format` op) accepts **only** `qemu_default_pixman_format(32, true)` (ui/console.c:816-821).
- pixman formats are **native-endian** ("pixman image formats are defined to be native endian, that means host byte order on qemu", include/ui/qemu-pixman.h:18-23).
- Channel layout of the 32-bit word: R in bits 23..16, G in 15..8, B in 7..0, top byte unused. In-tree corroboration: `VNC_SERVER_FB_FORMAT` is defined as `PIXMAN_FORMAT(32, PIXMAN_TYPE_ARGB, 0, 8, 8, 8)` under the comment "server fb is in PIXMAN_x8r8g8b8" (ui/vnc.h:598-599), and `vnc_convert_pixel` extracts `r = (v & 0x00ff0000) >> 16`, `g = (v & 0x0000ff00) >> 8`, `b = v & 0xff` (ui/vnc.c:869-872); `qemu_pixelformat_from_pixman`'s `PIXMAN_TYPE_ARGB` branch gives `rshift = bbits+gbits = 16`, `gshift = 8`, `bshift = 0` (ui/qemu-pixman.c:28-33). **[external]** The identity `PIXMAN_x8r8g8b8 == PIXMAN_FORMAT(32, PIXMAN_TYPE_ARGB, 0, 8, 8, 8)` itself comes from the system `<pixman.h>` enum, which is not in this tree.
- **On a little-endian host the bytes in memory are `B, G, R, X`** (0xXXRRGGBB stored LE). Corroboration in tree: on LE `PIXMAN_LE_x8r8g8b8 == PIXMAN_x8r8g8b8` (include/ui/qemu-pixman.h:52) and `DRM_FORMAT_XRGB8888 ↔ PIXMAN_LE_x8r8g8b8` (ui/qemu-pixman.c:93-100; "drm is little endian, pixman is native endian" :93); gtk maps it to `CAIRO_FORMAT_RGB24` (ui/gtk.c:522-534); sdl2 maps `PIXMAN_x8r8g8b8` to `SDL_PIXELFORMAT_ARGB8888` (ui/sdl2-2d.c:99-101); **cocoa builds the framebuffer `CGImage` directly over the pixman data/stride with `kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst`** (ui/cocoa.m:416-428, bitmapInfo at :423). **[external]** That this is the same layout Metal calls `BGRA8Unorm` is not verifiable in this tree.
- Non-default formats **can** reach your DCL: the VGA device shares its VRAM directly in 15/16/24/32-bpp native or byteswapped formats if `qemu_console_check_format()` says all listeners accept it (hw/display/vga.c:1622-1634); virtio-gpu 2D creates surfaces in the guest's chosen format (`virtio_gpu_get_pixman_format`, include/hw/virtio/virtio-gpu-pixman.h:20-43, e.g. `PIXMAN_BE_b8g8r8x8`, which on LE is `PIXMAN_x8r8g8b8` per include/ui/qemu-pixman.h:44). If you implement `dpy_gfx_check_format`, `qemu_pixman_check_format` (ui/qemu-pixman.c:172-191) is the stock "pixman can convert these" set. If you do **not** implement it, VGA will allocate a shadow surface in `PIXMAN_x8r8g8b8` for you (vga.c:1630 → :1670 `qemu_console_resize`), but virtio-gpu does not consult check_format — handle at least `x8r8g8b8`/`a8r8g8b8` and ideally convert others with `pixman_image_composite` (pattern: ui/gtk.c:535-552, ui/dbus-listener.c:770-776).

### 1.6 Who writes the pixel memory, and when (essential for zero-copy sharing)

- Surfaces created with `qemu_create_displaysurface_from(..., data)` wrap **guest-visible memory** — VGA `vram_ptr` (hw/display/vga.c:1665-1667), bochs-display RAM pointer (hw/display/bochs-display.c:221-226), ramfb `physical_memory_map` (hw/display/ramfb.c:67-77). Guest vCPUs write into it at any time with no lock; the `dpy_gfx_update` you get for these is only a "dirty since last poll" hint derived from a dirty-bitmap snapshot (bochs-display.c:234-252, vga.c:1741/1765).
- memfd-backed surfaces (`qemu_console_resize` → `qemu_create_displaysurface`, ui/console.c:1371; virtio-gpu 2D resources, hw/display/virtio-gpu.c:301-309) are written by the device model **under the BQL on the main loop** (virtio-gpu transfer commands in its ctrl BH; VGA shadow rendering inside `gfx_update`).
- Consequence: a foreign thread or another process reading the mapping will see tearing unless it reads only while the BQL is held, or double-buffers / copies inside `dpy_gfx_update`.

---

## 2. DisplayChangeListener and DisplayChangeListenerOps (include/ui/console.h)

### 2.1 Structs (include/ui/console.h:167-239, comments reproduced verbatim)

```c
typedef struct DisplayChangeListenerOps {
    const char *dpy_name;

    /* optional */
    void (*dpy_refresh)(DisplayChangeListener *dcl);

    /* optional */
    void (*dpy_gfx_update)(DisplayChangeListener *dcl,
                           int x, int y, int w, int h);
    /* optional */
    void (*dpy_gfx_switch)(DisplayChangeListener *dcl,
                           struct DisplaySurface *new_surface);
    /* optional */
    bool (*dpy_gfx_check_format)(DisplayChangeListener *dcl,
                                 pixman_format_code_t format);

    /* optional */
    void (*dpy_text_cursor)(DisplayChangeListener *dcl,
                            int x, int y);
    /* optional */
    void (*dpy_text_resize)(DisplayChangeListener *dcl,
                            int w, int h);
    /* optional */
    void (*dpy_text_update)(DisplayChangeListener *dcl,
                            int x, int y, int w, int h);

    /* optional */
    void (*dpy_mouse_set)(DisplayChangeListener *dcl,
                          int x, int y, bool on);
    /* optional */
    void (*dpy_cursor_define)(DisplayChangeListener *dcl,
                              QEMUCursor *cursor);

    /* required if GL */
    void (*dpy_gl_scanout_disable)(DisplayChangeListener *dcl);
    /* required if GL */
    void (*dpy_gl_scanout_texture)(DisplayChangeListener *dcl,
                                   uint32_t backing_id,
                                   bool backing_y_0_top,
                                   uint32_t backing_width,
                                   uint32_t backing_height,
                                   uint32_t x, uint32_t y,
                                   uint32_t w, uint32_t h,
                                   void *d3d_tex2d);
    /* optional (default to true if has dpy_gl_scanout_dmabuf) */
    bool (*dpy_has_dmabuf)(DisplayChangeListener *dcl);
    /* optional */
    void (*dpy_gl_scanout_dmabuf)(DisplayChangeListener *dcl,
                                  QemuDmaBuf *dmabuf);
    /* optional */
    void (*dpy_gl_cursor_dmabuf)(DisplayChangeListener *dcl,
                                 QemuDmaBuf *dmabuf, bool have_hot,
                                 uint32_t hot_x, uint32_t hot_y);
    /* optional */
    void (*dpy_gl_cursor_position)(DisplayChangeListener *dcl,
                                   uint32_t pos_x, uint32_t pos_y);
    /* optional */
    void (*dpy_gl_release_dmabuf)(DisplayChangeListener *dcl,
                                  QemuDmaBuf *dmabuf);
    /* required if GL */
    void (*dpy_gl_update)(DisplayChangeListener *dcl,
                          uint32_t x, uint32_t y, uint32_t w, uint32_t h);

} DisplayChangeListenerOps;                                     // include/ui/console.h:167-230

struct DisplayChangeListener {
    uint64_t update_interval;
    const DisplayChangeListenerOps *ops;
    DisplayState *ds;
    QemuConsole *con;

    QLIST_ENTRY(DisplayChangeListener) next;
};                                                              // include/ui/console.h:232-239
```

`DisplayState` is private to ui/console.c:66-75 (`gui_timer`, `last_update`, `update_interval`, `refreshing`, `initialized`, `listeners`, `console_notifiers`). `QemuConsole` is private to ui/console-priv.h:12-30 (`index`, `ds`, `surface`, `scanout`, `gl`, `ui_info`, `ui_timer`, `hw_ops`, `hw`, ...).

### 2.2 Registration

```c
void qemu_console_register_listener(QemuConsole *con, DisplayChangeListener *dcl,
                                    const DisplayChangeListenerOps *ops);
```
ui/console.c:631-651: asserts `!dcl->ds` (:635), sets `dcl->con`, `dcl->ops` (:637-638), sets `dcl->ds` (:641), inserts at head of `ds->listeners` (:642), calls `gui_setup_refresh()` (:643), then `displaychangelistener_display_console(dcl, &error_fatal)` (:644). That function (:273-311) **synchronously calls your `dpy_gfx_switch` with the console's current surface, followed by a full-area `dpy_gfx_update` iff the console is in `SCANOUT_SURFACE` mode** (:293-294 → `displaychangelistener_gfx_switch` :236-249, update at :244-248). Then, for a graphic console, `dcl_set_graphic_cursor` replays `dpy_cursor_define` (if a cursor exists) and `dpy_mouse_set` (:609-618, called at :645-646); for a text console it calls `qemu_text_console_update_size` instead (:647-649).

**`con == NULL` vs. incompatible console — these behave very differently:**

- `con == NULL` → you are switched to a static 640x480 dummy placeholder "This VM has no graphic display device." with `update=TRUE` (:281-289; dummy created once at :282-284, switch+update at :288). This is not an error, but it leaves you permanently on the dummy: `dpy_refresh` still fires (it is not console-filtered, :826-835) but `qemu_console_hw_update(NULL)` is a no-op (:155-157) and every broadcast is filtered by `dcl->con` (`qemu_console_update` :746, `qemu_console_set_surface` :792, `qemu_console_set_mouse` :892, `qemu_console_set_cursor` :910). `qemu_console_lookup_default()` returns NULL when no consoles exist (:1189-1199).
- `con != NULL` but incompatible → **QEMU exits.** `console_compatible_with()` (:568-596) reports via `error_setg(errp, ...)` — GL-context mismatch :575-580, "The console requires a GL context." :582-587 (device `get_flags` has `GRAPHIC_FLAGS_GL`), "The console requires display DMABUF support." :589-593 — and because the errp is `&error_fatal` (:644), `error_setg` prints and `exit(1)`s (util/error.c:39-42) before the dummy branch at :281 is reached. virtio-gpu sets `GRAPHIC_FLAGS_GL` when virgl is enabled and `GRAPHIC_FLAGS_DMABUF` when dmabuf is enabled (hw/display/virtio-gpu-base.c:161-167). A non-GL DCL registered on a virtio-gpu-gl/virgl console is therefore fatal, not a fallback.
- If the first console is a text console (`qemu_console_lookup_default` returns the first console of any kind if there is no graphic one, :1198), you should implement `dpy_text_*` or at least tolerate a text-rendered surface.

`dcl->con` matters: every broadcast skips listeners whose `dcl->con != con`. Get a console with `qemu_console_lookup_default()` (ui/console.c:1189-1199: first graphic console, else first console), `qemu_console_lookup_by_index(i)` (:1201-1211), or `qemu_console_lookup_by_device_name(id, head, errp)` (:1235-).

```c
void qemu_console_unregister_listener(DisplayChangeListener *dcl);   // ui/console.c:673-683
```
Removes from the list, sets `dcl->ds = NULL`, recalculates the refresh timer. No-op if not registered (:677-679).

### 2.3 `dpy_gfx_update(dcl, x, y, w, h)`

Called by `qemu_console_update(con, x, y, w, h)` (ui/console.c:730-753). Semantics: **the pixels inside `[x, x+w) × [y, y+h)` of the surface you were last handed via `dpy_gfx_switch` have changed; read them from `surface_data()` now.** The surface memory is stable between switches, so backends keep the `DisplaySurface *` and copy from it in update (ui/sdl2-2d.c:31-57, ui/gtk.c:392-441, ui/dbus-listener.c:763-803, vnc marks dirty and copies later in refresh: ui/vnc.c:653-660, 3259-3267).

**Clamping and empty rects.** The rect is clamped before dispatch: `x = MAX(x,0); y = MAX(y,0); x = MIN(x,width); y = MIN(y,height); w = MIN(w, width-x); h = MIN(h, height-y);` (:737-742). Nothing rejects the result, so a device rect entirely outside the surface yields **`w <= 0` or `h <= 0`**. Guard for that before computing offsets.

**When a full-area update follows a switch automatically — exactly two cases:**
1. `qemu_console_set_surface(con, NULL)` → placeholder surface (:783) → switch with `update = TRUE` (:795, `surface ? FALSE : TRUE`).
2. Registration: `displaychangelistener_display_console` passes `update = (con->scanout.kind == SCANOUT_SURFACE)` (:293-294), or always `TRUE` for the dummy path (:288).

After a **real** device-supplied surface is switched in, console.c emits **no** `dpy_gfx_update`; the device must emit its own (ramfb.c:120 `qemu_console_update_full`, bochs-display.c:232, vga.c:1741/1765, virtio-gpu.c:596-597 resource-flush → per-scanout intersect).

### 2.4 `dpy_gfx_switch(dcl, new_surface)` — when it's called and surface lifetime

Called from `qemu_console_set_surface(con, surface)` (ui/console.c:763-799):

```c
void qemu_console_set_surface(QemuConsole *con, DisplaySurface *surface)
{
    ...
    DisplaySurface *old_surface = con->surface;
    DisplaySurface *new_surface = surface;
    if (!surface) { new_surface = qemu_create_placeholder_surface(width, height, "Display output is not active."); } // :774-784
    assert(old_surface != new_surface);                     // :786
    con->scanout.kind = SCANOUT_SURFACE;                    // :788
    con->surface = new_surface;                             // :789
    dpy_gfx_create_texture(con, new_surface);               // :790
    QLIST_FOREACH(dcl, &s->listeners, next) {               // :791-796
        if (con != dcl->con) continue;
        displaychangelistener_gfx_switch(dcl, new_surface, surface ? FALSE : TRUE);   // :795
    }
    dpy_gfx_destroy_texture(con, old_surface);              // :797
    qemu_free_displaysurface(old_surface);                  // :798
}
```

- When: any time the device changes resolution/format/base address — `qemu_console_resize()` (ui/console.c:1357-1373), device page flips (vga.c:1656-1668), virtio-gpu `SET_SCANOUT` (hw/display/virtio-gpu.c:709-736), ramfb (ramfb.c:114-116), console creation (:1157-1158) and close (:1184-1185), and once at registration (§2.2).
- `qemu_console_resize()` early-return (:1363-1369) is `(scanout.kind != SCANOUT_SURFACE || (surface && surface_is_allocated(surface) && !surface_is_placeholder(surface))) && width unchanged && height unchanged`. So it is a no-op both when the current allocated, non-placeholder surface already has that size **and** when the console is currently in `SCANOUT_TEXTURE`/`SCANOUT_DMABUF` mode with the same dimensions (no new surface, no `dpy_gfx_switch`). Otherwise it allocates a fresh `PIXMAN_x8r8g8b8` memfd surface (:1371) and switches.
- **The old surface is freed immediately after all listeners' `dpy_gfx_switch` return** (:798). The `DisplaySurface *` you received previously is dangling as soon as your switch callback returns. If you need the old pixels beyond that (e.g., a render thread still reading), `pixman_image_ref(surface->image)` in switch and unref when done — cocoa comments this explicitly ("The DisplaySurface will be freed as soon as this callback returns", ui/cocoa.m:1917-1921) and vnc does it (ui/vnc.c:822-823). See §1.3 for what a ref does and does not keep alive.
- The `update` flag: `surface ? FALSE : TRUE` (:795) — see §2.3.
- `surface_is_placeholder(new_surface)` lets you detect "not active" states (sdl2 uses it: ui/sdl2-2d.c:75).
- **Same memfd, different offsets (virtio-gpu):** virtio-gpu creates a *new* `DisplaySurface` on every `SET_SCANOUT` that changes data pointer/size (:709-736) but the `share_handle` it attaches is the *resource's* fd (`res->share_handle`, :731) with `share_handle_offset = fb->offset`. Successive `dpy_gfx_switch` calls may hand you the same fd with a different offset/stride/size, and the memfd is the size of the whole resource (`res->hostmem`, :299), not `surface_stride*height`. Key any per-mapping cache on `(fd, offset)` and size the mapping from the fd (`fstat`) or `offset + stride*height`, not from the surface alone.
- **Re-entrancy:** `qemu_console_hw_update(dcl->con)` called from your `dpy_refresh` synchronously runs the device's `gfx_update` (:153-161), which may call `qemu_console_set_surface` / `qemu_console_update` and therefore re-enter your own `dpy_gfx_switch` / `dpy_gfx_update` while `dpy_refresh` is still on the stack (vga.c:1668/1741/1765, bochs-display.c:227/246/251, ramfb.c:115-120). Do not hold a non-recursive mutex across `qemu_console_hw_update`, and do not assume `dpy_gfx_switch` only happens between refreshes.

### 2.5 `dpy_refresh` and the refresh timer

```c
#define GUI_REFRESH_INTERVAL_DEFAULT    30      /* ms */
#define GUI_REFRESH_INTERVAL_IDLE     3000
```
(include/ui/console.h:38-40)

- `gui_setup_refresh(ds)` (ui/console.c:125-144): if **any** listener has a non-NULL `dpy_refresh`, creates `ds->gui_timer = timer_new_ms(QEMU_CLOCK_REALTIME, gui_update, ds)` and arms it immediately (:136-139); if none, frees the timer and sets it to NULL (:140-143). Called on register/unregister (:643, :682).
- `gui_update(ds)` (ui/console.c:99-123): sets `ds->refreshing = true`, calls `dpy_refresh(ds)` which invokes **every** listener's `dpy_refresh` (:826-835, not filtered by console), then computes the next interval = min over listeners of (`dcl->update_interval` if non-zero else `GUI_REFRESH_INTERVAL_DEFAULT` = 30 ms), starting from `GUI_REFRESH_INTERVAL_IDLE` (3000 ms) if there are no listeners; re-arms `timer_mod(ds->gui_timer, last_update + interval)`.
- So with a DCL that has `dpy_refresh` and `update_interval == 0`, `dpy_refresh` fires every ~30 ms.
- **Setting the interval — ordering constraint.** `qemu_console_listener_set_refresh(dcl, interval)` (ui/console.c:653-662) unconditionally dereferences `dcl->ds` (`DisplayState *ds = dcl->ds; ... ds->refreshing`, :656-659) and calls `timer_mod(ds->gui_timer, ...)` (:660). It must therefore be called **only after** `qemu_console_register_listener` (which sets `dcl->ds` at :641) **and** only when some registered listener has a non-NULL `dpy_refresh` (otherwise `ds->gui_timer == NULL`, :140-143). Calling it before registration crashes. Before registration, set `dcl->update_interval` (ms) directly. Cocoa calls it only from `updateUIInfoLocked` (ui/cocoa.m:548-549), which runs after registration (:2019-2024); vnc adapts it dynamically from `dpy_refresh` (ui/vnc.c:3255, 3262, 3275; intervals ui/vnc.c:61-63).
- **What `dpy_refresh` must do:** call `qemu_console_hw_update(dcl->con)` so the device model renders/scans its framebuffer and emits `qemu_console_update` for dirty rects. Every backend does exactly this as the first thing (ui/cocoa.m:1933, ui/gtk.c:443-446, ui/sdl2-2d.c:127-134, ui/vnc.c:3259, ui/dbus-listener.c:741-744). If no listener has `dpy_refresh`, the timer doesn't exist and devices like VGA never get polled → no `dpy_gfx_update` ever arrives.

### 2.6 `dpy_mouse_set(dcl, x, y, on)`

From `qemu_console_set_mouse(con, x, y, on)` (ui/console.c:882-899): stores `cursor_x/cursor_y/cursor_on` on the graphic console (:888-890), then broadcasts to listeners bound to that console (:891-898). Meaning: the guest's hardware cursor position (surface coordinates) and visibility. Replayed on registration (:615-617).

### 2.7 `dpy_cursor_define(dcl, cursor)` and `QEMUCursor`

```c
/* cursor data format is 32bit RGBA */
typedef struct QEMUCursor {
    uint16_t            width, height;
    int                 hot_x, hot_y;
    int                 refcount;
    uint32_t            data[];
} QEMUCursor;                                   // include/ui/console.h:120-126

QEMUCursor *cursor_alloc(uint16_t width, uint16_t height);
QEMUCursor *cursor_ref(QEMUCursor *c);
void cursor_unref(QEMUCursor *c);               // include/ui/console.h:128-130
QEMUCursor *qemu_console_get_cursor(QemuConsole *con);   // include/ui/console.h:361; ui/console.c:1277-1280
```

- `data` is `width*height` packed `uint32_t` pixels, no row padding (dbus sends `c->width * c->height * 4` bytes, ui/dbus-listener.c:902-908; cocoa uses `width*height*4`, ui/cocoa.m:359-363). Maximum size: `cursor_alloc` returns NULL for width or height > 512 (ui/cursor.c:99-101), so 512*512*4 bytes is the most you must handle.
- **Pixel word convention.** The header comment says "32bit RGBA" (include/ui/console.h:120), but the effective in-tree convention is **native-endian `0xAARRGGBB` words** (the `PIXMAN_a8r8g8b8` layout; bytes `B,G,R,A` on LE):
  - Producers: virtio-gpu `memcpy`s the guest cursor resource's pixman image verbatim (hw/display/virtio-gpu.c:45-76), and a `B8G8R8A8_UNORM` guest resource is `PIXMAN_BE_b8g8r8a8` (include/hw/virtio/virtio-gpu-pixman.h:26-27) = `PIXMAN_a8r8g8b8` on LE (include/ui/qemu-pixman.h:45); vmware_vga 32bpp does `qc->data[i] |= c->image[i] & 0xffffff` over an alpha mask (hw/display/vmware_vga.c:537-545); qxl alpha cursors are unpacked raw (hw/display/qxl-render.c:289-292); `cursor_set_mono` writes `0xff000000 | foreground/background` — alpha in the top byte (ui/cursor.c:160, :162, :187, :194).
  - Consumers: sdl2 `SDL_CreateRGBSurfaceFrom(c->data, w, h, 32, w*4, 0xff0000, 0x00ff00, 0xff, 0xff000000)` — R/G/B/A masks = ARGB word (ui/sdl2.c:771-773); cocoa `kCGBitmapByteOrder32Little | kCGImageAlphaFirst` (ui/cocoa.m:373); dbus XML documents `CursorDefine` data as "must be ARGB, 32-bit" (ui/dbus-display1.xml:444).
  - Exceptions: **gtk** wraps `c->data` with `gdk_pixbuf_new_from_data(GDK_COLORSPACE_RGB, has_alpha=TRUE, 8 bits/sample)` — i.e. it reads R,G,B,A *byte* order (= `0xAABBGGRR` words on LE) (ui/gtk.c:486-489); and the built-in XPM cursors are parsed as `(0xff<<24)|(b<<16)|(g<<8)|r` (ui/cursor.c:34), i.e. ABGR words. Both are harmless only because those cursors are black/white. Follow the ARGB-word convention.
- Refcounting: `cursor_ref`/`cursor_unref` are **plain non-atomic** `refcount++`/`--` (ui/cursor.c:110-124) — only call them with the BQL held. `qemu_console_set_cursor(con, cursor)` (ui/console.c:901-917) refs and stores the cursor on the console (:907-908), so `qemu_console_get_cursor(dcl->con)` returns the current cursor later; cocoa does its `cursor_ref` inside `BQL_LOCK_GUARD()` on the AppKit thread (ui/cocoa.m:1959-1960 → `setCursor` :341-354, ref at :354). Replayed on registration if a cursor exists (:612-614).

### 2.8 `dpy_gfx_check_format(dcl, format)`

```c
bool qemu_console_check_format(QemuConsole *con, pixman_format_code_t format);
```
ui/console.c:801-824: returns false if **any** listener (bound to this console or unbound, :808-811) rejects `format`; listeners without the op accept only `qemu_default_pixman_format(32, true)` (= `PIXMAN_x8r8g8b8`, :816-821). Devices call it to decide whether to hand you their native buffer or a shadow copy (hw/display/vga.c:1628-1634). Stock implementations: `qemu_pixman_check_format` (ui/qemu-pixman.c:172-191: x8r8g8b8, a8r8g8b8, b8g8r8x8, b8g8r8a8, r8g8b8, b8g8r8, x1r5g5b5, r5g6b5) and `console_gl_check_format` for GL (include/ui/console.h:381-382).

---

## 3. Threading model

### 3.1 Which thread invokes the DCL callbacks

All DCL callbacks are invoked synchronously from `qemu_console_*` functions, which are invoked from:

1. The GUI refresh timer `gui_update` (ui/console.c:99-123) — a `QEMU_CLOCK_REALTIME` timer (:137). Timers run inside `main_loop_wait()` via `qemu_clock_run_all_timers()` (util/main-loop.c:605), i.e., on the thread running `qemu_main_loop()`.
2. Device models' `gfx_update` (called from `qemu_console_hw_update` inside your `dpy_refresh`, ui/console.c:153-161) → `qemu_console_update`/`qemu_console_set_surface` (vga.c:1385/1668/1741/1765; ramfb.c:115-120; bochs-display.c:227/232/246/251).
3. Device bottom halves. virtio-gpu processes its control/cursor queues from BHs (`virtio_gpu_handle_ctrl_cb` schedules `g->ctrl_bh`, hw/display/virtio-gpu.c:1110-1114; `virtio_gpu_ctrl_bh` :1213-1219) → `qemu_console_set_surface` / `qemu_console_update` (virtio-gpu.c:734, 596-597). **These BHs are NOT on `qemu_get_aio_context()`.** They are created with `virtio_bh_io_new_guarded` (hw/display/virtio-gpu.c:1659-1661) → `virtio_bh_io_new_guarded_full` (include/hw/virtio/virtio.h:705-706) → `aio_bh_new_full(iohandler_get_aio_context(), cb, opaque, name, &transport->mem_reentrancy_guard)` (hw/virtio/virtio.c:4729-4737, call at :4735-4736) — i.e. the private **`iohandler_ctx`** (util/main-loop.c:617-635), the same context `qemu_set_fd_handler` uses (:643-651).

**BQL:** the main-loop thread holds the BQL for everything except the poll itself: `os_host_main_loop_wait` does `bql_unlock(); … qemu_poll_ns(...); … bql_lock(); glib_pollfds_poll();` (util/main-loop.c:307-315; Win32 variant :522-530). `glib_pollfds_poll` → `g_main_context_dispatch` (:288-294) — which runs the AioContext GSources (`aio_ctx_dispatch`, util/async.c:357-367; both `qemu_aio_context` and `iohandler_ctx` sources are attached to the default GMainContext at util/main-loop.c:179-186) — and `qemu_clock_run_all_timers()` (:605) both run **with the BQL held**. The initial acquisition on the main-loop thread is in `qemu_default_main`: `bql_lock(); status = qemu_main_loop(); …` (system/main.c:44-56). The BQL is `static QemuMutex bql` in system/cpus.c:72 with a per-thread `bql_locked` TLS flag (system/cpus.c:527, 555-558); `bql_lock_impl` asserts it is not already held by the current thread (:575-581) and `bql_unlock` asserts it is (:583-588).

Conclusion: **DCL callbacks run on the QEMU main-loop thread with the BQL held.** Two grades of guarantee:

- For `iohandler_ctx` (virtio-gpu BHs, `qemu_set_fd_handler`, `event_notifier_set_handler`): the comment at util/main-loop.c:617-621 says "This context runs on top of main loop. We can't reuse qemu_aio_context because iohandlers mustn't be polled by aio_poll(qemu_aio_context)." That context is only ever dispatched from the main loop's glib dispatch, so callbacks originating there are guaranteed to be on the actual main-loop thread.
- For `qemu_get_aio_context()` BHs: include/qemu/main-loop.h:317-319 notes "any thread that holds the BQL can act as the block layer main thread"; the mechanism is `aio_poll()` (util/aio-posix.c:652) which calls `aio_bh_poll(ctx)` (:745). I did not find any display path in this tree that drains `qemu_aio_context` from a non-main-loop thread, but the guarantee you should rely on for these is "BQL held", not "specific pthread id".

### 3.2 `bql_lock` / `bql_unlock` usage in ui/cocoa.m and ui/console.c

- ui/console.c: **no** `bql_lock`/`bql_unlock` calls (grep returned none) — console.c assumes it is already called under the BQL.
- ui/cocoa.m: because Cocoa callbacks arrive on the AppKit main thread (which does **not** hold the BQL), cocoa wraps every call into QEMU with the BQL:

```c
static void with_bql(CodeBlock block)
{
    bool locked = bql_locked();
    if (!locked) { bql_lock(); }
    block();
    if (!locked) { bql_unlock(); }
}                                                   // ui/cocoa.m:117-127 (bool_with_bql :129-142)
```
Used at ui/cocoa.m:586-588 (`updateUIInfo` → `updateUIInfoLocked` → `qemu_console_set_ui_info`), :1223-1226 (shutdown request), :1799-1820 (clipboard; note it temporarily `bql_unlock()`/`bql_lock()` around `qemu_event_wait`, :1807-1809), and `BQL_LOCK_GUARD()` at :1959 inside a `dispatch_async` block calling `qemu_console_get_cursor`. Conversely, the DCL callbacks (`cocoa_update` :1899-1908, `cocoa_switch` :1910-1926, `cocoa_mouse_set` :1949-1954, `cocoa_cursor_define` :1956-1962) arrive on the QEMU main-loop thread and **bounce to the AppKit thread with `dispatch_async(dispatch_get_main_queue(), ^{...})`** — they never touch AppKit from the QEMU thread. `cocoa_refresh` (:1928-1947) stays on the QEMU thread (calls `qemu_console_hw_update` at :1933 and reads the pasteboard).

### 3.3 How cocoa runs the QEMU main loop on a non-initial thread

```c
extern int (*qemu_main)(void);                       // include/qemu-main.h
```

system/main.c:
- `int (*qemu_main)(void);` (:58); on Darwin it defaults to `os_darwin_cfrunloop_main` = `CFRunLoopRun()` (:60-67).
- `main()` (:69-96): `qemu_init(argc, argv)`; then `bql_unlock(); replay_mutex_unlock();` (:84-85, comment :73-83 explains the lock hand-off); if `qemu_main != NULL` → `qemu_thread_create(&main_loop_thread, "qemu_main", qemu_default_main, NULL, QEMU_THREAD_DETACHED); return qemu_main();` (:87-91); else `qemu_default_main(NULL)` on the initial thread (:92-94).
- `qemu_default_main` (:44-56): `replay_mutex_lock(); bql_lock(); status = qemu_main_loop(); qemu_cleanup(status); bql_unlock(); … exit(status);`.

ui/cocoa.m: `cocoa_display_init` (runs during `qemu_init`, on the initial thread) registers the DCL (:2019-2020) and ends with `qemu_main = cocoa_main;` (:2032-2036); `cocoa_main` is `[NSApp run]` (:1887-1894). So on macOS with `-display cocoa`, thread A (initial/pthread-main) runs AppKit and thread B ("qemu_main") runs `qemu_main_loop` under the BQL.

**Why a non-Cocoa backend does not need this:** GTK and SDL explicitly reset the pointer — `qemu_main = NULL;` with comments "GTK's event polling must happen on the main thread." (ui/gtk.c:2820-2821) and "SDL's event polling (in dpy_refresh) must happen on the main thread." (ui/sdl2.c:1017-1018) — so the QEMU main loop runs on the initial thread and their `dpy_refresh` pumps their toolkit events from inside it. A headless / IPC backend (vnc, dbus, a custom shared-memory listener) has no toolkit main-thread requirement at all: it just leaves `qemu_main` alone. **Note for macOS builds:** `qemu_main` defaults to `os_darwin_cfrunloop_main` (system/main.c:66) regardless of display backend, so on Darwin the QEMU main loop is *always* on a secondary thread unless a UI sets `qemu_main = NULL`. If your backend wants the QEMU loop on the initial thread (e.g., it must talk to AppKit/Metal from the process main thread itself), set `qemu_main = NULL` in your `QemuDisplay.init`; otherwise leave the default and treat "QEMU main-loop thread" and "process main thread" as different threads.

### 3.4 When `QemuDisplay.early_init` / `init` run and what exists then

```c
struct QemuDisplay {
    DisplayType type;
    void (*early_init)(DisplayOptions *opts);
    void (*init)(DisplayState *ds, DisplayOptions *opts);
    void (*cleanup)(void);
    const char *vc;
};                                                   // include/ui/console.h:400-408
```

- `early_init` is invoked from `qemu_setup_display()` → `qemu_display_early_init()` during option processing (system/vl.c:1377-1393; ui/console.c:1425-1446), **before devices exist**.
- `init` is invoked from `qemu_init_displays()` (system/vl.c:2697-2703) → `init_displaystate()` (:2702; ui/console.c:1102-) then `qemu_display_init(ds, &dpy)` (:2703; ui/console.c:1448-1456). `qemu_init_displays()` is called at vl.c:3864, after `qmp_x_exit_preconfig` (:3861-3863 — machine and devices realized, so graphic consoles already exist) and after `qemu_init_main_loop` (:3770 — so `qemu_get_aio_context()` and `iohandler_ctx` are usable).
- The BQL is held for the whole of `qemu_init`: it is taken in `qemu_init_subsystems` (system/runstate.c:982, called from vl.c:2909) and released only after `qemu_init` returns (system/main.c:73-85; the `bql_unlock()` at :84 asserts it is held, system/cpus.c:583-588). Creating BHs / fd handlers inside `init` is therefore legal (§4.2).

### 3.5 Plumbing a new backend into `-display`

- `QemuDisplay.type` must be a value of the QAPI enum `DisplayType` (qapi/ui.json:1522-1534), and backend-specific options need a branch in the `DisplayOptions` union (:1556-1572).
- Registration: `qemu_display_register(ui)` stores into `dpys[type]` (ui/console.c:1385-1391). Built-in backends register with `type_init(register_xxx)` (cocoa: ui/cocoa.m:2055-2066; cocoa is compiled into `system_ss`, ui/meson.build:73). gtk/sdl/dbus/spice are loadable `ui_modules` (ui/meson.build:93-200): if `dpys[type]` is NULL when selected, `qemu_display_find_default` / `qemu_display_early_init` call `ui_module_load(DisplayType_str(type))` (ui/console.c:1408-1415, 1431-1437) = `module_load("ui-", ...)` (include/qemu/module.h:66).

---

## 4. Running code on the main loop from a foreign thread

### 4.1 Bottom halves (wait-free, thread-safe, signal-safe)

```c
typedef void QEMUBHFunc(void *opaque);                                    // include/qemu/aio.h:31
void aio_bh_schedule_oneshot_full(AioContext *ctx, QEMUBHFunc *cb, void *opaque, const char *name); // :372-373
#define aio_bh_schedule_oneshot(ctx, cb, opaque) \
    aio_bh_schedule_oneshot_full((ctx), (cb), (opaque), (stringify(cb)))  // :382-383
QEMUBH *aio_bh_new_full(AioContext *ctx, QEMUBHFunc *cb, void *opaque,
                        const char *name, struct MemReentrancyGuard *reentrancy_guard); // :396-397
#define aio_bh_new(ctx, cb, opaque)  aio_bh_new_full((ctx), (cb), (opaque), (stringify(cb)), NULL) // :405-406
void qemu_bh_schedule(QEMUBH *bh);     // :477
void qemu_bh_cancel(QEMUBH *bh);       // :490
void qemu_bh_delete(QEMUBH *bh);       // :503
AioContext *qemu_get_aio_context(void);                                   // include/qemu/main-loop.h:97
AioContext *iohandler_get_aio_context(void);                              // include/qemu/main-loop.h:248

/* include/qemu/main-loop.h:427-434, under "internal interfaces": */
#define qemu_bh_new_guarded(cb, opaque, guard) \
    qemu_bh_new_full((cb), (opaque), (stringify(cb)), guard)              // :429-430
#define qemu_bh_new(cb, opaque) \
    qemu_bh_new_full((cb), (opaque), (stringify(cb)), NULL)               // :431-432
QEMUBH *qemu_bh_new_full(QEMUBHFunc *cb, void *opaque, const char *name,
                         struct MemReentrancyGuard *reentrancy_guard);   // :433-434; impl util/main-loop.c:610-615 on qemu_aio_context
```
(`qemu_bh_new` is used in-tree at util/main-loop.c:177; the line at include/qemu/main-loop.h:82 is only a usage inside the `main_loop_wait` doc-comment example, not the definition.)

- Thread safety: "Bottom halves are lightweight callbacks whose invocation is guaranteed to be wait-free, thread-safe and signal-safe" (include/qemu/aio.h:388-389; also main-loop.h:66-67). `aio_bh_enqueue` is "Called concurrently from any thread" (util/async.c:73-108): atomic flag or + lock-free list insert + `aio_notify(ctx)` which sets the AioContext's EventNotifier to wake the poller (util/async.c:465-482). **No BQL is needed to schedule a BH.** (`qemu_bh_cancel` is racy without the BQL, aio.h:482-486; `qemu_bh_delete` is async and frees at the next poll, :493-503, util/async.c:250-253.)
- The one-shot variant allocates the `QEMUBH` itself and frees it after running (`BH_ONESHOT`, util/async.c:130-142, 222-224). Used in-tree from ui/console.c:172-173 to defer `qemu_console_hw_update`.
- Execution: `aio_bh_poll` (util/async.c:181-228) → `aio_bh_call` → `bh->cb(bh->opaque)` (:159-178). For `qemu_get_aio_context()` and `iohandler_get_aio_context()` this happens in the main loop's glib dispatch (§3.1), **under the BQL**. So a BH callback may directly call `qemu_console_*`, `qemu_console_set_ui_info`, input APIs, etc.
- **Before `qemu_init_main_loop`** (system/vl.c:3770), `qemu_get_aio_context()` returns NULL (util/main-loop.c:145-148) and `aio_bh_schedule_oneshot` would dereference `bh->ctx == NULL` in `aio_bh_enqueue` (util/async.c:74-98); `qemu_notify_event` silently no-ops in that state (:150-156). Not an issue from `QemuDisplay.init` (§3.4), but it is from `early_init`.

Pattern for a foreign (render/IPC) thread:
```c
/* foreign thread — no BQL */
aio_bh_schedule_oneshot(qemu_get_aio_context(), my_cb, my_state);
/* my_cb runs on the QEMU main loop with the BQL held */
```
If you want the stronger "only ever from the main loop's glib dispatch" guarantee (§3.1), create your BH on `iohandler_get_aio_context()` instead (`aio_bh_new(iohandler_get_aio_context(), cb, opaque)` during `init`, then `qemu_bh_schedule` from any thread).

### 4.2 File-descriptor handlers and event notifiers

```c
typedef void IOHandler(void *opaque);                                     // include/qemu/aio.h:33
void qemu_set_fd_handler(int fd, IOHandler *fd_read, IOHandler *fd_write, void *opaque); // include/qemu/main-loop.h:227-230
void event_notifier_set_handler(EventNotifier *e, EventNotifierHandler *handler);        // :244-245
```
Documented at include/qemu/main-loop.h:199-226: level-triggered; `fd_read` fires when readable, `fd_write` when writable; pass NULL for both to remove. Implementation (util/main-loop.c:643-651) registers on the private `iohandler_ctx` via `aio_set_fd_handler(iohandler_ctx, ...)`; `event_notifier_set_handler` likewise (:653-658). That context's GSource is attached to the default GMainContext (util/main-loop.c:183-186) so callbacks run in the main loop's glib dispatch with the BQL held, and — per the comment at util/main-loop.c:617-621 — it is by design never drained by `aio_poll(qemu_aio_context)`, so these callbacks only ever run from the main loop (a *stronger* guarantee than `qemu_get_aio_context()` BHs give, §3.1).

**Calling `qemu_set_fd_handler` itself from another thread requires the BQL** — "The lock should be taken by threads other than the main loop thread when calling `qemu_bh_new()`, `qemu_set_fd_handler()` and basically all other functions documented in this file" (include/qemu/main-loop.h:355-363). Practical rule: create BHs and fd handlers during your display `init` (main thread, BQL held, §3.4) or inside a BH; from foreign threads only *schedule* already-created BHs / one-shots, or `event_notifier_set()`.

EventNotifier API for the foreign-thread wakeup: `event_notifier_init(e, active)` / `event_notifier_cleanup(e)` / `event_notifier_set(e)` / `event_notifier_test_and_clear(e)` (include/qemu/event_notifier.h:33-36); POSIX-only `event_notifier_get_fd(e)` (:40).

### 4.3 `qemu_notify_event`

```c
void qemu_notify_event(void);   // include/qemu/main-loop.h:111
```
"forces main_loop_wait to look at pending events and exit … rarely necessary, because main loop services (bottom halves and timers) call it themselves" (main-loop.h:99-110). Implementation just schedules an internal no-op BH (util/main-loop.c:150-156 → `qemu_bh_schedule(qemu_notify_bh)`, created at :177). Scheduling any BH already wakes the loop (aio_notify), so you normally never call it yourself.

### 4.4 BQL helpers

```c
bool bql_locked(void);                                     // include/qemu/main-loop.h:271
#define bql_lock() bql_lock_impl(__FILE__, __LINE__)       // :368
void bql_unlock(void);                                     // :384
#define BQL_LOCK_GUARD() ...  /* conditional lock for the scope */ // :410-412
```
`bql_lock()` asserts the current thread does not already hold it (system/cpus.c:579), so use `BQL_LOCK_GUARD()` or the `with_bql` pattern (ui/cocoa.m:117-127) when the call site can be reached both with and without the lock. Taking the BQL from a foreign thread is legal (cocoa does it) but blocks the main loop and all vCPUs while held (main-loop.h:376-379) — prefer BHs for anything non-trivial.

---

## 5. Device-update polling, console queries, and the dbus ScanoutMap reference design

### 5.1 `qemu_console_hw_update(con)` (= old `graphic_hw_update`)

```c
void qemu_console_hw_update(QemuConsole *con)
{
    if (!con) return;
    if (!con->hw_ops->gfx_update || con->hw_ops->gfx_update(con->hw)) {
        qemu_console_hw_update_done(con);
    }
}                                                           // ui/console.c:153-161
```
Invokes the device's `GraphicHwOps.gfx_update` (include/ui/console.h:323-336; `gfx_update` "Returns true if the update is handled synchronously, false if deferred"), which is where devices scan their VRAM, possibly `qemu_console_set_surface`, and emit `qemu_console_update` for changed rows. **Call it from your `dpy_refresh`** (every in-tree backend does, see §2.5) and expect re-entry into your own switch/update callbacks (§2.4). Not calling it means devices that render lazily (VGA, bochs, ramfb) never produce updates. `qemu_console_hw_invalidate(con)` (ui/console.c:222-227) asks the device to redraw everything on its next update (use after your own resize/reconnect).

Related: `qemu_console_co_wait_update(con)` (ui/console.c:168-177, coroutine-only, used by screendump) defers a hw_update via `aio_bh_schedule_oneshot(qemu_get_aio_context(), console_hw_update_bh, con)` — an in-tree example of the §4.1 pattern.

### 5.2 Console queries

```c
int  qemu_console_get_index(QemuConsole *con);      // ui/console.c:1307-1310 — con->index, or -1 for NULL
bool qemu_console_is_graphic(QemuConsole *con);     // ui/console.c:1282-1285 — con && QEMU_IS_GRAPHIC_CONSOLE(con)
uint32_t qemu_console_get_head(QemuConsole *con);   // :1312-1321
int  qemu_console_get_width(QemuConsole *con, int fallback);   // :1323-1338 (SCANOUT_SURFACE → surface_width)
int  qemu_console_get_height(QemuConsole *con, int fallback);  // :1340-1355
DisplaySurface *qemu_console_surface(QemuConsole *con);        // :1375-1383 — NULL unless scanout.kind == SCANOUT_SURFACE
char *qemu_console_get_label(QemuConsole *con);     // :1298-1305
QEMUCursor *qemu_console_get_cursor(QemuConsole *con); // :1277-1280 — NULL for non-graphic consoles
bool qemu_console_has_gl(QemuConsole *con);         // :550-553
```
Console add/remove notifications: `qemu_console_add_notifier(Notifier *)` / `QEMU_CONSOLE_ADDED|REMOVED` (include/ui/console.h:418-434; ui/console.c:1087-1096, notified at :1159, :1176).

### 5.3 ui/dbus-listener.c shared-memory scanout (ScanoutMap) — reference design

Struct (ui/dbus-listener.c:55-94): embeds `DisplayChangeListener dcl` (:71), keeps `DisplaySurface *ds` (:72), `enum share_kind ds_share` (`SHARE_KIND_NONE/MAPPED/D3DTEX`, :49-53, :73), and `bool can_share_map` (:76) plus a `QemuDBusDisplay1ListenerUnixMap *map_proxy` (:87). Non-GL ops table:

```c
const DisplayChangeListenerOps dbus_dcl_ops = {
    .dpy_name                = "dbus",
    .dpy_gfx_update          = dbus_gfx_update,
    .dpy_gfx_switch          = dbus_gfx_switch,
    .dpy_refresh             = dbus_refresh,
    .dpy_mouse_set           = dbus_mouse_set,
    .dpy_cursor_define       = dbus_cursor_define,
};                                                  // ui/dbus-listener.c:946-953
```

Flow:
1. **Where the fd comes from — it does not create one.** `dbus_gfx_switch` just records `ddl->ds = new_surface; ddl->ds_share = SHARE_KIND_NONE;` (:876-883). The fd is `ddl->ds->share_handle`, which already exists because QEMU-allocated surfaces are memfd-backed (§1.3/§1.4) and virtio-gpu resources are also allocated with `qemu_pixman_image_new_shareable` (hw/display/virtio-gpu.c:301-309) and propagated via `qemu_displaysurface_set_share_handle(scanout->ds, res->share_handle, fb->offset)` (virtio-gpu.c:731). Surfaces wrapping foreign memory (`qemu_create_displaysurface_from` with data, e.g. VGA VRAM/ramfb/bochs) have `share_handle == SHAREABLE_NONE` and cannot be mapped.
2. **`dbus_scanout_map(ddl)`** (POSIX, :536-579): if already `SHARE_KIND_MAPPED` return true (:541-543); if `!can_share_map || ds->share_handle == SHAREABLE_NONE` return false (:545-547); otherwise append `ds->share_handle` to a `GUnixFDList` (:550-555) and call the client's `ScanoutMap(handle, offset=ds->share_handle_offset, width, height, stride, pixman_format)` synchronously (:557-570), passing `surface_width/height/stride/format(ddl->ds)`; on success `ds_share = SHARE_KIND_MAPPED` (:576). **The pixman format advertised is whatever `surface_format(ddl->ds)` is** — no conversion (the D-Bus XML documents the arg as `pixman_format` "ex: PIXMAN_X8R8G8B8", ui/dbus-display1.xml:480-499). The Windows variant (:418-468) duplicates the file-mapping HANDLE into the peer process instead.
3. **Update signalling — `dbus_gfx_update`** (:822-853): if `dbus_scanout_map()` succeeds → send only the rectangle `UpdateMap(x, y, w, h)` (:839-845; XML :501-515 "Update the display content with the current shared map and the given region"). **Zero copy: the client mmaps the fd once and just re-reads the rect.** Fallback when mapping is unavailable: full-frame → `Scanout(width,height,stride,format, data)` with the whole buffer as a GVariant referencing the pixman image (`ddl_scanout`, :805-820); partial → copy the rect into a temporary pixman image and send `Update(...)` (`dbus_gfx_update_sub`, :763-803).
4. **Client capability negotiation**: `dbus_display_listener_setup_shared_map` checks whether the peer implements `org.qemu.Display1.Listener.Unix.Map` and creates the proxy, setting `can_share_map = true` (:1105-1148). Any failure flips `can_share_map = false` and falls back to copying (:552-554, :571-573).
5. **Refresh**: `dbus_refresh` just calls `qemu_console_hw_update(dcl->con)` (:741-744).
6. Old-frame message discarding: on re-scanout the listener bumps a serial so stale `Scanout/Update/ScanoutMap/UpdateMap` messages still queued in GDBus are dropped by a filter (`ddl_discard_display_messages`, :101-107; `dbus_filter`, :1184-1238) — relevant if you build an async IPC and want "latest frame wins".

Design takeaways for a custom zero-copy backend: (a) in `dpy_gfx_switch`, read `surface->share_handle`/`share_handle_offset`/`surface_stride`/`surface_format`/`surface_width`/`surface_height` and hand the fd (dup it — the pixman destroy function closes the original when the surface dies, ui/qemu-pixman.c:298, util/memfd.c:158-161) to your consumer, keyed on `(fd, offset)` (§2.4); (b) in `dpy_gfx_update`, transmit only the damage rect (guarding `w <= 0 || h <= 0`, §2.3); (c) if `share_handle == SHAREABLE_NONE`, fall back to copying from `surface_data()` and remember that memory is device-owned (§1.3, §1.6); (d) you cannot force devices to give you a shareable surface, but VGA will allocate one (memfd-backed, `x8r8g8b8`) if your `dpy_gfx_check_format` rejects its native VRAM format (vga.c:1628-1634 → :1670 `qemu_console_resize` → `qemu_create_displaysurface`).

---

## 6. `qemu_console_set_ui_info(con, info, delay)` (= old `dpy_set_ui_info`)

### 6.1 Struct and API

```c
typedef struct QemuUIInfo {
    /* physical dimension */
    uint16_t width_mm;
    uint16_t height_mm;
    /* geometry */
    int       xoff;
    int       yoff;
    uint32_t  width;
    uint32_t  height;
    uint32_t  refresh_rate;
} QemuUIInfo;                                         // include/ui/console.h:108-118

bool qemu_console_ui_info_supported(const QemuConsole *con);              // ui/console.c:693-700 — con && con->hw_ops->ui_info != NULL
const QemuUIInfo *qemu_console_get_ui_info(const QemuConsole *con);       // :702-707 (asserts supported)
int  qemu_console_set_ui_info(QemuConsole *con, QemuUIInfo *info, bool delay); // :709-728
```

`qemu_console_set_ui_info` (ui/console.c:709-728): returns -1 if the device has no `ui_info` op (:711-713); returns 0 without action if `memcmp` finds no change (:714-717); otherwise stores `con->ui_info = *info` and arms `con->ui_timer` for `now + (delay ? 1000 : 0)` ms ("Typically we get a flood of these as the user resizes the window. Wait until the dust has settled (one second without updates), then go notify the guest." :719-723). The timer callback `dpy_set_ui_info_timer` calls `con->hw_ops->ui_info(con->hw, head, &con->ui_info)` (:685-691; timer created per console at :458-459).

**Zero-initialise `QemuUIInfo`.** Because the comparison is a `memcmp` over the whole struct (:714), uninitialised fields defeat the "nothing changed" short-circuit and re-arm the 1 s timer on every call. Cocoa declares `QemuUIInfo info;` and only sets `refresh_rate` inside a conditional (ui/cocoa.m:528, 547-551) — do not copy that. Use `QemuUIInfo info = { ... }` as vnc (ui/vnc.c:2641), sdl2 (ui/sdl2.c:605-608) and dbus (ui/dbus-console.c:198-205) do, or start from `*qemu_console_get_ui_info(con)` as gtk does — but check `qemu_console_ui_info_supported` first, because `qemu_console_get_ui_info` asserts support (:702-707; gtk pattern ui/gtk.c:751-758).

`refresh_rate` unit: cocoa passes an integer Hz value (`1000 * timeScale / timeValue`, ui/cocoa.m:550); virtio-gpu passes it straight into the EDID and xenfb treats it as Hz (hw/display/xenfb.c:767-773 "T = 1 / f"). Callers in tree: ui/cocoa.m:567 (delay=TRUE), ui/gtk.c:744/758 (TRUE), ui/sdl2.c:609 (TRUE), ui/vnc.c:2642 (false), ui/spice-display.c:695 (false), ui/dbus-console.c:215 (false, from the D-Bus `SetUIInfo` method).

### 6.2 Devices that honor `ui_info` (grep hw/display for `.ui_info`)

- **virtio-gpu** (all variants: virtio-gpu-device/pci/gl/rutabaga share `virtio_gpu_ops`): `.ui_info = virtio_gpu_ui_info` (hw/display/virtio-gpu-base.c:172-179). `virtio_gpu_ui_info` (:101-125) copies `xoff/yoff/refresh_rate/width/height/width_mm/height_mm` into `g->req_state[idx]` (struct `virtio_gpu_requested_state`, include/hw/virtio/virtio-gpu.h:86-91), sets/clears bit `idx` of `enabled_output_bitmask` depending on `width && height` (:117-121), and raises `VIRTIO_GPU_EVENT_DISPLAY` via a config-space interrupt (:123-124, `virtio_gpu_notify_event` :95-99). Ignored if `idx >= conf.max_outputs` (:105-107).
- **virtio-vga** forwards to the embedded virtio-gpu (`virtio_vga_base_ui_info`, hw/display/virtio-vga.c:50-58, ops :78-85).
- **xenfb**: `.ui_info = xenfb_ui_info` (hw/display/xenfb.c:756-776, ops :970) — only uses `refresh_rate` to send a refresh-period message; does **not** resize.
- **ramfb**: NOT FOUND — `wrapper_ops` has only `.gfx_update` (hw/display/ramfb-standalone.c:36-38). **VGA**: `vga_ops = { .invalidate, .gfx_update, .text_update }` (hw/display/vga.c:2195-2199), no `.ui_info`. **bochs-display**: `{ .gfx_update }` only (hw/display/bochs-display.c:260-262). **qxl**: `qxl_ops = { .gfx_update = qxl_hw_update }` (hw/display/qxl.c:1145-1147), used for both the primary and secondary consoles (:2241, :2266). For these, `qemu_console_set_ui_info` returns -1 and window resize can only scale.

### 6.3 What the guest needs for a resize request to take effect (virtio-gpu)

The host never resizes the guest framebuffer; it only *advertises* a preferred mode and pokes the guest:

1. `VIRTIO_GPU_EVENT_DISPLAY` config interrupt (hw/display/virtio-gpu-base.c:124) → guest driver re-queries.
2. `VIRTIO_GPU_CMD_GET_DISPLAY_INFO` → `virtio_gpu_get_display_info` (hw/display/virtio-gpu.c:195-206) → `virtio_gpu_base_fill_display_info` reports `enabled` + `r.width/r.height` from `req_state[i]` for each output whose bit is set in `enabled_output_bitmask` (virtio-gpu-base.c:41-54). Output 0 is enabled at realize with `xres`/`yres` properties as the initial request (:198-201; per-output `outputs[n].xres/yres` :221-225).
3. `VIRTIO_GPU_CMD_GET_EDID` (only if the guest negotiated `VIRTIO_GPU_F_EDID`, offered when the `edid` property is on — default **true**, include/hw/virtio/virtio-gpu.h:176-177, feature bit set at virtio-gpu-base.c:267-269) → `virtio_gpu_get_edid` (virtio-gpu.c:208-228) → `virtio_gpu_base_generate_edid` builds a `qemu_edid_info { width_mm, height_mm, prefx = width, prefy = height, refresh_rate, name }` from `req_state[scanout]` and calls `qemu_edid_generate` (virtio-gpu-base.c:56-80; struct at include/hw/display/edid.h:6-17). This is how `width_mm/height_mm` (DPI) and `refresh_rate` reach the guest.
4. **[external — guest-driver behaviour, not verifiable in this tree]** The guest's KMS driver (Linux `virtio_gpu`, Windows viogpu) then does a modeset: allocates a new resource, `SET_SCANOUT`, `RESOURCE_FLUSH`. On the QEMU side those commands become `qemu_console_set_surface` (virtio-gpu.c:709-736) → your `dpy_gfx_switch`, then `qemu_console_update` → your `dpy_gfx_update` (:596-597). If the guest has no virtio-gpu driver loaded (firmware/ramfb stage) or ignores hotplug events, nothing happens.

Cocoa's `updateUIInfoLocked` is the host-side example: fill `width/height` in backing pixels (`frame.size * backingScaleFactor`), `width_mm/height_mm` from the screen's physical size, `refresh_rate` from the display link, `xoff/yoff = 0`, and call `qemu_console_set_ui_info(dcl.con, &info, TRUE)` (ui/cocoa.m:524-568; must be called with BQL — comment at :526, wrapper at :586-588) — but zero-initialise the struct (§6.1).

---

## Appendix A — Minimal non-GL DCL skeleton consistent with the above

```c
#include "qemu/osdep.h"
#include "qemu/main-loop.h"
#include "ui/console.h"          /* pulls in ui/surface.h, ui/qemu-pixman.h */
#include "qemu-main.h"

typedef struct MyDpy { DisplayChangeListener dcl; DisplaySurface *ds; /* … */ } MyDpy;

static void my_gfx_switch(DisplayChangeListener *dcl, DisplaySurface *new_surface)
{
    MyDpy *d = container_of(dcl, MyDpy, dcl);
    d->ds = new_surface;                        /* old surface is freed when we return: ui/console.c:798 */
    /* new_surface->share_handle (memfd, may be SHAREABLE_NONE) / share_handle_offset / stride / format;
     * may be re-entered from inside my_refresh (§2.4); same fd may arrive with a new offset (§2.4). */
}
static void my_gfx_update(DisplayChangeListener *dcl, int x, int y, int w, int h)
{
    if (w <= 0 || h <= 0) return;               /* ui/console.c:737-742 can produce empty rects */
    /* read rect from surface_data(d->ds) + y*surface_stride + x*surface_bytes_per_pixel */
}
static void my_refresh(DisplayChangeListener *dcl)
{   qemu_console_hw_update(dcl->con); }        /* every ~30 ms (GUI_REFRESH_INTERVAL_DEFAULT) or dcl->update_interval */
static const DisplayChangeListenerOps my_ops = {
    .dpy_name = "mine", .dpy_gfx_update = my_gfx_update, .dpy_gfx_switch = my_gfx_switch,
    .dpy_refresh = my_refresh, .dpy_gfx_check_format = qemu_pixman_check_format,
    .dpy_mouse_set = …, .dpy_cursor_define = …,   /* cursor words are 0xAARRGGBB native-endian (§2.7) */
};
static void my_init(DisplayState *ds, DisplayOptions *opts)
{
    static MyDpy d;
    d.dcl.update_interval = 16;                 /* set BEFORE registering; qemu_console_listener_set_refresh()
                                                 * is only legal AFTER registration (ui/console.c:653-662) */
    /* con == NULL is tolerated but leaves you on a dummy surface; a GL-only console is fatal (§2.2) */
    qemu_console_register_listener(qemu_console_lookup_default(), &d.dcl, &my_ops);
    /* BQL is held here (§3.4): safe to aio_bh_new()/qemu_set_fd_handler() now */
    /* leave qemu_main alone (macOS: QEMU loop stays on a secondary thread) or set qemu_main = NULL */
}
static QemuDisplay qemu_display_mine = { .type = DISPLAY_TYPE_…, .init = my_init, .cleanup = … };
/* register via qemu_display_register() in a type_init (cf. ui/cocoa.m:2055-2066); DISPLAY_TYPE_… must exist in qapi/ui.json:1522-1534 */
```
From a foreign thread: `aio_bh_schedule_oneshot(qemu_get_aio_context(), cb, opaque);` — `cb` runs on the QEMU main loop with the BQL held and may call any `qemu_console_*` function. For a `QemuUIInfo` request, zero-initialise the struct and pass `delay=true` from UI resize paths (§6.1).

---

## Appendix B — Revision log (what changed vs. the previous draft, all re-verified against source)

- §3.1/§4.2: virtio-gpu BHs run on `iohandler_ctx` (hw/virtio/virtio.c:4735), not `qemu_get_aio_context()`; added the stronger main-loop-only guarantee for that context (util/main-loop.c:617-621) and the `aio_poll` mechanism cite (util/aio-posix.c:652, :745).
- §2.2/§2.3/§2.4: registration full-update is ui/console.c:293-294 (not :304-305); post-switch update after `qemu_console_set_surface` happens only for `surface == NULL` (:795); incompatible console is fatal via `&error_fatal` (:644, util/error.c:39-42), dummy path is :281-289 and only for `con == NULL`; added `qemu_console_resize` texture/dmabuf no-op branch (:1363-1369), empty-rect clamp (:737-742), re-entrancy, same-fd/different-offset, and `con == NULL` consequences.
- §4.1: `qemu_bh_new` definition is include/qemu/main-loop.h:431-432 (:82 is a doc example); added pre-`qemu_init_main_loop` NULL-context hazard.
- §1.5: `PIXMAN_x8r8g8b8` layout cited via ui/vnc.h:598-599 + ui/vnc.c:869-872 + ui/qemu-pixman.c:28-33; the enum identity and the Metal claim marked external; cocoa framebuffer `CGImage` cite added (ui/cocoa.m:416-428).
- §1.3/§1.6: distinguished memfd-owned pixels (destroy function, ui/qemu-pixman.c:347-349) from device-owned VRAM wrapped without one (ui/display-surface.c:44-47); added who-writes-when.
- §2.1: restored all `/* optional */` and `/* required if GL */` comments verbatim (include/ui/console.h:167-230).
- §2.5: `qemu_console_listener_set_refresh` after-registration constraint (ui/console.c:653-662, :641, :140-143).
- §2.7: cursor word convention corrected to native-endian ARGB with producer/consumer cites; gtk and XPM exceptions noted; non-atomic refcount and 512x512 limit added.
- §3.4/§3.5: added init timing (vl.c:1377-1393, 2697-2703, 3770, 3861-3864; BQL taken in system/runstate.c:982) and `-display` plumbing (qapi/ui.json:1522-1534, 1556-1572; ui/meson.build:73, 93-200).
- §6.1/§6.2: `QemuUIInfo` zero-init requirement; qxl/vga/bochs `GraphicHwOps` cites (hw/display/qxl.c:1145-1147, :2241, :2266; vga.c:2195-2199; bochs-display.c:260-262).
- §6.3: guest KMS-driver step marked external.


## Open questions
- §3.1: the source comment at include/qemu/main-loop.h:317-319 says any BQL holder can act as the main thread for qemu_aio_context; whether any non-display QEMU subsystem in practice aio_poll()s qemu_aio_context from a vCPU/RCU thread while a display BH is pending was not exhaustively searched — the safe assumption remains 'BQL held, thread unspecified' for qemu_get_aio_context() BHs and 'main-loop thread' for iohandler_ctx.
- §1.5: the equality PIXMAN_x8r8g8b8 == PIXMAN_FORMAT(32, PIXMAN_TYPE_ARGB, 0, 8, 8, 8) and the Metal BGRA8Unorm correspondence come from outside the tree (<pixman.h>, Metal docs) and were not verified here.
- §6.3 step 4 (guest KMS driver issuing SET_SCANOUT/RESOURCE_FLUSH after a display-info change) describes guest-driver behaviour that cannot be verified from this QEMU tree.
