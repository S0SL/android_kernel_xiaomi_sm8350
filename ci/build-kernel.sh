#!/usr/bin/env bash
#
# Build the LineageOS android_kernel_xiaomi_sm8350 kernel (5.4 QGKI)
# with BakaSU integrated, for the Xiaomi Mi 11 Pro (mars).
#
# Designed to run on a x86_64 GitHub Actions runner:
#   CLANG_DIR=<aosp clang-r563880c> ./ci/build-kernel.sh
#
# Env:
#   CLANG_DIR         clang prebuilt directory (must contain bin/clang)
#   OUT               output dir, default <repo>/out
#   JOBS              parallel jobs, default nproc
#   NO_DEBUG_INFO     1 (default) drops CONFIG_DEBUG_INFO: build-time only,
#                     does not change the generated kernel code, saves RAM/disk
#   MAKE_TARGET       default "Image" (kernel image only, no modules needed
#                     for a kernel-only AnyKernel3 zip)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT:-$ROOT/out}"
CLANG_DIR="${CLANG_DIR:-$ROOT/toolchain/clang}"
JOBS="${JOBS:-$(nproc)}"
NO_DEBUG_INFO="${NO_DEBUG_INFO:-1}"
MAKE_TARGET="${MAKE_TARGET:-Image}"

export PATH="$CLANG_DIR/bin:$PATH"

BASE_CONFIG="vendor/lahaina-qgki_defconfig"
FRAGMENTS=(
	"vendor/debugfs.config"
	"vendor/xiaomi_QGKI.config"
)

# TARGET_PRODUCT=mars mirrors LineageOS' TARGET_KERNEL_ADDITIONAL_FLAGS
# for the Xiaomi Mi 11 Pro.
MAKE_BASE=(
	-C "$ROOT"
	O="$OUT"
	ARCH=arm64
	LLVM=1
	CROSS_COMPILE=aarch64-linux-gnu-
	TARGET_PRODUCT=mars
)

kmake() { make "${MAKE_BASE[@]}" "$@"; }

echo "== toolchain =="
clang --version | head -1
echo "== kernel =="
make -s -C "$ROOT" kernelversion

echo
echo "== [1/3] base defconfig: $BASE_CONFIG =="
mkdir -p "$OUT"
cp "$ROOT/arch/arm64/configs/$BASE_CONFIG" "$OUT/.config"
kmake olddefconfig >/dev/null

echo "== [2/3] merging LineageOS config fragments =="
for fragment in "${FRAGMENTS[@]}"; do
	echo "-- $fragment"
	"$ROOT/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" \
		"$ROOT/arch/arm64/configs/$fragment" >/dev/null
	kmake olddefconfig >/dev/null
done

echo "== [3/3] enabling BakaSU (SUSFS inline hook mode) =="
# The kernel is 5.4 (non-GKI), so the tracepoint (GKI2) hook is unusable and
# the manual hook path is selected instead. The LSM based "auto" hooks are
# disabled, the three call sites are patched directly in the kernel sources:
#   kernel/sys.c        -> ksu_handle_setresuid
#   fs/read_write.c     -> ksu_handle_sys_read
#   drivers/input/input.c -> ksu_handle_input_handle_event
"$ROOT/scripts/config" --file "$OUT/.config" \
	-e KSU \
	-e KSU_SUSFS \
	-d KSU_TRACEPOINT_HOOK \
	-d KSU_MANUAL_HOOK \
	-e KSU_SUSFS_SUS_PATH \
	-e KSU_SUSFS_SUS_MOUNT \
	-e KSU_SUSFS_SUS_KSTAT \
	-e KSU_SUSFS_SPOOF_UNAME \
	-e KSU_SUSFS_ENABLE_LOG \
	-e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
	-e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
	-e KSU_SUSFS_OPEN_REDIRECT \
	-e KSU_SUSFS_SUS_MAP

if [ "$NO_DEBUG_INFO" = "1" ]; then
	echo "-- disabling CONFIG_DEBUG_INFO (debug symbols only)"
	"$ROOT/scripts/config" --file "$OUT/.config" \
		-d DEBUG_INFO -d DEBUG_INFO_DWARF4
fi

kmake olddefconfig >/dev/null

echo
echo "== BakaSU config =="
grep -E "^CONFIG_KSU|^# CONFIG_KSU" "$OUT/.config" | sed 's/^/  /'

grep -q "^CONFIG_KSU=y" "$OUT/.config" || { echo "ERROR: CONFIG_KSU is not set" >&2; exit 1; }
grep -q "^CONFIG_KSU_SUSFS=y" "$OUT/.config" || { echo "ERROR: CONFIG_KSU_SUSFS is not set" >&2; exit 1; }

echo
echo "== building '$MAKE_TARGET' (jobs=$JOBS) =="
kmake -j"$JOBS" "$MAKE_TARGET"

echo
echo "== artifacts =="
ls -la "$OUT/arch/arm64/boot/Image"
