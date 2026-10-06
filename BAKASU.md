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

### 2. 内核 hook（SUSFS inline hook 模式）

内核是 5.4（non-GKI），BakaSU 的 tracepoint（GKI2 / 5.10+）模式不可用。
启用 SUSFS 后 hook 模式取 BakaSU “Hooking Method” choice 的第三项 **SUSFS Inline Hook**
（`CONFIG_KSU_SUSFS=y`，与 `KSU_MANUAL_HOOK` 互斥），埋点如下：

| 文件 | 埋点 | 作用 |
| --- | --- | --- |
| `fs/exec.c` | `ksu_handle_execveat()` / `ksu_handle_execveat_sucompat()` in `do_execveat_common()` | `su` 兼容、模块/root 提权识别 |
| `fs/open.c` | `ksu_handle_faccessat()` in `do_faccessat()` | `su` 路径重定向 |
| `fs/stat.c` | `ksu_handle_stat()` in `vfs_statx()`<br>`ksu_handle_newfstat_ret()` in `SYSCALL_DEFINE2(newfstat)`<br>`ksu_handle_fstat64_ret()` in `SYSCALL_DEFINE2(fstat64)` | 隐藏/伪装 stat 结果（su 检测） |
| `fs/read_write.c` | `ksu_handle_sys_read()` in `SYSCALL_DEFINE3(read)`（static key 控制） | init.rc 注入 |
| `kernel/reboot.c` | `ksu_handle_sys_reboot()` + `KSU_REBOOT_MAGIC1 (0xDEADBEEF)` | ksud 安装 fd 的 supercall 通道 |
| `kernel/sys.c` | `ksu_handle_setresuid()` in `__sys_setresuid()` | manager 提权、模块 umount |
| `drivers/input/input.c` | `ksu_handle_input_handle_event()` in `input_handle_event()`（static key 控制） | 音量键安全模式检测 |

BakaSU 编译时用 `kernel/tools/inline_hook_check.mk` 逐个校验这些埋点，
缺任何一个直接编译失败 —— “编译通过”本身就代表 hook 没漏。

### 3. SUSFS 内核侧移植

BakaSU 只带 KSU 侧接口，SUSFS 内核侧必须自己 backport。
simonpunk 官方仓库的 `kernel-5.4` 分支停在 2025-02，缺少 BakaSU 需要的
`susfs_add_sus_map` / `susfs_show_version` / `susfs_get_enabled_features` 等接口，
因此以 miyume 内核（同样 sm8350 5.4 + ReSukiSU，SUSFS **v2.1.0**）为基准移植，
并补上 v2.3.0 才有的 `TIF_PROC_NO_SU(34)`、`TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT(35)`
线程标志与 `susfs_*_no_su()` / `susfs_set_current_proc_umounted_for_zygote_next()` 辅助函数。

新增文件：`fs/susfs.c`、`include/linux/susfs.h`、`include/linux/susfs_def.h`

改动调用点（19 个既有文件）：
`fs/Makefile`、`fs/exec.c`、`fs/namei.c`、`fs/namespace.c`、`fs/notify/fdinfo.c`、`fs/open.c`、
`fs/proc/base.c`、`fs/proc/cmdline.c`、`fs/proc/fd.c`、`fs/proc/task_mmu.c`、`fs/proc_namespace.c`、
`fs/read_write.c`、`fs/readdir.c`、`fs/stat.c`、`fs/statfs.c`、`kernel/kallsyms.c`、`kernel/sys.c`、
`security/selinux/avc.c`、`drivers/input/input.c`

移植时剔除了参考仓库里与本设备无关的 HyperOS 私有改动（`hwui_mon`、`netbpfload` uname 伪装），
并保留 LineageOS 原有的 VMA padding 行为（`VMA_PAD_START`）。

SUSFS 不修改任何结构体（只用 thread_info flags 与 inode `i_state` 位），所以**不影响模块 ABI**。

### 4. defconfig

改动在 `arch/arm64/configs/vendor/xiaomi_QGKI.config`（`TARGET_KERNEL_CONFIG` 的最后一个 fragment）：

```
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
# CONFIG_KSU_TRACEPOINT_HOOK is not set
# CONFIG_KSU_MANUAL_HOOK is not set
```

### 5. 没有做的东西

- 未改动设备树 / dtbo / ramdisk，刷机包只替换 boot 分区里的内核 `Image`。
- 未包含 `sus_su`（SUSFS 自带的 su 替换实现），Shamiko 支持上游已移除。

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

### 方式一：fastboot 刷 boot.img（推荐，不需要 recovery）

本机 recovery 与内核同在 `boot` 分区，所以直接把 boot 镜像刷进去最省事：

```sh
# 手机进 fastboot（关机后 音量下 + 电源）
fastboot flash boot boot-bakasu-mars.img
fastboot reboot
```

镜像怎么来（`ci/make-bootimg.sh`）：

```sh
# 1) 从官方 OTA 里取出 boot 分区
./payload-dumper-go -p boot -o bootdump lineage-23.2-<date>-nightly-mars-signed.zip

# 2) 用我们的 Image 替换其中的内核（ramdisk / dtb 不动，脚本会校验 ramdisk 一致性）
MAGISKBOOT=/path/to/magiskboot \
  ./ci/make-bootimg.sh bootdump/boot.img out/arch/arm64/boot/Image boot-bakasu-mars.img
```

> magiskboot 可以从 Magisk APK 里取：`unzip Magisk-*.apk 'lib/arm64-v8a/*'`，
> `lib/arm64-v8a/libmagiskboot.so` 就是一个可直接执行的静态 arm64 程序。

### 方式二：recovery 刷 AnyKernel3 zip

1. 安装 **与内核配套** 的 BakaSU manager APK（`ReSukiSU_*_arm64-v8a-release.apk`）。
   版本必须和内核里 KernelSU 子模块的提交一致，否则 manager 会报「需要更新内核」
   （它要求 `KERNEL_SU_UAPI_VERSION` 相等）。本内核对应 **v4.2.0-rc1 / 35061 / UAPI 2**。
2. 刷入 `BakaSU-mars-*.zip`（AnyKernel3，只改 boot 分区内核）：
   - 方式 A：Recovery → Apply update → adb sideload 或选择 zip；
   - 方式 B：用内核刷写 App（如 Horizon Kernel Flasher / FKM），选 boot 分区刷 zip。
3. 重启，打开 manager，应当显示“已安装 / Working”。

> 注意：**LineageOS 官方 recovery 对 `adb sideload` 的包会做签名校验**，未签名的
> AnyKernel3 zip 可能直接报错刷不进去；这种情况请用方式一（fastboot 刷 boot.img）。

回退：把官方原版 `boot.img` 刷回 boot 分区即可（或者重刷一次 ROM zip）。

## 四、兼容性注意（重要）

- 本内核只替换 boot 分区的 `Image`，ramdisk / dtb / dtbo 保持官方不动。
- **内核版本串（UTS_RELEASE）会和官方不同**：本仓库构建出来是
  `5.4.302-qgki-g<本仓库 commit>` —— defconfig 没有关 `CONFIG_LOCALVERSION_AUTO`，
  构建时会按 git 状态追加短 SHA。但这**不影响模块加载**，原因：
  - `CONFIG_MODVERSIONS=y`：内核比对模块 vermagic 时（`same_magic()`，`has_crcs=true`）
    会**跳过第一个字段（版本号）**，只比对 `SMP PREEMPT mod_unload modversions aarch64`；
  - `CONFIG_MODULE_SIG` 未开启，没有签名强制；
  - 我们只新增调用，没有改动任何既有类型/函数签名，所以符号 CRC（`__crc_*`）与官方一致。
  因此 `/vendor/lib/modules` 以及 boot 镜像里的 `BOOT_KERNEL_MODULES`
  （`msm_drm` / `fts_touch_spi` / `qti_battery_charger_main` 等）都能正常加载。
- 反过来：**不要**动 `CONFIG_LOCALVERSION`、`CONFIG_MODVERSIONS`、`CONFIG_MODULE_SIG`、
  `CONFIG_CFI_CLANG`、`CONFIG_LTO_CLANG`、`SMP`/`PREEMPT` 这类影响模块 ABI 的配置，
  否则就真的会出现模块加载失败。
- **KernelSU 子模块与 SUSFS 版本必须"同代配对"**（当前状态：submodule 在 **main**，内核侧
  SUSFS 为 **v2.3.0**，两者配套 ✓）。
  历史教训：
  - BakaSU 在 `03b60f26`（2026-08-23，`kernel: sync with latest susfs`）把 KSU 侧切到**新版
    SUSFS 接口**；如果这时内核侧还是 **v2.1.0**（老接口），内核会**在 userspace 起来之前卡死**
    —— pstore / mtdoops 一个字都没有，表现为开机第一/二屏反复重启。BakaSU 自己也有描述该
    失败模式的补丁（`052ca277`：*“avoid old version of susfs hang in boot”*）。
  - 所以两种可用组合二选一：
    * **新组合（当前）**：KernelSU **main** + 内核侧 **SUSFS v2.3.0**（移植自上游
      `gki-android13-5.10` 分支），manager 用 main 的 nightly（`Manager-release`）或同提交构建；
    * **旧组合（历史）**：KernelSU 钉 `a9216b04`（`v4.2.0-rc1`，版本码 35061 / UAPI 2）+
      内核侧 SUSFS **v2.1.0**（上游 `kernel-5.4` 分支，2025-02-23 起冻结），manager 用 v4.2.0-rc1。
- 内核上报的版本码 = `30000 + KernelSU 提交数 + 700`（main @ 4513 → **35213**）。
  CI 里必须先把 submodule 变成完整克隆，否则浅克隆只数到 1 个提交、上报 30701。
- `KERNEL_SU_UAPI_VERSION`：`a9216b04` → 2，`v4.2.0-rc3` → 4，**main → 5**。
  **内核与 manager 的 UAPI 必须相等**，否则 manager 显示「需要更新内核」（不相等时 su 通常
  仍可用，但 SUSFS 设置页不可用）。main 没有 release tag，官方 release 里没有对应 APK，
  要用 nightly：`https://nightly.link/Baka-SU/BakaSU/workflows/build-manager/main/Manager-release.zip`。

## 四·五、SUSFS v2.1.0 → v2.3.0 的移植要点（2026-10-06 完成）

上游 v2.3.0 只有 5.10+ 的补丁（`gki-android13-5.10` 分支），移植到 5.4 时踩到的点：

- 补丁是「从**干净内核**加 SUSFS」的全量补丁：必须先撤掉旧版 SUSFS 再应用，否则冲突从 16 处
  涨到 43 处；`patch -F3` 的模糊匹配会**猜错位置**（实测 2 处代码被塞进块注释、2 处落进错误
  函数，其中 `show_smap_vma()` 被改成 `return 0;` 会让 void 函数编译失败），应用后必须逐文件复核。
- 5.10 → 5.4 的 API 适配（本树已有的 backport 不用动：`mmap_lock`、`struct selinux_state`、
  `current_uid`、`vfs_getattr`、`d_revalidate`）：
  * `include/linux/susfs_def.h` 需自己补 `<linux/cred.h>`（v2.3.0 在 5.10 靠间接包含）；
  * `struct fsnotify_ops` 在 5.4 是 `handle_event`（8 参），5.10 才是 `handle_inode_event`；
  * `struct kstat` **没有 `mnt_id`**、没有 `STATX_MNT_ID` → SUS_KSTAT 的 mnt_id 欺骗无法移植。
    不要给 `struct kstat` 加字段：`generic_fillattr` / `vfs_getattr` 是 `EXPORT_SYMBOL`，
    改结构体会改变 CRC，可能导致 vendor 模块加载失败（显示/触摸立刻出问题）；
  * `fs/proc/bootconfig.c` 在 5.4 不存在，SPOOF_CMDLINE 由 `fs/proc/cmdline.c` 承担（v2.3.0
    核心导出的 `susfs_spoof_cmdline_or_bootconfig()` 签名一致，无需改）；
  * exec hook 要放 `__do_execve_file()`（5.4 没有 `bprm_execve()`），并且必须在 `putname()`
    **之前**（否则 post hook 读已释放的 `filename->name`）；5.4 独有的 usermode-helper 路径
    （`filename == NULL`）必须加守卫，否则 KernelSU 空指针崩溃；
  * open_redirect：5.4 的 `do_last()` 自己就 `vfs_open()`（5.10 是 `open_last_lookups()` +
    `do_open()` 分离），照抄上游会撞 `BUG_ON(file->f_mode & FMODE_OPENED)` panic →
    改为「命中后重走一遍 + `is_open_redirect_retry` 保证只重定向一次」。代价：`O_CREAT`/
    `O_TRUNC` 这类打开对原路径会多一次副作用（与 v2.1.0 的做法一致）；
  * `security/selinux/selinuxfs.c`：5.4 的 `struct selinux_state` 没有 `status_lock`，同一把锁
    在 `selinux_state.ss->status_lock`（KernelSU 在 `KSU_COMPAT_USE_SELINUX_STATE` 下也用它）；
  * `ksu_handle_sys_read` 只有 3 参版本（`KernelSU/kernel/runtime/ksud_integration.c`）。
- 第一轮验证配置：**SUS_KSTAT 关闭**，其余子功能开启。要开启 SUS_KSTAT 时需注意上面
  `struct kstat` 的限制（`fs/stat.c` 里那两行 `stat->mnt_id = …` 已按 5.4 形态处理掉）。
- 编译迭代经验：CI 里给 `kmake` 加 **`-k`**，一次就能拿到全部编译错误（本次第一轮报 5 类、
  第二轮即零错误通过）。


## 五、这台设备上抓内核 panic 日志（踩坑记录）

排查 SUSFS 卡死时试过的三条路，结论如下（避免以后重复踩）：

- **pstore / ramoops（可用，但要选对内存）**：内核已编 `CONFIG_PSTORE_RAM=y`，可用 cmdline
  驱动：`ramoops.mem_address=… ramoops.mem_size=… ramoops.record_size=… ramoops.console_size=…`。
  但**必须选非 `no-map` 的保留内存**：`no-map` 区域会让 `pfn_valid()` 为假，驱动改走
  `request_mem_region()` 那条路而失败（`/sys/fs/pstore` 一直空）。`splash_region` 虽然符合
  条件但被显示驱动占用，写进去会**破坏启动**（第二屏重启），不要用。
- **mtdoops**：本平台 cmdline 里有 `block2mtd.block2mtd=/dev/block/sda15,2097152 mtdoops.mtddev=0`，
  但 LineageOS 的 defconfig 没开 MTD，且 `block2mtd` 打开 `/dev/block/sda15` 只重试 3 秒
  （设备节点由 ueventd 创建，经常来不及）→ 实际抓不到东西。`/dev/block/sda15` 里的记录是
  HyperOS 时代留下的。
- **`androidboot.init_fatal_panic=1`**：能让 init 出错时直接触发内核 panic（配合上面的日志通道）。

最终结论：这次的卡死发生在 **userspace 之前**，任何内核侧日志通道都抓不到，只能靠
**二分 KernelSU 提交** 定位。

## 六、构建产物验证

- `Image` arm64 头部魔数 `ARMd` 正确，镜像内含 BakaSU 运行时代码（`KernelSU:` 日志串等）
- 本内核（`a9216b04` 钉版）实测：**能正常开机**，manager 显示 `v4.2.0-rc1-a9216b04@ReSukiSU (35061/2)`，
  SuSFS `v2.1.0`，root 正常
- 可刷 zip：`device.name1=mars`、`do.devicecheck=1`、`BLOCK=boot`、`IS_SLOT_DEVICE=1`、`do.modules=0`

