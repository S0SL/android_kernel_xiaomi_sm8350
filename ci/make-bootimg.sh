#!/usr/bin/env bash
#
# Build a fastboot-flashable boot.img for the Xiaomi Mi 11 Pro (mars):
# take the official LineageOS boot image and swap in our kernel.
#
# Why: on this device recovery and the kernel live in the same "boot"
# partition, so a custom kernel can be flashed with
#     fastboot flash boot boot.img
# instead of relying on a recovery being able to install an AnyKernel3 zip.
#
# The ramdisk and dtb are taken from the official image and left untouched,
# only the kernel is replaced (the modules in vendor_boot keep working
# because CONFIG_MODVERSIONS is enabled, so the version string does not
# matter for module loading).
#
# Getting the official boot.img:
#   ./payload-dumper-go -p boot -o bootdump lineage-23.2-<date>-nightly-mars-signed.zip
#
# Usage:
#   MAGISKBOOT=/path/to/magiskboot \
#     ./ci/make-bootimg.sh bootdump/boot.img out/arch/arm64/boot/Image out-boot.img
#
set -euo pipefail

BOOTIMG="${1:?usage: make-bootimg.sh <official boot.img> <kernel Image> <output.img>}"
IMAGE="${2:?usage: make-bootimg.sh <official boot.img> <kernel Image> <output.img>}"
OUTPUT="${3:?usage: make-bootimg.sh <official boot.img> <kernel Image> <output.img>}"

MAGISKBOOT="${MAGISKBOOT:-magiskboot}"

command -v "$MAGISKBOOT" >/dev/null 2>&1 || {
	echo "ERROR: magiskboot not found (set MAGISKBOOT=/path/to/magiskboot)" >&2
	echo "       Magisk's APK ships one: lib/arm64-v8a/libmagiskboot.so" >&2
	exit 1
}
[ -f "$BOOTIMG" ] || { echo "ERROR: $BOOTIMG not found" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "ERROR: $IMAGE not found" >&2; exit 1; }

BOOTIMG="$(realpath "$BOOTIMG")"
IMAGE="$(realpath "$IMAGE")"
OUTPUT="$(realpath -m "$OUTPUT")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cp "$BOOTIMG" boot.img

echo "== unpacking official boot image =="
"$MAGISKBOOT" unpack boot.img
ORIG_RAMDISK_SHA="$(sha256sum ramdisk.cpio | cut -d' ' -f1)"

echo "== replacing kernel =="
rm -f kernel
cp "$IMAGE" kernel

echo "== repacking =="
"$MAGISKBOOT" repack boot.img "$OUTPUT"

echo "== verifying =="
mkdir verify && cd verify
cp "$OUTPUT" check.img
"$MAGISKBOOT" unpack check.img >/dev/null 2>&1
NEW_RAMDISK_SHA="$(sha256sum ramdisk.cpio | cut -d' ' -f1)"
if [ "$ORIG_RAMDISK_SHA" != "$NEW_RAMDISK_SHA" ]; then
	echo "ERROR: ramdisk changed while repacking!" >&2
	exit 1
fi
echo "ramdisk unchanged: $NEW_RAMDISK_SHA"
cd ..

ls -la "$OUTPUT"
echo
echo "flash with: fastboot flash boot $(basename "$OUTPUT")"
