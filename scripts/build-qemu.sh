#!/bin/bash
# Build the Alcove QEMU engine: pinned upstream tag + qemu-patches/*.patch.
# Usage: scripts/build-qemu.sh [--clean] [--install]
# Result: build/qemu-build/qemu-system-aarch64 (signed with the hypervisor
# entitlement by QEMU's own build, scripts/entitlement.sh) and
# build/qemu-install/ on --install.
# Env: QEMU_TAG, QEMU_GIT, PYTHON, JOBS, ALCOVE_CONFIGURE_EXTRA.
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

# libpng: QMP `screendump` defaults to PNG (install-windows.py, AlcoveQMP).
PKGS="meson pkgconf ninja glib pixman dtc libslirp capstone libusb zstd libpng"
installed="$(brew list --versions $PKGS || true)"
for pkg in $PKGS; do
  grep -q "^$pkg " <<<"$installed" || { echo "missing brew package: $pkg (brew install $pkg)" >&2; exit 1; }
done

mkdir -p "$ROOT/build"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 -b "$QEMU_TAG" "$QEMU_GIT" "$SRC"
fi

# --- Source tree: make it exactly $QEMU_TAG + qemu-patches/*.patch. ---------
# Three tree ids decide what to do, all computed in throwaway index files so
# nothing here touches the working tree:
#   head_tree     pristine HEAD
#   patched_tree  HEAD with the patch series applied
#   work_tree     what build/qemu-src holds right now (tracked + untracked)
# A tree equal to patched_tree is left alone (no gratuitous rebuild); anything
# else is reset to pristine and re-patched. A tree that holds the patch series
# of an earlier commit of this repository (one that changed qemu-patches/) is
# named by that commit. Other in-tree edits are saved to
# build/qemu-src-discarded-<time>.diff first, so nothing is lost silently.
# (`git checkout -- .` is not enough to undo an earlier `git apply --index`:
# it restores from the index, which still holds the patch, so the next apply
# fails with "already exists in index".)
shopt -s nullglob
work_index="$SRC/.git/alcove-work-index"
patch_index="$SRC/.git/alcove-patch-index"
earlier_index="$SRC/.git/alcove-earlier-index"
trap 'rm -f "$work_index" "$patch_index" "$earlier_index"' EXIT
rm -f "$work_index" "$patch_index" "$earlier_index"
head_tree="$(git -C "$SRC" rev-parse 'HEAD^{tree}')"

GIT_INDEX_FILE="$work_index" git -C "$SRC" read-tree HEAD
GIT_INDEX_FILE="$work_index" git -C "$SRC" add -A
work_tree="$(GIT_INDEX_FILE="$work_index" git -C "$SRC" write-tree)"

GIT_INDEX_FILE="$patch_index" git -C "$SRC" read-tree HEAD
patched_tree=""
if ( for p in "$ROOT"/qemu-patches/*.patch; do
       GIT_INDEX_FILE="$patch_index" git -C "$SRC" apply --cached "$p" 2>/dev/null || exit 1
     done ); then
  patched_tree="$(GIT_INDEX_FILE="$patch_index" git -C "$SRC" write-tree)"
fi

# The commit of this repository, among those that changed qemu-patches/, whose
# patch series applied to HEAD gives work_tree, as "<short hash> <subject>";
# empty when there is none or $ROOT is not a git checkout.
earlier_series_commit() {
  git -C "$ROOT" rev-parse -q --verify HEAD >/dev/null 2>&1 || return 0
  local commit name
  for commit in $(git -C "$ROOT" log --format=%H -- qemu-patches); do
    GIT_INDEX_FILE="$earlier_index" git -C "$SRC" read-tree HEAD
    if ( for name in $(git -C "$ROOT" ls-tree --name-only "$commit" -- qemu-patches/ | grep '\.patch$'); do
           git -C "$ROOT" show "$commit:$name" | GIT_INDEX_FILE="$earlier_index" git -C "$SRC" apply --cached - 2>/dev/null || exit 1
         done ) \
       && [ "$(GIT_INDEX_FILE="$earlier_index" git -C "$SRC" write-tree)" = "$work_tree" ]; then
      git -C "$ROOT" log -1 --format='%h %s' "$commit"
      return 0
    fi
  done
}

# Honor QEMU_TAG on an existing clone (fetch the tag if this shallow clone lacks it).
if ! git -C "$SRC" rev-parse -q --verify "refs/tags/$QEMU_TAG^{commit}" >/dev/null; then
  git -C "$SRC" fetch -q --depth 1 origin tag "$QEMU_TAG"
fi
target="$(git -C "$SRC" rev-parse "refs/tags/$QEMU_TAG^{commit}")"
head="$(git -C "$SRC" rev-parse HEAD)"

if [ "$head" = "$target" ] && [ -n "$patched_tree" ] && [ "$work_tree" = "$patched_tree" ]; then
  echo "source tree already at $QEMU_TAG + patches; leaving it untouched"
else
  if [ "$work_tree" != "$head_tree" ] && [ "$work_tree" != "$patched_tree" ]; then
    earlier="$(earlier_series_commit)"
    if [ -n "$earlier" ]; then
      echo "build/qemu-src holds qemu-patches/*.patch of commit $earlier; applying the current patch series"
    else
      work_diff="$ROOT/build/qemu-src-discarded-$(date +%Y%m%d-%H%M%S).diff"
      GIT_INDEX_FILE="$work_index" git -C "$SRC" diff --cached HEAD > "$work_diff"
      echo "build/qemu-src had edits that are not exactly qemu-patches/*.patch; saved to $work_diff:" >&2
      git -C "$SRC" status --short >&2
    fi
  fi
  git -C "$SRC" reset -q --hard
  git -C "$SRC" clean -qfd
  if [ "$head" != "$target" ]; then
    echo "checking out $QEMU_TAG"
    git -C "$SRC" checkout -q --detach "$target"
  fi
  if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
    echo "source tree is not pristine after reset:" >&2
    git -C "$SRC" status --short >&2
    exit 1
  fi
  for p in "$ROOT"/qemu-patches/*.patch; do
    echo "applying $(basename "$p")"
    git -C "$SRC" apply --index "$p"
  done
fi
rm -f "$work_index" "$patch_index" "$earlier_index"
shopt -u nullglob

if [ "$CLEAN" = 1 ]; then rm -rf "$BLD"; fi
mkdir -p "$BLD"
# --disable-pvg (in the configure call below): the engine is built without the apple-gfx devices.
if [ ! -f "$BLD/build.ninja" ]; then
  ( cd "$BLD" && "$SRC/configure" \
      --python="$PYTHON" \
      --target-list=aarch64-softmmu \
      --prefix="$PREFIX" \
      --extra-cflags="-I$BREW/include" \
      --extra-ldflags="-L$BREW/lib" \
      --enable-hvf --enable-cocoa --enable-slirp --enable-libusb --enable-tpm \
      --enable-virtfs --enable-fdt=system --enable-capstone --enable-zstd --enable-vnc \
      --enable-png \
      --disable-gtk --disable-sdl --disable-docs --disable-guest-agent --disable-werror \
      --disable-pvg \
      -Dalcove=enabled \
      ${ALCOVE_CONFIGURE_EXTRA:-} )
fi
ninja -C "$BLD" -j "$JOBS"
if [ "$INSTALL" = 1 ]; then ninja -C "$BLD" install; fi
"$BLD/qemu-system-aarch64" --version | head -1
codesign -d --entitlements - "$BLD/qemu-system-aarch64" 2>&1 | grep -q com.apple.security.hypervisor \
  || { echo "hypervisor entitlement missing on $BLD/qemu-system-aarch64" >&2; exit 1; }
echo "hypervisor entitlement: ok"
