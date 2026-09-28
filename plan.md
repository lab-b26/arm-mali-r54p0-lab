# Arm Mali GPU Bug Bounty — r54p0 x86 Simulated Platform Lab

## OpenCode Big Pickle execution plan

**Purpose:** give OpenCode a deterministic, checkpointed procedure to build and verify the Arm-documented x86 **"Simulated Platform Device"** lab using the **Mali 5th Gen r54p0** Kbase source and the **six Arm-supplied virtual-device patches**, then prepare the environment for stateful Kbase syscall fuzzing and later bounty-oriented validation.

**Primary source of truth:** the Arm Bug Bounty documents and the exact `patches_for_virtual_device.zip` supplied with this project. Do not silently replace them with a newer driver, another patch set, another Kbase branch, or an unofficial recipe.

---

## 0. Operating rules for the agent

OpenCode must behave as a reproducible build/research agent, not as an interactive guesser.

### 0.1 Rules

1. Work only inside the dedicated lab workspace unless a system package install or an explicitly requested download requires another path.
2. Never modify an existing kernel source tree, Android tree, or Mali tree outside the lab workspace.
3. Before any destructive operation, create a backup or use a fresh directory. Do not run broad `rm -rf` against `$HOME`.
4. Record every version, checksum, git commit, patch checksum, compiler version, QEMU version, kernel config, and command used for the successful build.
5. Do not claim success unless the corresponding verification command passes.
6. If an Arm-supplied patch does not apply cleanly, stop at the patching stage, save the exact error, and do not invent a replacement patch without recording it as an **agent-created compatibility modification**.
7. Keep the **Arm baseline** separate from the **instrumented investigation build**.
8. `CONFIG_MALI_DEBUG=n` is mandatory. Never enable it.
9. The x86 virtual platform uses `CONFIG_MALI_NO_MALI=y`. Treat all findings that exist only in the dummy model as investigation-only; do not treat dummy-model code as a bounty finding.
10. Do not use privileged/debug-only interfaces as the basis for the final EL0 reachability claim.
11. Do not assume that a KASAN crash is automatically a bounty-eligible vulnerability. Always perform the scope/impact triage described below.
12. Never turn a crash into an exploit automatically. First establish root cause, reachability, affected code, and security impact.
13. Keep a copy of the exact original Arm patches and original r54p0 source archive. Never overwrite them.
14. All downloaded third-party source must be identified and recorded before use.
15. If a source does not specify a value, mark it `IMPLEMENTATION_CHOICE` rather than pretending Arm specified it.

### 0.2 Source precedence

When two instructions appear to disagree, use this order:

1. Arm documents uploaded with this project.
2. Exact Arm patch bundle supplied with this project.
3. Official Arm driver download page and official release metadata.
4. Official Linux/QEMU/Syzkaller documentation.
5. Local implementation choices made necessary by the host environment.

Document any lower-priority change in `research/decisions.md`.

---

# 1. Scope of this lab

This phase builds the **x86 workstation / Simulated Platform Device** environment documented by Arm.

The target stack is:

```text
x86_64 host
    |
    +-- QEMU x86_64
            |
            +-- 64-bit Linux guest
                    |
                    +-- Arm Mali 5th Gen Kbase r54p0
                    |      |
                    |      +-- CONFIG_MALI_MIDGARD=m
                    |      +-- CONFIG_MALI_CSF_SUPPORT=y
                    |      +-- CONFIG_MALI_EXPERT=y
                    |      +-- CONFIG_MALI_NO_MALI=y
                    |      +-- CONFIG_MALI_NO_MALI_DEFAULT_GPU="tKRx"
                    |      +-- CONFIG_MALI_PLATFORM_NAME="vexpress"
                    |      +-- CONFIG_MALI_DEBUG=n
                    |
                    +-- dummy Mali model
                    |
                    +-- /dev/mali0
                    |
                    +-- unprivileged test process
```

The official Arm guide says the x86 path is the **"Simulated Platform Device"** configuration and that it requires the driver source patches supplied in `patches_for_virtual_device.zip`. The six patches apply cleanly to **Mali 5th Gen r54p0**. Arm's expected successful probe includes `Kernel DDK version r54p0-00eac0`, `Using Dummy Model`, and `Probed as mali0`.

This lab does **not** emulate a real Mali GPU or execute Mali GPU firmware. It is a driver-side investigation environment.

---

# 2. Workspace layout

Create exactly this layout:

```text
~/arm-mali-r54p0-x86/
├── downloads/
│   ├── AX504X08X-SW-99002-r54p0-01eac0.tar.gz
│   └── patches_for_virtual_device.zip
├── source/
│   ├── linux-<KVER>/
│   └── mali-r54p0-unpacked/
├── kernel/
│   ├── baseline/                 # clean build output
│   └── instrumented/             # KASAN/KCOV investigation build
├── patches/
│   └── arm-virtual-device/       # untouched copies
├── rootfs/
│   ├── baseline/
│   └── instrumented/
├── artifacts/
│   ├── baseline/
│   └── instrumented/
├── qemu/
│   ├── run-baseline.sh
│   ├── run-instrumented.sh
│   └── logs/
├── fuzz/
│   ├── syzkaller/
│   ├── corpus/
│   ├── programs/
│   └── crashes/
├── research/
│   ├── decisions.md
│   ├── versions.md
│   ├── patches.md
│   ├── uapi-map.md
│   ├── targets.md
│   ├── triage.md
│   └── findings/
└── logs/
    ├── host.txt
    ├── download.txt
    ├── patch.txt
    ├── config-baseline.txt
    ├── config-instrumented.txt
    ├── build-baseline.txt
    ├── build-instrumented.txt
    └── verification.txt
```

Set:

```bash
export LAB="$HOME/arm-mali-r54p0-x86"
mkdir -p "$LAB"/{downloads,source,kernel/{baseline,instrumented},patches/arm-virtual-device,rootfs/{baseline,instrumented},artifacts/{baseline,instrumented},qemu/logs,fuzz/{syzkaller,corpus,programs,crashes},research/findings,logs}
```

---

# 3. Preflight host inspection

## 3.1 Host requirements

Arm's virtual-platform guide says its instructions were tested on **Ubuntu 24.04.2 LTS**, using 16 GB RAM, 256 GB disk, and 4 or more vCPUs. More vCPUs mainly affect compile time.

Check the actual machine:

```bash
cat /etc/os-release
uname -a
uname -m
lscpu
free -h
df -h "$HOME"
```

The build host should be x86_64 for this lab.

Hard stop if:

```text
uname -m != x86_64
```

unless the same build is intentionally being performed on another workstation and the QEMU target is still x86_64.

## 3.2 Required programs

Check first:

```bash
for c in \
  gcc g++ clang make bc bison flex patch unzip tar xz cpio gzip \
  curl busybox qemu-system-x86_64 qemu-img git sha256sum md5sum; do
    command -v "$c" || true
done
```

Install missing Debian/Ubuntu packages:

```bash
sudo apt update
sudo apt install -y \
  build-essential gcc g++ clang llvm lld \
  make bc bison flex \
  libssl-dev libelf-dev dwarves \
  patch unzip xz-utils cpio gzip \
  busybox-static curl wget git \
  qemu-system-x86 qemu-utils \
  python3 python3-pip cmake ninja-build \
  ripgrep jq gdb
```

Record versions:

```bash
{
  echo '=== host ==='
  date -Is
  cat /etc/os-release
  uname -a
  echo
  echo '=== tool versions ==='
  gcc --version | head -1
  clang --version | head -1
  make --version | head -1
  qemu-system-x86_64 --version | head -1
  cmake --version | head -1
  git --version
} | tee "$LAB/logs/host.txt"
```

## 3.3 KVM

Check:

```bash
ls -l /dev/kvm || true
grep -E '^(vmx|svm)' /proc/cpuinfo | head
lsmod | grep '^kvm' || true
```

If KVM is available, use it. If it is unavailable, still allow a non-accelerated QEMU smoke test, but record that performance will be much lower.

Do not make KVM a build correctness dependency.

---

# 4. Obtain the exact Arm r54p0 source

## 4.1 Required package

Use the **Mali 5th Gen GPU Architecture Kernel Driver** download page:

```text
https://developer.arm.com/downloads/-/mali-drivers/5th-gen-gpu-architecture-kernel
```

Required r54p0 package:

```text
AX504X08X-SW-99002-r54p0-01eac0.tar.gz
```

Official MD5 recorded in the Arm download listing:

```text
3bcd3870b58f83442b16b83e432e2f97
```

Do not substitute r54p2/r54p3/r56p0 for this exact x86-patch baseline.

Reason: the supplied Arm virtual-device patch set states that it applies cleanly to **r54p0**.

If the source archive is not already present in `$LAB/downloads`, OpenCode should stop with a clear instruction to obtain it from Arm's official page and then continue. Do not download a similarly named release by guessing.

## 4.2 Verify archive

```bash
MALI_TARBALL="$LAB/downloads/AX504X08X-SW-99002-r54p0-01eac0.tar.gz"

test -f "$MALI_TARBALL"
md5sum "$MALI_TARBALL"
```

Required MD5:

```text
3bcd3870b58f83442b16b83e432e2f97
```

Record:

```bash
{
  echo "MALI_TARBALL=$MALI_TARBALL"
  echo "MD5=$(md5sum "$MALI_TARBALL" | awk '{print $1}')"
  echo "SHA256=$(sha256sum "$MALI_TARBALL" | awk '{print $1}')"
} | tee -a "$LAB/logs/download.txt"
```

If MD5 differs, **stop**. Do not proceed with an unverified archive.

---

# 5. Preserve the exact Arm patch bundle

The supplied file is:

```text
patches_for_virtual_device.zip
```

Copy it without modification:

```bash
PATCH_ZIP="$LAB/downloads/patches_for_virtual_device.zip"
cp /mnt/data/arm_upload/patches_for_virtual_device.zip "$PATCH_ZIP"
```

If the path is unavailable on another host, obtain the ZIP from the project input instead of changing the six patch files.

Verify:

```bash
unzip -l "$PATCH_ZIP"
sha256sum "$PATCH_ZIP"
```

Expected six patch names:

```text
0001-mali-fix-build-error-for-CONFIG_OF-n-for-4.1-kernels.patch
0002-Fix-x86-build-error-for-missing-asm-arch_timer.h.patch
0003-Workaround-arch_timer-funcs-undefined-for-NO_MALI.patch
0004-Workaround-no-definition-of-dmb-in-non-Arm-platforms.patch
0005-Fix-unused-function-warnings.patch
0006-Fix-make-clean-when-no-arbitration-code-present.patch
```

Extract an untouched copy:

```bash
rm -rf "$LAB/patches/arm-virtual-device"/*
unzip -q "$PATCH_ZIP" -d "$LAB/patches/arm-virtual-device"
```

Record:

```bash
sha256sum "$LAB/patches/arm-virtual-device"/*.patch \
  | tee "$LAB/logs/patch.txt"
```

Never edit files in this directory.

---

# 6. Obtain a Linux kernel

## 6.1 What Arm actually specifies

Arm's Device Configuration Guidelines do **not** pin a single Linux kernel release. For a new virtual environment they recommend using the latest Android Common Kernel or the latest Linux stable or long-term release before testing.

Therefore the agent must not write a fictitious statement such as "Arm requires Linux 6.x".

## 6.2 Selection rule for this implementation

At execution time:

1. Inspect current stable/LTS Linux releases.
2. Prefer an actively maintained LTS line for reproducibility.
3. Record the exact kernel release in `research/versions.md`.
4. Download from an official kernel source location.
5. Do not assume the selected kernel is automatically compatible with r54p0.
6. If the six Arm patches fail to apply, stop and report the compatibility issue.

Example variables once selected:

```bash
export KVER="<selected-stable-or-LTS-release>"
export KERNEL_DIR="$LAB/source/linux-$KVER"
```

Download, verify, unpack, and record the exact URL, checksum if available, and git/source version.

---

# 7. Unpack the r54p0 source and locate Kbase

```bash
rm -rf "$LAB/source/mali-r54p0-unpacked"
mkdir -p "$LAB/source/mali-r54p0-unpacked"
tar -xf "$MALI_TARBALL" -C "$LAB/source/mali-r54p0-unpacked"
```

Find the driver kernel directory:

```bash
find "$LAB/source/mali-r54p0-unpacked" \
  -type d -path '*/driver/product/kernel' -print
```

Set:

```bash
export MALI_KERNEL_DIR="$(find "$LAB/source/mali-r54p0-unpacked" -type d -path '*/driver/product/kernel' -print -quit)"
```

Verify:

```bash
test -n "$MALI_KERNEL_DIR"
test -f "$MALI_KERNEL_DIR/drivers/gpu/arm/midgard/Kbuild"
```

Locate the release string:

```bash
grep -n 'MALI_RELEASE_NAME' \
  "$MALI_KERNEL_DIR/drivers/gpu/arm/midgard/Kbuild"
```

Expected release family:

```text
r54p0-00eac0
```

Record the source tree path and release string.

---

# 8. Create a fresh Linux source tree for the baseline

Never integrate Mali into the downloaded Linux archive in place if the same source tree will later be used for a second build.

```bash
# unpack the selected official Linux source into:
# $LAB/source/linux-$KVER
```

After unpacking:

```bash
cd "$KERNEL_DIR"
git status 2>/dev/null || true
```

For tarball-based kernel sources, Git status may not be available. In that case, record a complete source archive checksum instead.

---

# 9. Integrate Mali into Linux exactly as Arm documents

Arm's integration sequence is:

```bash
cp -a "$MALI_DIR/driver/product/kernel"/* "$KDIR/"
cd "$KDIR"
echo 'obj-$(CONFIG_MALI_MIDGARD) += arm/' | tee -a drivers/gpu/Makefile
sed -i '$i source "drivers/gpu/arm/Kconfig"' drivers/video/Kconfig
```

For this project:

```bash
export KDIR="$KERNEL_DIR"
```

and use the actual parent directory that contains `driver/product/kernel` as `MALI_DIR`.

Then verify the modifications occurred exactly once:

```bash
grep -n 'obj-$(CONFIG_MALI_MIDGARD) += arm/' drivers/gpu/Makefile
grep -n 'source "drivers/gpu/arm/Kconfig"' drivers/video/Kconfig
```

If either line is duplicated because the agent is rerunning the build, stop and cleanly recreate the kernel source tree instead of appending another copy.

---

# 10. Apply all six Arm x86 patches

## 10.1 Preflight

First test every patch without changing the tree:

```bash
cd "$KDIR"
for patch_file in "$LAB"/patches/arm-virtual-device/*.patch; do
    echo "DRY-RUN: $patch_file"
    patch --dry-run -p3 -i "$patch_file"
done
```

All six must pass.

## 10.2 Apply

Exactly as Arm documents:

```bash
cd "$KDIR"
for patch_file in "$LAB"/patches/arm-virtual-device/*.patch; do
    echo "$patch_file"
    patch -p3 -i "$patch_file"
done
```

Capture the entire output:

```bash
{
  cd "$KDIR"
  for patch_file in "$LAB"/patches/arm-virtual-device/*.patch; do
    echo "=== APPLY $(basename "$patch_file") ==="
    patch -p3 -i "$patch_file"
  done
} 2>&1 | tee "$LAB/logs/patch.txt"
```

If a patch fails:

```text
STOP
SAVE ERROR
DO NOT GUESS
DO NOT SKIP THE PATCH
DO NOT EDIT THE PATCH FILE
```

## 10.3 Patch purpose

### Patch 0001
Corrects the kernel-version guard around `of_property_*_flag` compatibility functions for `CONFIG_OF=n` on the non-DT x86 configuration.

### Patch 0002
Removes the non-x86-compatible dependency on `asm/arch_timer.h` from code that must compile on the x86 simulated platform.

### Patch 0003
Provides the non-Arm timer-frequency workaround required by the no-Mali build.

### Patch 0004
Provides `dmb(opt)` for non-Arm platforms by mapping it to the generic Linux memory barrier.

### Patch 0005
Prevents unused-function warnings in the no-Device-Tree configuration.

### Patch 0006
Fixes `make clean` when the Mali arbitration reference code is not present.

Do not describe these patches as vulnerability fixes. They are **virtual-platform/x86 build-enablement patches supplied by Arm**.

---

# 11. Configure the x86 Simulated Platform Device

## 11.1 Start from x86_64 defconfig

```bash
cd "$KDIR"
make O="$LAB/kernel/baseline" x86_64_defconfig
```

## 11.2 Mali configuration required by Arm

Set:

```text
CONFIG_MALI_MIDGARD=m
CONFIG_MALI_CSF_SUPPORT=y
CONFIG_MALI_EXPERT=y
CONFIG_MALI_NO_MALI=y
# CONFIG_MALI_REAL_HW is not set
CONFIG_MALI_NO_MALI_DEFAULT_GPU="tKRx"
CONFIG_MALI_PLATFORM_NAME="vexpress"
```

Also ensure Device Tree is disabled for the non-DT x86 simulated path:

```text
CONFIG_OF=n
```

Arm's guide notes that `CONFIG_LARGE_PAGE_SUPPORT=y` will be selected by default.

## 11.3 Enforce MALI_DEBUG=n

This is mandatory for bounty-compatible Kbase builds:

```text
# CONFIG_MALI_DEBUG is not set
```

Use the kernel `scripts/config` helper where available:

```bash
SCRIPTS="$KDIR/scripts/config"

"$SCRIPTS" --file "$LAB/kernel/baseline/.config" \
  --disable OF \
  --module MALI_MIDGARD \
  --enable MALI_CSF_SUPPORT \
  --enable MALI_EXPERT \
  --enable MALI_NO_MALI \
  --disable MALI_REAL_HW \
  --disable MALI_DEBUG \
  --set-str MALI_NO_MALI_DEFAULT_GPU tKRx \
  --set-str MALI_PLATFORM_NAME vexpress
```

Then:

```bash
make O="$LAB/kernel/baseline" olddefconfig
```

## 11.4 Configuration audit

Run:

```bash
grep -E '^(CONFIG_MALI_|# CONFIG_MALI_|CONFIG_OF=|# CONFIG_OF )' \
  "$LAB/kernel/baseline/.config"
```

Then assert the required values:

```bash
./scripts/config --state MALI_MIDGARD
./scripts/config --state MALI_CSF_SUPPORT
./scripts/config --state MALI_EXPERT
./scripts/config --state MALI_NO_MALI
./scripts/config --state MALI_REAL_HW
./scripts/config --state MALI_DEBUG
./scripts/config -s MALI_NO_MALI_DEFAULT_GPU
./scripts/config -s MALI_PLATFORM_NAME
```

If the helper syntax for string values differs on the selected kernel, read `scripts/config --help` and use that kernel's documented syntax. Do not guess.

Save the complete config:

```bash
cp "$LAB/kernel/baseline/.config" "$LAB/logs/config-baseline.txt"
```

---

# 12. Build the baseline kernel and Kbase

Build normally as a kernel module:

```bash
cd "$KDIR"
make O="$LAB/kernel/baseline" -j"$(nproc)" bzImage modules \
  2>&1 | tee "$LAB/logs/build-baseline.txt"
```

Verify:

```bash
ls -lh \
  "$LAB/kernel/baseline/arch/x86/boot/bzImage" \
  "$LAB/kernel/baseline/vmlinux"

find "$LAB/kernel/baseline" -name mali_kbase.ko -print
```

Copy the built module:

```bash
MALI_KO="$(find "$LAB/kernel/baseline" -type f -name mali_kbase.ko -print -quit)"
test -n "$MALI_KO"
cp "$MALI_KO" "$LAB/artifacts/baseline/mali_kbase.ko"
cp "$LAB/kernel/baseline/arch/x86/boot/bzImage" "$LAB/artifacts/baseline/bzImage"
cp "$LAB/kernel/baseline/vmlinux" "$LAB/artifacts/baseline/vmlinux"
cp "$LAB/kernel/baseline/.config" "$LAB/artifacts/baseline/kernel.config"
```

Record hashes:

```bash
sha256sum "$LAB/artifacts/baseline"/* \
  | tee "$LAB/artifacts/baseline/SHA256SUMS"
```

Do not continue to QEMU unless `mali_kbase.ko` exists.

---

# 13. Build the minimal initramfs

The official guide focuses on building/installing the kernel module; a minimal BusyBox initramfs is an implementation convenience for the QEMU lab.

Create:

```bash
RFS="$LAB/rootfs/baseline"
rm -rf "$RFS"
mkdir -p "$RFS"/{bin,dev,etc,proc,sys,tmp}
```

Install static BusyBox:

```bash
BUSYBOX="$(command -v busybox)"
test -n "$BUSYBOX"
cp "$BUSYBOX" "$RFS/bin/busybox"
chmod 0755 "$RFS/bin/busybox"
```

Create links:

```bash
cd "$RFS/bin"
for app in sh mount umount ls cat echo dmesg insmod rmmod sleep grep mkdir uname id ps; do
    ln -sf busybox "$app"
done
```

Copy Kbase:

```bash
cp "$LAB/artifacts/baseline/mali_kbase.ko" "$RFS/mali_kbase.ko"
```

Create init:

```bash
cat > "$RFS/init" <<'INIT'
#!/bin/sh

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

printf '\n=== Arm Mali 5th Gen r54p0 x86 Simulated Platform ===\n'
uname -a

printf '\n--- loading mali_kbase.ko ---\n'
insmod /mali_kbase.ko
RC=$?
printf 'insmod exit=%s\n' "$RC"

printf '\n--- Mali dmesg ---\n'
dmesg | grep -i mali || true

printf '\n--- Mali devices ---\n'
ls -l /dev/mali* 2>/dev/null || true

printf '\n--- Kbase version ---\n'
cat /sys/module/mali_kbase/version 2>/dev/null || true

printf '\n--- sysfs inspection ---\n'
find /sys/class/misc/mali0 -maxdepth 2 -type f -print 2>/dev/null || true

printf '\n=== interactive shell ===\n'
exec /bin/sh
INIT
chmod 0755 "$RFS/init"
```

Pack:

```bash
cd "$RFS"
find . -print0 | cpio --null -ov --format=newc \
  | gzip -9 > "$LAB/artifacts/baseline/mali-initramfs.cpio.gz"
```

---

# 14. Launch QEMU

The Arm guide defines the x86 configuration as a non-Device-Tree **Simulated Platform Device** with `CONFIG_MALI_PLATFORM_NAME="vexpress"`. It does not prescribe one universal QEMU command line in the document. Therefore the exact QEMU command is an **implementation choice**, not an Arm requirement.

Use a simple x86_64 PC machine for this lab:

```bash
cat > "$LAB/qemu/run-baseline.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LAB="${LAB:-$HOME/arm-mali-r54p0-x86}"

exec qemu-system-x86_64 \
  -machine pc \
  -accel kvm \
  -cpu host \
  -m 4096 \
  -smp 4 \
  -kernel "$LAB/artifacts/baseline/bzImage" \
  -initrd "$LAB/artifacts/baseline/mali-initramfs.cpio.gz" \
  -append 'console=ttyS0' \
  -nographic \
  -no-reboot
EOF
chmod +x "$LAB/qemu/run-baseline.sh"
```

If KVM is unavailable, use the same command without `-accel kvm` and `-cpu host`, then record the slower non-accelerated mode.

Start:

```bash
LAB="$LAB" "$LAB/qemu/run-baseline.sh" \
  2>&1 | tee "$LAB/qemu/logs/baseline-boot.log"
```

---

# 15. Mandatory bring-up checks

Inside the guest:

```bash
uname -a
cat /sys/module/mali_kbase/version
ls -l /dev/mali*
dmesg | grep -i mali
```

## 15.1 Expected Arm signature

The guide's successful dummy-model example contains the following pattern:

```text
mali mali.0: Kernel DDK version r54p0-00eac0
mali mali.0: Using Dummy Model
mali mali.0: GPU metrics tracepoint support enabled
mali mali.0: Register LUT 000c0000 initialized for GPU arch 0x000d0801
mali mali.0: GPU identified as 0x0 arch 13.8.1 r0p0 status 0
mali mali.0: No OPPs found in device tree! Scaling timeouts using 100000 kHz
mali mali.0: Large page allocation set to true after hardware feature check
mali mali.0: Clock not available for devfreq
mali mali.0: Continuing without devfreq
mali mali.0: Probed as mali0
```

Exact line ordering and extra informational messages may vary with the selected kernel, but these three conditions are critical:

```text
Kernel DDK version r54p0-00eac0
Using Dummy Model
Probed as mali0
```

## 15.2 Failure triage

### `insmod` fails

Collect:

```bash
dmesg | tail -200
modinfo /mali_kbase.ko 2>/dev/null || true
cat /proc/kallsyms | grep -i mali | head -100
```

Check unresolved symbols on the host:

```bash
nm -u "$LAB/artifacts/baseline/mali_kbase.ko" || true
```

Do not immediately patch the source. First determine whether this is a kernel-version/API mismatch.

### Module loads but no `mali0`

Check:

```bash
dmesg | grep -Ei 'mali|platform|vexpress|probe|of_|acpi'
ls -l /sys/class/misc/
find /sys/devices -iname '*mali*' -o -iname '*vexpress*' 2>/dev/null
```

For the x86 Simulated Platform Device path, ensure `CONFIG_OF=n` and `CONFIG_MALI_PLATFORM_NAME="vexpress"`.

### `make clean` fails on missing arbitration code

This is the documented purpose of patch 0006. Reapply/verify that patch rather than adding arbitrary arbitration source.

---

# 16. Test Kbase with Arm's recommended libGPUCounters example

Once `/dev/mali0` is confirmed, build Arm's example:

```bash
cd "$LAB/fuzz"
git clone https://github.com/ARM-software/libGPUCounters.git "$LAB/fuzz/libGPUCounters"
cd "$LAB/fuzz/libGPUCounters"
```

Arm says CMake must be at least version 3.13.5. Check:

```bash
cmake --version
```

Build:

```bash
cmake -DHWCPIPE_BUILD_EXAMPLES=ON -B build .
cmake --build build -j"$(nproc)"
```

Run:

```bash
cd build
examples/api-example
```

Arm's documented example output identifies:

```text
GPU Device 0:
Product Family: Arm 5th Gen
Number of Cores: 13
Bus Width: 64
GPU 0 Supported counters:
```

The guide notes that counter values are expected to be zero for the dummy model.

Save output:

```bash
examples/api-example 2>&1 | tee "$LAB/qemu/logs/libGPUCounters-api-example.log"
```

If the device node is missing, the guide says the example reports `Mali GPU device 0 is missing`.

---

# 17. Understand the user/kernel attack surface before fuzzing

Do not begin with random ioctl numbers.

Arm's How-To Guide says Kbase is accessed mainly through IOCTLs on a Mali file descriptor, usually obtained with:

```c
open("/dev/mali0", ...)
```

For CSF GPUs, the user/kernel definitions live under:

```text
include/uapi/gpu/arm/midgard/
```

including:

```text
mali_kbase_ioctl.h
mali_kbase_mem_flags.h
mali_base_kernel.h
mali_base_common_kernel.h
csf/mali_kbase_csf_ioctl.h
csf/mali_base_csf_kernel.h
csf/mali_kbase_csf_errors_dumpfault.h
csf/mali_kbase_csf_mem_flags.h
gpu/mali_kbase_gpu_coherency.h
gpu/mali_kbase_gpu_id.h
backend/csf/mali_kbase_gpu_regmap_csf
```

Create a UAPI inventory:

```bash
cd "$KDIR"
rg -n 'KBASE_IOCTL|_IO[A-Z]*\(|struct kbase_|struct base_' \
  include/uapi/gpu/arm/midgard \
  > "$LAB/research/uapi-map-raw.txt"
```

Then generate a human-readable `research/uapi-map.md` with:

```text
ioctl name
command value
argument type
input/output direction
required initialization state
handle/resource dependencies
mmap relationship
cleanup operation
whether it is privileged or unprivileged
```

---

# 18. First valid ioctl sequence

Arm's FAQ says that after opening the Mali device only a limited subset of IOCTLs can initially be used. The wider interface requires this order:

```text
KBASE_IOCTL_VERSION_CHECK
        ↓
KBASE_IOCTL_SET_FLAGS
        ↓
other general/CSF interfaces
```

Do not begin fuzzing every ioctl independently.

Create a minimal seed program that:

1. Opens `/dev/mali0`.
2. Performs `KBASE_IOCTL_VERSION_CHECK`.
3. Performs `KBASE_IOCTL_SET_FLAGS`.
4. Queries GPU properties if useful.
5. Exercises one memory operation.
6. Cleans everything up.
7. Closes the Mali fd.

Use the exact r54p0 headers to construct the structures. Never invent the structure layout from a newer Kbase version.

---

# 19. Stateful Kbase model for fuzzing

The fuzzing model should follow Kbase resource lifetimes rather than treating each ioctl as an independent syscall.

## 19.1 Context lifecycle

```text
open /dev/mali0
    ↓
VERSION_CHECK
    ↓
SET_FLAGS
    ↓
context active
    ↓
allocate resources
    ↓
cleanup
    ↓
close
```

## 19.2 Memory lifecycle

Arm documents the following general CSF memory operations:

```text
MEM_ALLOC
MEM_ALLOC_EX
MEM_IMPORT
MEM_ALIAS
MEM_FREE
MEM_SYNC
MEM_COMMIT
MEM_FLAGS_CHANGE
MEM_QUERY
```

Common mapping pattern:

```text
MEM_ALLOC / IMPORT / ALIAS
        ↓
GPU address/cookie returned
        ↓
mmap()/mmap64()
        ↓
CPU + GPU mapping
        ↓
operations
        ↓
munmap()/MEM_FREE as appropriate
```

For 64-bit userspace, Arm calls the common memory arrangement `SAME_VA`. Its documented implementation has important address/zone/alignment constraints. Fuzzing should therefore preserve valid seeds and mutate around those constraints instead of making every address random.

## 19.3 JIT / Tiler Heap

Include stateful seeds for:

```text
MEM_JIT_INIT
CS_TILER_HEAP_INIT
CS_TILER_HEAP_SIZE
CS_TILER_HEAP_TERM
```

Arm says Tiler Heap initialization requires prior JIT setup.

## 19.4 GPU queues / CSF

Document and seed:

```text
CS_QUEUE_REGISTER
CS_QUEUE_REGISTER_EX
CS_QUEUE_TERMINATE
CS_QUEUE_GROUP_CREATE
CS_QUEUE_GROUP_TERMINATE
CS_QUEUE_BIND
CS_QUEUE_KICK
QUEUE_GROUP_CLEAR_FAULTS
CS_GET_GLB_IFACE
```

A valid queue generally requires:

```text
GPU buffer allocation
      ↓
valid ring-buffer size/address
      ↓
CS_QUEUE_REGISTER
      ↓
CS_QUEUE_GROUP_CREATE
      ↓
CS_QUEUE_BIND
      ↓
mmap user-IO pages
      ↓
CS_QUEUE_KICK / other operations
      ↓
termination/cleanup
```

Do not execute arbitrary CSF firmware instructions just because the queue buffer is writable. Keep the first harness limited to interface correctness and state transitions.

## 19.5 Synchronization

Model:

```text
CQS objects
GPU queues
KCPU queues
Linux fences
```

CQS memory has alignment requirements documented by Arm:

```text
32-bit CQS: 8-byte alignment
64-bit CQS: 16-byte alignment
```

Use valid seeds and mutate values around boundaries.

## 19.6 KCPU queues

Model:

```text
KCPU_QUEUE_CREATE
        ↓
KCPU_QUEUE_ENQUEUE
        ↓
commands execute asynchronously
        ↓
KCPU_QUEUE_DELETE
```

Arm says a context can support up to 256 KCPU queues and a queue can have up to 256 active commands; these limits are useful boundary values for test generation, but do not begin with maximum-size stress cases.

---

# 20. Create the Syzkaller environment only after the manual driver test works

Build Syzkaller:

```bash
cd "$LAB/fuzz"
git clone https://github.com/google/syzkaller.git "$LAB/fuzz/syzkaller"
cd "$LAB/fuzz/syzkaller"
make
```

Verify:

```bash
./syz-manager -version
./syz-execprog -version
./syz-repro -version
```

Record the Git revision:

```bash
git -C "$LAB/fuzz/syzkaller" rev-parse HEAD \
  | tee -a "$LAB/research/versions.md"
```

Do not configure a manager until the kernel boots and Kbase probes successfully.

---

# 21. Investigation kernel: KASAN + KCOV

Keep the baseline build untouched.

Start from the same source/configuration or a clean source copy and create:

```text
$LAB/kernel/instrumented/
```

The Arm Device Configuration Guidelines permit KASAN options to be enabled for research builds, with KASAN test options disabled. They also permit UBSAN options with UBSAN test options disabled.

For the investigation build, retain:

```text
CONFIG_MALI_DEBUG=n
CONFIG_MALI_NO_MALI=y
CONFIG_MALI_CSF_SUPPORT=y
CONFIG_MALI_EXPERT=y
```

Add instrumentation useful for fuzzing:

```text
CONFIG_KASAN=y
CONFIG_KCOV=y
CONFIG_DEBUG_INFO=y
CONFIG_FRAME_POINTER=y
```

If any additional instrumentation is used, record it as **investigation-only** in `research/decisions.md` and do not confuse that config with the final bounty validation configuration.

Also enforce the Arm guideline exceptions:

```text
CONFIG_KASAN_*_TEST=n
CONFIG_TEST_UBSAN=n
```

Verify before building:

```bash
rg -n '^(CONFIG_KASAN.*TEST|CONFIG_TEST_UBSAN)=' \
  "$LAB/kernel/instrumented/.config" || true
```

Build:

```bash
make O="$LAB/kernel/instrumented" olddefconfig
make O="$LAB/kernel/instrumented" -j"$(nproc)" bzImage modules \
  2>&1 | tee "$LAB/logs/build-instrumented.txt"
```

Verify:

```bash
grep -E '^(CONFIG_KASAN=|CONFIG_KCOV=|CONFIG_DEBUG_INFO=|CONFIG_FRAME_POINTER=)' \
  "$LAB/kernel/instrumented/.config"
```

Never enable `CONFIG_MALI_DEBUG` just to make the fuzzing easier.

---

# 22. Fuzzing strategy

## 22.1 Phase A — deterministic smoke corpus

Before mutation, create small valid programs:

```text
seed-001-open-version-flags
seed-002-memory-alloc-free
seed-003-memory-alloc-mmap-unmap
seed-004-import-user-buffer
seed-005-memory-alias
seed-006-jit-init
seed-007-tiler-heap-lifecycle
seed-008-cs-queue-register-term
seed-009-cs-group-create-term
seed-010-kcpu-queue-create-enqueue-delete
seed-011-cqs-signal
seed-012-fence-validation
```

Each seed must terminate without requiring root.

## 22.2 Phase B — boundary mutations

Mutate one dimension at a time:

```text
size = 0
size = 1
size = sizeof(struct)-1
size = sizeof(struct)
size = sizeof(struct)+1
size = PAGE_SIZE-1
size = PAGE_SIZE
size = PAGE_SIZE+1
```

Address/buffer boundaries:

```text
0
1
PAGE_SIZE-1
PAGE_SIZE
PAGE_SIZE+1
alignment-1
alignment
alignment+1
```

Handle lifecycle mutations:

```text
valid handle
stale handle
already freed handle
wrong object-type handle
same handle after unrelated cleanup
```

Do not rely exclusively on random mutation; maintain semantic relationships.

## 22.3 Phase C — lifecycle mutation

Focus on sequences such as:

```text
allocate → map → unmap → free
allocate → map → free → use
import → sticky-map → sticky-unmap → free
queue-register → bind → terminate
queue-group-create → bind → group-terminate
KCPU enqueue → delete
CQS signal → object release
```

The objective is to find violations of lifetime, reference-count, state-machine, bounds, and cleanup invariants.

## 22.4 Phase D — concurrency

Add controlled concurrency:

```text
thread A: allocate/free
thread B: map/unmap
thread C: queue operations
thread D: synchronization operations
```

Prefer reproducible barriers and short loops over uncontrolled random threading.

Record every race candidate with the smallest thread schedule that reproduces it.

---

# 23. What to instrument and observe

Collect:

```text
KASAN reports
KCOV coverage
kernel warnings
kernel oops/panic
mali driver logs
testcase bytes/operations
syscall sequence
thread schedule
module version
kernel version
kernel config
```

Useful host commands:

```bash
rg -n -i 'mali|kasan|kcov|BUG:|WARNING:|use-after-free|slab|out-of-bounds' \
  "$LAB/qemu/logs" "$LAB/fuzz/crashes"
```

When GDB is useful:

```text
vmlinux = instrumented vmlinux
mali_kbase.ko = exact module used by the crash VM
```

Keep symbol files. Never strip the only copy of `vmlinux`.

---

# 24. Dummy-model boundary

The FAQ explicitly identifies the following as dummy-model code:

```text
mali_kbase_model_dummy.c
mali_kbase_model_dummy.h
```

and any code path compiled only when `CONFIG_MALI_NO_MALI` is enabled.

The FAQ also says the dummy model:

```text
replaces real GPU register accesses
replaces real GPU IRQ handling
completes dummy operations immediately
does not execute GPU firmware
```

Therefore classify every crash:

```text
CRASH
  |
  +-- only inside dummy-model code? --> investigation-only / out
  |
  +-- Kbase code also exercised with NO_MALI=n? --> continue validation
  |
  +-- depends on real GPU/firmware behavior? --> virtual lab insufficient
```

This is one of the most important bounty gates.

---

# 25. GPU page-fault limitation

Do not incorrectly conclude that a page-fault-sensitive code path is safe because QEMU/NO_MALI did not trigger it.

Arm's FAQ says that on the virtual platform there is no real GPU MMU IRQ to trigger a GPU page fault. A real GPU or deliberate Kbase modifications that manually simulate the relevant interrupt/register state are needed to evaluate such behavior.

Therefore:

```text
NO_MALI + no page-fault crash
        !=
real GPU page-fault path is safe
```

Mark these targets as `REQUIRES_REAL_GPU` in `research/targets.md`.

---

# 26. Power-state differences

Arm's FAQ says the dummy-model virtual device normally uses an `always_on` power policy, whereas a real device normally uses a demand policy.

This matters because some allocation/free operations differ depending on GPU power state, particularly MMU programming.

For research notes, inspect:

```bash
cat /sys/class/misc/mali0/device/power_policy 2>/dev/null || true
```

Do not use debugfs/sysfs writes as the final EL0 exploit primitive. Treat power-policy manipulation as an investigation aid only.

---

# 27. Historical PoCs and advisories

The Arm How-To Guide contains examples based on vulnerabilities that have already been patched. They are useful for understanding Kbase state transitions and for confirming that the lab executes expected code, but they are **not automatically new findings**.

Use them only as:

```text
smoke tests
UAPI learning aids
root-cause references
regression checks
```

Maintain:

```text
research/cves/
research/historical-pocs/
```

For every historical issue record:

```text
identifier
affected Kbase release
fixed release
root cause
affected Kbase file/function
what changed in the patch
whether r54p0 contains the old code
whether the same invariant exists in the current target
```

Never submit a historical reproduced issue as a new finding.

---

# 28. Bounty-oriented triage gates

A candidate finding should pass all of these gates before being called a strong bounty candidate.

## Gate A — Kbase ownership

Is the vulnerable code in Arm Kbase rather than:

```text
Linux generic kernel
QEMU
virtual-device patch
vendor platform driver
GPU firmware
```

If not, reclassify.

## Gate B — dummy-model exclusion

Does the vulnerability exist only in:

```text
mali_kbase_model_dummy.c
mali_kbase_model_dummy.h
CONFIG_MALI_NO_MALI-only code
```

If yes, do not submit under the Kbase bounty scope.

## Gate C — EL0 reachability

Can an ordinary unprivileged process reach the vulnerable path through a Kbase user/kernel interface such as:

```text
open()
ioctl()
mmap()/mmap64()
munmap()
read()
poll()
close()
```

Do not base the final claim on:

```text
root
CAP_SYS_ADMIN
privileged debugfs
privileged sysfs writes
kernel module loading
custom kernel patches
```

## Gate D — production configuration

For final validation, return to:

```text
CONFIG_MALI_DEBUG=n
CONFIG_MALI_NO_MALI=n
appropriate CONFIG_MALI_CSF_SUPPORT
normal/default Kbase options
normal/default module parameters
```

and the supported OEM device configuration described by the program.

## Gate E — unmodified driver / CSFFW

The final reproducer should use the unmodified in-scope Kbase and the normal supported firmware stack. Inserted timing delays may be documented if needed, but do not modify the driver to manufacture the bug.

## Gate F — meaningful impact

A crash alone is not enough to conclude exploitability.

Document the actual security consequence supported by evidence:

```text
memory corruption
kernel information exposure
cross-context data access
arbitrary kernel memory access
privilege-boundary violation
other concrete security impact
```

Do not invent impact from a symbol name or a KASAN report.

---

# 29. Final validation path

When an investigation result looks promising:

```text
r54p0 / NO_MALI=y
        |
        | understand crash
        | minimize testcase
        | identify invariant
        v
same Kbase logic with NO_MALI=n
        |
        | test real hardware behavior
        v
supported OEM device
        |
        | latest available security patches
        | stock driver
        | stock CSFFW
        v
ordinary unprivileged process
        |
        v
minimal reproducible PoC
```

Do not use the virtual-device crash itself as proof of a real-device vulnerability.

---

# 30. Evidence package for each serious candidate

Create:

```text
research/findings/FINDING-001/
├── README.md
├── testcase.c
├── testcase.min.c
├── reproduction.sh
├── crash.txt
├── dmesg.txt
├── kernel.config
├── kernel.version
├── mali.version
├── patch-state.txt
├── syzkaller-program.txt
├── coverage-notes.md
├── root-cause.md
└── scope-analysis.md
```

`README.md` should contain:

```text
Finding ID
Date
Environment
Host
Kernel
Kbase version
GPU architecture/model
CONFIG_MALI_DEBUG
CONFIG_MALI_NO_MALI
CONFIG_MALI_CSF_SUPPORT
Other allowed Kbase options changed
Runtime module parameters
Trigger interface
Required privilege
Reproduction rate
Observed failure
Root cause
Security impact
NO_MALI dependency analysis
Real-hardware validation status
```

---

# 31. Build/research state machine for OpenCode

OpenCode must maintain a state file:

```text
research/state.md
```

Use exactly these states:

```text
PREFLIGHT_OK
SOURCES_VERIFIED
PATCHES_VERIFIED
KERNEL_SOURCE_READY
MALI_INTEGRATED
PATCHES_APPLIED
BASELINE_CONFIG_VALID
BASELINE_BUILD_OK
INITRAMFS_OK
QEMU_BOOT_OK
MALI_PROBE_OK
MALIGPUCOUNTERS_OK
UAPI_MAPPED
INVESTIGATION_BUILD_OK
FUZZER_READY
SEEDS_VALID
FUZZING_ACTIVE
CANDIDATE_FOUND
TRIAGE_COMPLETE
REAL_DEVICE_VALIDATED
REPORT_READY
```

Only advance one state after its verification checklist passes.

If a later command fails, keep the last known good state.

---

# 32. Checkpoint helper

Use a shell helper in the workspace:

```bash
checkpoint() {
    local name="$1"
    printf '%s %s\n' "$(date -Is)" "$name" | tee -a "$LAB/research/state.log"
}
```

Example:

```bash
checkpoint PREFLIGHT_OK
checkpoint SOURCES_VERIFIED
checkpoint PATCHES_APPLIED
```

Every build phase should also save complete stdout/stderr to `logs/` using `tee`.

---

# 33. Do not perform these shortcuts

Do **not**:

```text
use r25p0 from an unrelated mirror
use a current r56p0 tree with the r54p0 patch bundle without a deliberate port
mix a newer Mali userspace UAPI header into the r54p0 kernel
turn MALI_DEBUG on
enable the real-hardware backend in the x86 dummy lab
randomly edit CONFIG_OF references outside the supplied x86 patches
skip source or checksum verification
call a dummy-model crash a bounty finding
claim real GPU/firmware behavior from NO_MALI
fuzz only random ioctl command numbers
run the fuzzer as root and claim EL0 reachability
use debugfs/sysfs-only triggers as the final attack surface
modify Kbase code solely to force a crash
submit known/patched historical CVEs as new findings
```

---

# 34. First execution checklist

OpenCode should complete the following in order:

```text
[ ] Create workspace
[ ] Record host versions/resources
[ ] Verify QEMU and KVM
[ ] Verify r54p0 archive exists
[ ] Verify r54p0 MD5 = 3bcd3870b58f83442b16b83e432e2f97
[ ] Verify six Arm patch filenames
[ ] Record patch hashes
[ ] Select and record a current Linux stable/LTS kernel
[ ] Unpack Linux
[ ] Unpack r54p0
[ ] Locate driver/product/kernel
[ ] Verify MALI_RELEASE_NAME is r54p0
[ ] Integrate Kbase into Linux
[ ] Dry-run all six patches with -p3
[ ] Apply all six patches with -p3
[ ] Configure x86_64
[ ] CONFIG_OF=n
[ ] MALI_MIDGARD=m
[ ] MALI_CSF_SUPPORT=y
[ ] MALI_EXPERT=y
[ ] MALI_NO_MALI=y
[ ] MALI_REAL_HW=n
[ ] MALI_NO_MALI_DEFAULT_GPU="tKRx"
[ ] MALI_PLATFORM_NAME="vexpress"
[ ] MALI_DEBUG=n
[ ] Verify LARGE_PAGE_SUPPORT selection
[ ] Build bzImage
[ ] Build mali_kbase.ko
[ ] Build initramfs
[ ] Boot QEMU
[ ] Verify r54p0-00eac0
[ ] Verify Using Dummy Model
[ ] Verify Probed as mali0
[ ] Verify /dev/mali0
[ ] Build libGPUCounters example
[ ] Run api-example
[ ] Save logs
[ ] Map the r54p0 UAPI
[ ] Build an unprivileged minimal seed
[ ] Build investigation kernel with KASAN/KCOV
[ ] Build Syzkaller
[ ] Start with valid stateful seeds
[ ] Begin mutation fuzzing
```

Do not begin long fuzzing runs before `MALIGPUCOUNTERS_OK` and `SEEDS_VALID`.

---

# 35. Completion criteria

The r54p0 x86 lab is considered **complete** only when all of the following are true:

1. The exact r54p0 source archive was verified.
2. The exact six Arm x86 patches were applied.
3. The kernel is 64-bit x86.
4. Mali Kbase is a module.
5. CSF support is enabled.
6. Expert configuration is enabled.
7. No-Mali is enabled for the virtual lab.
8. Real hardware backend is disabled.
9. Default dummy GPU is `tKRx`.
10. Platform name is `vexpress`.
11. `CONFIG_MALI_DEBUG=n`.
12. Linux boots in QEMU.
13. `mali_kbase.ko` loads.
14. `/dev/mali0` exists.
15. The r54p0 `Using Dummy Model` probe is observed.
16. `libGPUCounters` can open the device and identify an Arm 5th Gen GPU.
17. Baseline and instrumented configurations are stored separately.
18. A reproducible stateful UAPI seed can open, negotiate, exercise, and close Kbase without root.
19. Every major command and configuration has an audit trail.

---

# 36. Final instruction to OpenCode

The target is **not** "make the kernel crash quickly".

The target is:

```text
reproducible environment
        ↓
accurate Kbase model
        ↓
stateful unprivileged interface coverage
        ↓
new crash/bug candidate
        ↓
root-cause analysis
        ↓
dummy-model exclusion check
        ↓
NO_MALI=n validation
        ↓
real supported device validation
        ↓
concrete security impact
```

When uncertain, prefer **stop + record + ask for a missing input** over guessing.

The Arm documents are the source of truth for the virtual-platform configuration; this plan adds only explicit implementation choices needed to automate the lab and clearly labels them as such.

---

## Source material used to write this plan

- `arm_gpu_bug_bounty_virtual_platform_how_to_guide.pdf` — Arm GPU Bug Bounty Virtual Platform How-To Guide, document version `20250623-1.0`.
- `arm_gpu_bug_bounty_how_to_guide.pdf` — Arm GPU Bug Bounty How-To Guide, document version `20250623-1.0`.
- `arm_gpu_bug_bounty_faq.pdf` — Arm GPU Bug Bounty FAQ, document version `20250623-1.0`.
- `arm_gpu_bug_bounty_device_configuration_guidelines.pdf` — Arm GPU Bug Bounty Device Configuration Guidelines, document version `20250623-1.0`.
- `patches_for_virtual_device.zip` — six Arm-supplied x86 virtual-device patches.

Official driver source page:

```text
https://developer.arm.com/downloads/-/mali-drivers/5th-gen-gpu-architecture-kernel
```

r54p0 package recorded for this exact patch baseline:

```text
AX504X08X-SW-99002-r54p0-01eac0.tar.gz
MD5: 3bcd3870b58f83442b16b83e432e2f97
```

Official libGPUCounters repository referenced by Arm's guide:

```text
https://github.com/ARM-software/libGPUCounters.git
```
