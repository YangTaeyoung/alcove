#!/bin/bash
# SP0 spike: boot the Ubuntu noble arm64 cloud image headless under HVF and
# wait for the login prompt on the serial console. Exit 0 on success.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
QEMU="$ROOT/build/qemu-build/qemu-system-aarch64"
QIMG="$ROOT/build/qemu-build/qemu-img"
FW="$ROOT/build/qemu-build/pc-bios/edk2-aarch64-code.fd"
IMG="$ROOT/images/noble-server-cloudimg-arm64.img"
WORK="$ROOT/build/test-ubuntu"; mkdir -p "$WORK"
TIMEOUT="${TIMEOUT:-180}"

[ -x "$QEMU" ] || { echo "build QEMU first (scripts/build-qemu.sh)"; exit 1; }
[ -f "$IMG" ] || { echo "missing $IMG"; exit 1; }

# fresh overlay so the base image stays pristine
rm -f "$WORK/disk.qcow2" "$WORK/serial.log" "$WORK/efi-vars.fd"
"$QIMG" create -q -f qcow2 -b "$IMG" -F qcow2 "$WORK/disk.qcow2" 8G
dd if=/dev/zero of="$WORK/efi-vars.fd" bs=1m count=64 status=none

# cloud-init NoCloud seed: user alcove / password alcove
mkdir -p "$WORK/seed"
cat > "$WORK/seed/user-data" <<'YAML'
#cloud-config
users:
  - name: alcove
    plain_text_passwd: alcove
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
ssh_pwauth: true
YAML
printf 'instance-id: alcove-spike\nlocal-hostname: alcove-spike\n' > "$WORK/seed/meta-data"
rm -f "$WORK/seed.iso"
hdiutil makehybrid -quiet -iso -joliet -default-volume-name cidata -o "$WORK/seed.iso" "$WORK/seed"

"$QEMU" \
  -accel hvf -M virt -cpu host -smp 4 -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file="$FW" \
  -drive if=pflash,format=raw,file="$WORK/efi-vars.fd" \
  -drive if=none,id=disk0,format=qcow2,file="$WORK/disk.qcow2" \
  -device virtio-blk-pci,drive=disk0 \
  -drive if=none,id=seed,format=raw,readonly=on,file="$WORK/seed.iso" \
  -device virtio-blk-pci,drive=seed \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -display none -serial file:"$WORK/serial.log" -monitor none \
  -pidfile "$WORK/qemu.pid" -daemonize
trap 'kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true' EXIT

for i in $(seq 1 "$TIMEOUT"); do
  if grep -q "alcove-spike login:" "$WORK/serial.log" 2>/dev/null; then
    echo "PASS: login prompt after ${i}s"; grep -m1 "Linux version" "$WORK/serial.log" || true; exit 0
  fi
  sleep 1
done
echo "FAIL: no login prompt within ${TIMEOUT}s"; tail -20 "$WORK/serial.log"; exit 1
