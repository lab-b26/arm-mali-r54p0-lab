#!/usr/bin/env bash
set -euo pipefail

# Arm GPU Bug Bounty x86 "Simulated Platform Device" bootstrap.
# Based on Arm's 20250623-1.0 Virtual Platform How-To Guide and the supplied
# patches_for_virtual_device.zip. The Mali driver tarball itself must be
# downloaded by the user from Arm's official download page and passed in.
#
# Concrete kernel choice for this implementation: Linux 6.12.111 LTS.
# Arm's Device Configuration Guidelines do not pin an exact kernel release;
# they recommend the latest stable/LTS for a new virtual environment.

ROOT="${ROOT:-$HOME/arm-r54p0-x86-lab}"
KVER="${KVER:-6.12.111}"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz"
MALI_TARBALL="${MALI_TARBALL:-}"
PATCH_ZIP="${PATCH_ZIP:-}"

usage() {
    cat <<USAGE
Usage:
  MALI_TARBALL=/path/to/AX504X08X-SW-99002-r54p0-01eac0.tar.gz \
  PATCH_ZIP=/path/to/patches_for_virtual_device.zip \
  $0

Optional:
  ROOT=$HOME/arm-r54p0-x86-lab
  KVER=6.12.111

The script builds:
  - x86_64 Linux kernel
  - Arm Mali 5th Gen Kbase r54p0 as mali_kbase.ko
  - minimal BusyBox initramfs with mali_kbase.ko

It does not download the proprietary/Arm driver source automatically.
You must obtain it from Arm's official download page and accept Arm's EULA.
USAGE
}

[[ -n "$MALI_TARBALL" && -n "$PATCH_ZIP" ]] || { usage; exit 2; }
[[ -f "$MALI_TARBALL" ]] || { echo "ERROR: missing MALI_TARBALL: $MALI_TARBALL" >&2; exit 1; }
[[ -f "$PATCH_ZIP" ]] || { echo "ERROR: missing PATCH_ZIP: $PATCH_ZIP" >&2; exit 1; }

for cmd in gcc make flex bison bc cpio gzip xz patch unzip busybox; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    }
done

mkdir -p "$ROOT"/{src,build,artifacts,work}

# 1) Linux source
if [[ ! -d "$ROOT/src/linux-${KVER}" ]]; then
    mkdir -p "$ROOT/work/kernel-download"
    if [[ ! -f "$ROOT/work/kernel-download/linux-${KVER}.tar.xz" ]]; then
        echo "[+] Downloading Linux ${KVER} ..."
        curl -L --fail --retry 3 -o \
            "$ROOT/work/kernel-download/linux-${KVER}.tar.xz" \
            "$KERNEL_URL"
    fi
    tar -xJf "$ROOT/work/kernel-download/linux-${KVER}.tar.xz" -C "$ROOT/src"
fi
KDIR="$ROOT/src/linux-${KVER}"

# 2) Unpack the Arm r54p0 source and locate driver/product/kernel.
rm -rf "$ROOT/work/mali-src" "$ROOT/work/patches"
mkdir -p "$ROOT/work/mali-src" "$ROOT/work/patches"
tar -xf "$MALI_TARBALL" -C "$ROOT/work/mali-src"
MALI_KERNEL_DIR="$(find "$ROOT/work/mali-src" -type d -path '*/driver/product/kernel' -print -quit)"
[[ -n "$MALI_KERNEL_DIR" ]] || {
    echo "ERROR: could not find */driver/product/kernel inside r54p0 tarball" >&2
    exit 1
}
MALI_DIR="$(dirname "$(dirname "$(dirname "$MALI_KERNEL_DIR")")")"

echo "[+] KDIR=$KDIR"
echo "[+] MALI_DIR=$MALI_DIR"
echo "[+] MALI_KERNEL_DIR=$MALI_KERNEL_DIR"

grep -R "MALI_RELEASE_NAME" -n "$MALI_KERNEL_DIR/drivers/gpu/arm/midgard/Kbuild" | head -3 || true

# 3) Arm's in-tree integration instructions.
echo "[+] Copying Kbase into kernel tree ..."
cp -a "$MALI_KERNEL_DIR"/* "$KDIR"/

cd "$KDIR"
printf '%s\n' 'obj-$(CONFIG_MALI_MIDGARD) += arm/' >> drivers/gpu/Makefile
# Match Arm's documented insertion at the end of drivers/video/Kconfig.
sed -i '$i source "drivers/gpu/arm/Kconfig"' drivers/video/Kconfig

# 4) Arm's supplied x86 patches.
echo "[+] Applying Arm virtual-device patches ..."
unzip -q "$PATCH_ZIP" -d "$ROOT/work/patches"
shopt -s nullglob
patches=("$ROOT/work/patches"/*.patch)
[[ "${#patches[@]}" -eq 6 ]] || {
    echo "ERROR: expected 6 patches, found ${#patches[@]}" >&2
    exit 1
}
for patch_file in "${patches[@]}"; do
    echo "  - $(basename "$patch_file")"
    # This is Arm's documented -p3 invocation.
    patch -p3 -i "$patch_file"
done
shopt -u nullglob

# 5) Kernel config: x86_64, non-DT, Mali r54p0 dummy model.
# Start from the normal x86_64 defconfig, then set Arm's Mali options.
make O="$ROOT/build" x86_64_defconfig

"$KDIR/scripts/config" --file "$ROOT/build/.config" \
    --disable OF \
    --enable MODULES \
    --enable BLK_DEV_INITRD \
    --enable DEVTMPFS \
    --enable DEVTMPFS_MOUNT \
    --enable SERIAL_8250 \
    --enable SERIAL_8250_CONSOLE \
    --enable VIRTIO \
    --enable VIRTIO_PCI \
    --enable VIRTIO_BLK \
    --enable EXT4_FS \
    --module MALI_MIDGARD \
    --enable MALI_CSF_SUPPORT \
    --enable MALI_EXPERT \
    --enable MALI_NO_MALI \
    --disable MALI_REAL_HW \
    --set-str MALI_NO_MALI_DEFAULT_GPU tKRx \
    --set-str MALI_PLATFORM_NAME vexpress

# Arm requires DEBUG=n for bounty configurations. Keep it off here too.
"$KDIR/scripts/config" --file "$ROOT/build/.config" --disable MALI_DEBUG

# Keep instrumentation OFF in the base build. For fuzzing, use a separate
# investigation configuration and do not treat it as the submission build.
"$KDIR/scripts/config" --file "$ROOT/build/.config" \
    --disable KASAN \
    --disable UBSAN \
    --disable KCOV

make O="$ROOT/build" olddefconfig

# Sanity checks.
echo "[+] Selected Mali configuration:"
grep -E '^(CONFIG_MALI_(MIDGARD|CSF_SUPPORT|EXPERT|NO_MALI|NO_MALI_DEFAULT_GPU|PLATFORM_NAME)=|# CONFIG_MALI_(REAL_HW|DEBUG|OF) is not set)' \
    "$ROOT/build/.config" || true

echo "[+] CONFIG_LARGE_PAGE_SUPPORT:"
grep -E '^CONFIG_LARGE_PAGE_SUPPORT=' "$ROOT/build/.config" || true

# 6) Build kernel + modules.
echo "[+] Building kernel and Mali module ..."
make -C "$KDIR" O="$ROOT/build" -j"$(nproc)" bzImage modules

MALI_KO="$(find "$ROOT/build" -type f -name mali_kbase.ko -print -quit)"
[[ -n "$MALI_KO" ]] || { echo "ERROR: mali_kbase.ko was not produced" >&2; exit 1; }
cp "$MALI_KO" "$ROOT/artifacts/mali_kbase.ko"
cp "$ROOT/build/arch/x86/boot/bzImage" "$ROOT/artifacts/bzImage"
cp "$ROOT/build/vmlinux" "$ROOT/artifacts/vmlinux"
cp "$ROOT/build/.config" "$ROOT/artifacts/kernel.config"

# 7) Minimal initramfs, sufficient for driver bring-up.
RFS="$ROOT/work/rootfs"
rm -rf "$RFS"
mkdir -p "$RFS"/{bin,dev,etc,proc,sys,tmp}
BUSYBOX_BIN="$(command -v busybox)"
cp "$BUSYBOX_BIN" "$RFS/bin/busybox"
chmod 0755 "$RFS/bin/busybox"
for app in sh mount umount ls cat echo dmesg insmod rmmod sleep grep mkdir uname id ps; do
    ln -sf busybox "$RFS/bin/$app"
done
cp "$ROOT/artifacts/mali_kbase.ko" "$RFS/mali_kbase.ko"
cat > "$RFS/init" <<'INIT'
#!/bin/sh

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

printf '\n=== Arm Mali r54p0 x86 virtual lab ===\n'
uname -a
printf '\n--- loading mali_kbase.ko ---\n'
insmod /mali_kbase.ko
RC=$?
printf 'insmod exit=%s\n' "$RC"

printf '\n--- Mali dmesg ---\n'
dmesg | grep -i mali || true

printf '\n--- device nodes ---\n'
ls -l /dev/mali* 2>/dev/null || true

printf '\n--- module version ---\n'
cat /sys/module/mali_kbase/version 2>/dev/null || true

printf '\nType commands here; Ctrl-] is the QEMU escape.\n'
exec /bin/sh
INIT
chmod 0755 "$RFS/init"

( cd "$RFS" && find . -print0 | cpio --null -ov --format=newc ) | gzip -9 > "$ROOT/artifacts/mali-initramfs.cpio.gz"

# 8) Verification report.
{
    echo "KDIR=$KDIR"
    echo "KVER=$KVER"
    echo "MALI_DIR=$MALI_DIR"
    echo "MALI_KERNEL_DIR=$MALI_KERNEL_DIR"
    echo "MALI_KO=$MALI_KO"
    echo
    echo "Driver release string:"
    grep -n 'MALI_RELEASE_NAME' "$MALI_KO" 2>/dev/null || true
    echo
    echo "Kernel config:"
    grep -E '^(CONFIG_MALI_|# CONFIG_MALI_|CONFIG_OF=|# CONFIG_OF )' "$ROOT/build/.config" || true
    echo
    echo "Kernel image:"
    ls -lh "$ROOT/artifacts/bzImage" "$ROOT/artifacts/vmlinux"
    echo "Mali module:"
    ls -lh "$ROOT/artifacts/mali_kbase.ko"
} > "$ROOT/artifacts/build-report.txt"

cat > "$ROOT/run.sh" <<RUN
#!/usr/bin/env bash
set -euo pipefail
exec qemu-system-x86_64 \
  -machine pc \
  -accel kvm \
  -cpu host \
  -m 4096 \
  -smp 4 \
  -kernel "$ROOT/artifacts/bzImage" \
  -initrd "$ROOT/artifacts/mali-initramfs.cpio.gz" \
  -append 'console=ttyS0' \
  -nographic \
  -no-reboot
RUN
chmod +x "$ROOT/run.sh"

cat <<DONE

[+] BUILD COMPLETE

Artifacts:
  $ROOT/artifacts/bzImage
  $ROOT/artifacts/vmlinux
  $ROOT/artifacts/mali_kbase.ko
  $ROOT/artifacts/mali-initramfs.cpio.gz
  $ROOT/artifacts/kernel.config
  $ROOT/artifacts/build-report.txt

Run:
  $ROOT/run.sh

Inside the guest, the success signature from Arm should include:
  mali mali.0: Kernel DDK version r54p0-00eac0
  mali mali.0: Using Dummy Model
  mali mali.0: Probed as mali0

Note: the script has not been tested here because the Arm r54p0 source tarball
was not included in the upload. The supplied Arm patch set and PDFs were inspected.
DONE
