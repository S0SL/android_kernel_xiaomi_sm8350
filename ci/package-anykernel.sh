#!/usr/bin/env bash
#
# Package the built kernel Image into a flashable AnyKernel3 zip
# for the Xiaomi Mi 11 Pro (mars).
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/out}"
IMAGE="$OUT/arch/arm64/boot/Image"
DIST="$ROOT/dist"
STAGE="$ROOT/ak3-build"
AK3_SRC="${AK3_SRC:-$ROOT/ak3}"

[ -f "$IMAGE" ] || { echo "ERROR: $IMAGE not found, build the kernel first" >&2; exit 1; }

if [ ! -d "$AK3_SRC" ]; then
	git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git "$AK3_SRC"
fi

KSU_DESC="$(git -C "$ROOT/KernelSU" describe --tags 2>/dev/null || echo unknown)"
if [ -r "$OUT/include/config/kernel.release" ]; then
	KERNEL_VER="$(cat "$OUT/include/config/kernel.release")"
else
	KERNEL_VER="$(make -s -C "$ROOT" kernelversion)"
fi
NAME="BakaSU-mars-${KERNEL_VER}-${KSU_DESC}"

rm -rf "$STAGE"
mkdir -p "$DIST"
cp -r "$AK3_SRC" "$STAGE"
rm -rf "$STAGE/.git"

cat > "$STAGE/anykernel.sh" <<EOF
### BakaSU kernel for Xiaomi Mi 11 Pro (mars) on LineageOS 23.2
### ${KERNEL_VER} + BakaSU ${KSU_DESC} (manual hook)
## AnyKernel3 by osm0sis @ xda-developers

properties() { '
kernel.string=BakaSU ${KSU_DESC} for Xiaomi Mi 11 Pro (mars) - LineageOS 23.2
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=mars
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
boot_attributes() {
set_perm_recursive 0 0 755 644 \$RAMDISK/*;
set_perm_recursive 0 0 750 750 \$RAMDISK/init* \$RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;

write_boot;
## end boot install
EOF

# Kernel only: ramdisk, dtb and dtbo stay exactly as LineageOS shipped them.
cp "$IMAGE" "$STAGE/Image"

cd "$STAGE"
rm -f "$DIST/${NAME}.zip"
zip -r9 "$DIST/${NAME}.zip" . -x ".git/*" >/dev/null

echo "== created =="
ls -la "$DIST/${NAME}.zip"
