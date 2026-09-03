#!/bin/bash
# Build the Alcove QEMU engine: pinned upstream tag + qemu-patches/*.patch.
# Usage: scripts/build-qemu.sh [--clean] [--install]
# Result: build/qemu-build/qemu-system-aarch64 (signed with the hypervisor
# entitlement by QEMU's own install step) and build/qemu-install/ on --install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU_TAG="${QEMU_TAG:-v11.1.1}"
QEMU_GIT="${QEMU_GIT:-https://gitlab.com/qemu-project/qemu.git}"
SRC="$ROOT/build/qemu-src"
BLD="$ROOT/build/qemu-build"
PREFIX="$ROOT/build/qemu-install"
BREW="$(brew --prefix)"
PYTHON="${PYTHON:-$BREW/bin/python3}"   # needs Python >= 3.11 (tomllib)
JOBS="${JOBS:-$(( $(sysctl -n hw.ncpu) - 2 ))}"

CLEAN=0; INSTALL=0
for a in "$@"; do case "$a" in --clean) CLEAN=1;; --install) INSTALL=1;; *) echo "unknown arg $a" >&2; exit 2;; esac; done

for pkg in meson pkgconf ninja glib pixman dtc libslirp capstone libusb zstd; do
  brew list --versions "$pkg" >/dev/null 2>&1 || { echo "missing brew package: $pkg (brew install $pkg)" >&2; exit 1; }
done

mkdir -p "$ROOT/build"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 -b "$QEMU_TAG" "$QEMU_GIT" "$SRC"
fi

# Re-apply the patch series from a pristine tree every time so the result is reproducible.
git -C "$SRC" checkout -q -- . && git -C "$SRC" clean -qfd
shopt -s nullglob
for p in "$ROOT"/qemu-patches/*.patch; do
  echo "applying $(basename "$p")"
  git -C "$SRC" apply --index "$p"
done
shopt -u nullglob

if [ "$CLEAN" = 1 ]; then rm -rf "$BLD"; fi
mkdir -p "$BLD"
if [ ! -f "$BLD/build.ninja" ]; then
  ( cd "$BLD" && "$SRC/configure" \
      --python="$PYTHON" \
      --target-list=aarch64-softmmu \
      --prefix="$PREFIX" \
      --extra-cflags="-I$BREW/include" \
      --extra-ldflags="-L$BREW/lib" \
      --enable-hvf --enable-cocoa --enable-slirp --enable-libusb --enable-tpm \
      --enable-virtfs --enable-fdt=system --enable-capstone --enable-zstd --enable-vnc \
      --disable-gtk --disable-sdl --disable-docs --disable-guest-agent --disable-werror \
      ${ALCOVE_CONFIGURE_EXTRA:-} )
fi
ninja -C "$BLD" -j "$JOBS"
if [ "$INSTALL" = 1 ]; then ninja -C "$BLD" install; fi
"$BLD/qemu-system-aarch64" --version | head -1
codesign -d --entitlements - "$BLD/qemu-system-aarch64" 2>&1 | grep -q com.apple.security.hypervisor && echo "hypervisor entitlement: ok"
