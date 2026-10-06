# BakaSU 集成说明（小米 11 Pro / mars，LineageOS 23.2）

本仓库基于 `LineageOS/android_kernel_xiaomi_sm8350` 的 `lineage-23.2` 分支（内核 `5.4.302`，non-GKI / QGKI），
集成了 [BakaSU](https://github.com/Baka-SU/BakaSU)（KernelSU 下游分支，前身 ReSukiSU）。

## 一、集成了什么

### 1. BakaSU 内核代码

以 git submodule 形式引入（与 BakaSU 官方 `setup.sh` 的做法一致，参考了 miyume 内核的集成方式）：

```
KernelSU/            -> https://github.com/Baka-SU/BakaSU （submodule）
drivers/kernelsu     -> ../KernelSU/kernel （符号链接）
drivers/Makefile     + obj-$(CONFIG_KSU) += kernelsu/
drivers/Kconfig      + source "drivers/kernelsu/Kconfig"
```

更新 BakaSU 版本：

```sh
git submodule update --remote KernelSU
```

### 2. 内核 hook 补丁

内核是 5.4，属于 **non-GKI**，所以选择 **Manual Hook**（`CONFIG_KSU_MANUAL_HOOK=y`），
tracepoint（GKI2/5.10+）模式不可用。

同时关闭了 BakaSU 默认开启的 LSM “自动 hook”（`KSU_MANUAL_HOOK_AUTO_*`），改为在源码里直接埋点
（这是 5.4 上最稳妥的方式，也是 miyume 内核采用的方式）：

| 文件 | 加入的调用 | 作用 |
| --- | --- | --- |
| `fs/exec.c` | `ksu_handle_execveat()` in `do_execveat_common()` | `su` 兼容、模块/root 提权识别 |
| `fs/open.c` | `ksu_handle_faccessat()` in `do_faccessat()` | `su` 路径重定向 |
| `fs/stat.c` | `ksu_handle_stat()` in `vfs_statx()`<br>`ksu_handle_newfstat_ret()` in `SYSCALL_DEFINE2(newfstat)`<br>`ksu_handle_fstat64_ret()` in `SYSCALL_DEFINE2(fstat64)` | 隐藏/伪装 stat 结果（su 检测） |
| `fs/read_write.c` | `ksu_handle_sys_read()` in `SYSCALL_DEFINE3(read)` | init.rc 注入 |
| `kernel/reboot.c` | `ksu_handle_sys_reboot()` + `KSU_REBOOT_MAGIC1 (0xDEADBEEF)` | ksud 安装 fd 的 supercall 通道 |
| `kernel/sys.c` | `ksu_handle_setresuid()` in `__sys_setresuid()` | manager 提权、模块 umount |
| `drivers/input/input.c` | `ksu_handle_input_handle_event()` in `input_event()` | 音量键安全模式检测 |

BakaSU 在编译时会用 `kernel/tools/manual_hook_check.mk` 逐个校验这些埋点是否齐全，
缺任何一个都会直接编译失败 —— 也就是说“编译通过”本身就代表 hook 没有漏。

### 3. defconfig

改动在 `arch/arm64/configs/vendor/xiaomi_QGKI.config`（`TARGET_KERNEL_CONFIG` 的最后一个 fragment）：

```
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
# CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK is not set
# CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK is not set
# CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK is not set
```

### 4. 没有做的东西

- **SUSFS 未启用**。SUSFS 需要在内核侧做大量 backport（`fs/susfs.c` 等），BakaSU 里 `CONFIG_KSU_SUSFS=y`
  之外还必须打 simonpunk 的补丁。当前版本不含 SUSFS，manager 里相关功能会显示不可用。
  需要的话可以后续按 <https://gitlab.com/simonpunk/susfs4ksu> 单独做。
- 未改动设备树 / dtbo / ramdisk，刷机包只替换 boot 分区里的内核 `Image`。

## 二、云编译（GitHub Actions）

`.github/workflows/build-kernel.yml`：push 或手动 `workflow_dispatch` 触发。

- 运行环境 `ubuntu-22.04`
- 工具链用 LineageOS 23.2 对应的 AOSP 预编译 clang `clang-r563880c`（与官方编译一致）
- 配置：`vendor/lahaina-qgki_defconfig` + `vendor/debugfs.config` + `vendor/xiaomi_QGKI.config`，
  `TARGET_PRODUCT=mars`
- 只编译 `Image`（内核本体），不打模块 —— 设备上原有模块继续沿用，因此**不要**改内核版本号/vermagic
- 产物：`BakaSU-mars-anykernel3`（可刷 zip）+ BakaSU manager APK

> 说明：CI 里关掉了 `CONFIG_DEBUG_INFO`（仅调试符号，不影响内核代码与模块兼容性），
> 因为免费 runner 的磁盘/RAM 比较紧张。要完全复刻官方编译可以设 `NO_DEBUG_INFO=0`。

本地同样可以构建：

```sh
# 需要 x86_64 或 aarch64 的 clang-21（AOSP clang-r563880c 或发行版 clang）
export CLANG_DIR=/path/to/clang
./ci/build-kernel.sh       # 生成 out/arch/arm64/boot/Image
./ci/package-anykernel.sh  # 生成 dist/BakaSU-mars-*.zip
```

## 三、刷入

前置：已解锁 BL 的 Mi 11 Pro（mars），已刷 LineageOS 23.2，且 **vbmeta 已禁用校验**
（刷 LineageOS 时正常流程已经做了，否则任何第三方内核都起不来）。

1. 安装 BakaSU manager APK（`ReSukiSU_*_arm64-v8a-release.apk`）。
2. 刷入 `BakaSU-mars-*.zip`（AnyKernel3，只改 boot 分区内核）：
   - 方式 A：LineageOS Recovery → Apply update → adb sideload 或选择 zip；
   - 方式 B：用内核刷写 App（如 Horizon Kernel Flasher / FKM），选 boot 分区刷 zip。
3. 重启，打开 manager，应当显示“已安装 / Working”。

回退：把 LineageOS 原版 `boot.img` 刷回 boot 分区即可（或者重刷一次 ROM zip）。

## 四、兼容性注意

- 本内核只替换 `Image`，**内核版本字符串（vermagic）保持与官方一致**，设备上 `/vendor/lib/modules`
  的模块照常加载。
- 因此请不要修改 `CONFIG_LOCALVERSION`、也不要改 `CONFIG_MODVERSIONS` 等影响模块 ABI 的配置。
- 因为内核版本码（35213）比现成的 manager release（v4.2.0-rc3，35171）新，manager 可能提示
  “内核比管理器新”，属正常，功能不受影响。
