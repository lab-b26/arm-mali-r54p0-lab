# Arm r54p0 x86 Mali virtual lab

This bundle implements the x86 **"Simulated Platform Device"** path from Arm's
`Arm GPU Bug Bounty Virtual Platform How-To Guide` (document version 20250623-1.0).

## What comes from Arm

- Mali 5th Gen Kbase source: r54p0.
- In-tree integration:
  - `cp -a "$MALI_DIR"/driver/product/kernel/* "$KDIR/"`
  - append `obj-$(CONFIG_MALI_MIDGARD) += arm/` to `drivers/gpu/Makefile`
  - add `source "drivers/gpu/arm/Kconfig"` to `drivers/video/Kconfig`
- x86 configuration:
  - `CONFIG_MALI_MIDGARD=m`
  - `CONFIG_MALI_CSF_SUPPORT=y`
  - `CONFIG_MALI_EXPERT=y`
  - `CONFIG_MALI_NO_MALI=y`
  - `# CONFIG_MALI_REAL_HW is not set`
  - `CONFIG_MALI_NO_MALI_DEFAULT_GPU="tKRx"`
  - `CONFIG_MALI_PLATFORM_NAME="vexpress"`
- supplied six x86 patches, applied with `patch -p3`.
- the expected `dmesg` success signature.

## One explicit implementation choice

Arm's Device Configuration Guidelines say a new virtual environment should use
the latest stable or longterm Linux kernel, but they do not pin an exact kernel
release. This bundle uses Linux **6.12.111 LTS** as a concrete baseline because
it is a conservative LTS line for the 2025 r54p0 document. If your r54p0 source
needs a different kernel, change `KVER=` and port the six patches as Arm says may
be necessary for other driver versions.

## Host

Arm says the virtual-platform instructions were tested on Ubuntu 24.04.2 LTS
with 16 GB RAM, 256 GB disk and 4 or more vCPUs. Use that as the reference host.

## Prerequisites

On Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y \
  build-essential gcc make clang bc bison flex libssl-dev libelf-dev dwarves \
  cpio gzip xz-utils patch unzip busybox-static curl \
  qemu-system-x86 qemu-utils cpu-checker
```

Get the **r54p0 Arm 5th Gen kernel-driver source** from Arm's official download
page. The package listed there is:

`AX504X08X-SW-99002-r54p0-01eac0.tar.gz`

MD5:

`3bcd3870b58f83442b16b83e432e2f97`

Also use the supplied:

`patches_for_virtual_device.zip`

## Build

```bash
chmod +x setup_arm_r54p0_x86.sh

MALI_TARBALL="$HOME/Downloads/AX504X08X-SW-99002-r54p0-01eac0.tar.gz" \
PATCH_ZIP="$HOME/Downloads/patches_for_virtual_device.zip" \
./setup_arm_r54p0_x86.sh
```

Then:

```bash
$HOME/arm-r54p0-x86-lab/run.sh
```

## Expected Mali probe

Arm's guide gives this successful pattern:

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

## After bring-up

Arm's FAQ explains that after opening the Mali device, only a limited set of
IOCTLs is initially accepted. To access the broader interface, user space first
uses `KBASE_IOCTL_VERSION_CHECK` and then `KBASE_IOCTL_SET_FLAGS`. That is the
right starting point for a later stateful syscall harness.

The FAQ also notes that the dummy model does not execute the GPU firmware and
cannot model vulnerabilities requiring real GPU/firmware reads, writes or
instruction execution. Keep this lab as the driver-side investigation stage.
