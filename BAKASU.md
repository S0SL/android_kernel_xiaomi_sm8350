# BakaSU + SUSFS 内核 · 接手文档

> ⚠️ **非官方构建（Unofficial），刷入有风险。** 使用前请阅读 [免责声明](DISCLAIMER.md)。


> 项目说明见本文档。仓库根的 `README.md` 是 LineageOS 上游原文，未改动。
> 分支 `lineage-23.2` · 内核 `5.4.302-qgki` · 文档更新 2026-11-23（基线提交 `797c093f`）

小米 11 Pro（`mars`，SM8350）在 LineageOS 23.2 上使用的**自制内核**：在 LineageOS 官方
5.4 QGKI 内核上集成 **BakaSU**（KernelSU 下游分支）与 **SUSFS v2.3.0**，由 GitHub Actions
自动产出可刷写产物。本文是唯一的接手入口，包含已完成的工作、踩过的坑、以及还没做的事。

---

## 0. 一屏速查

| 项目 | 值 |
| --- | --- |
| 仓库 | `S0SL/android_kernel_xiaomi_sm8350`（fork 自 `LineageOS/android_kernel_xiaomi_sm8350`） |
| 分支 | 只有 `lineage-23.2`（默认分支） |
| 内核 | Linux `5.4.302` + `CONFIG_LOCALVERSION="-qgki"`（non-GKI / QGKI 树，`arch/arm64`） |
| 机型 / ROM | 小米 11 Pro（`mars`）/ LineageOS 23.2（Android 16） |
| BakaSU | 子模块 `KernelSU/` → `https://github.com/Baka-SU/BakaSU`，钉在 `61e2ce83` |
| KernelSU 版本码 | `30000 + 4513 + 700 = 35213`；`KERNEL_SU_UAPI_VERSION = 5` |
| SUSFS | 内核侧 `v2.3.0`（从上游 `gki-android13-5.10` 反向移植到 5.4） |
| CI | `.github/workflows/build-kernel.yml` + `ci/build-kernel.sh` + `ci/package-anykernel.sh` |
| 产物 | AnyKernel3 zip、`boot.img`（fastboot 直刷）、配套管理器 APK |
| 最新 Release | [`boot-img-LOS23.2-20260930-bakasu`](https://github.com/S0SL/android_kernel_xiaomi_sm8350/releases/tag/boot-img-LOS23.2-20260930-bakasu) |
| 状态 | **已实测可用**：能开机、root 正常、SUSFS 全链路工作、CI 能出包 |

### 已完成 / 待办（先看这两张表）

**已完成**

- [x] BakaSU 以 submodule 方式接入，SUSFS inline hook 埋点全部打通
- [x] SUSFS 从 v2.1.0 升到 **v2.3.0**（5.10 → 5.4 反向移植：122 hunk / 16 处手工合并 / 5 处 `-F3` 错位纠正）
- [x] 5.4 适配点全部收敛（fsnotify 回调、`struct kstat` 无 `mnt_id`、bootconfig、`do_last()`、`selinux_state`、KSU 三参读钩子、`__do_execve_file()`）
- [x] KernelSU 子模块从旧 pin（`a9216b04`）升到 main（`61e2ce83`）
- [x] `CONFIG_KSU_SUSFS_SUS_KSTAT=y` 打开，并把 `fdinfo` 的伪造输出与 5.4 原生字段对齐
- [x] CI：push / 手动触发即产出 **AnyKernel3 zip + boot.img + 配套管理器 APK**
- [x] 真机验证：内核启动、root、SUSFS 各子功能、管理器配套
- [x] 仓库整理与本文档；备份标签保留

**待办**（详见 [§11](#11-待办清单)）

- [ ] 跟进 BakaSU main（pin 之后又前进了 72 个提交，含 SUSFS 接口大改）——**升级前必须重做移植与验证**
- [ ] 管理器版本码与内核自报差 2（35215 vs 35213，UAPI 相同，可用但不严谨）
- [ ] `ci/package-anykernel.sh` 里 `(manual hook)` 字样已过期（实际是 SUSFS inline hook）
- [ ] `ci/make-bootimg.sh`（本地）与 workflow 内联 repack 逻辑重复，改一处要同步另一处
- [ ] 日志通道仍不可靠（ramoops 不可用、mtdoops 时序问题），开机卡死只能二分
- [ ] 产物不含内核模块（`do.modules=0`），自编模块需求未做

---

## 1. 这是什么

### 1.1 基线

- 上游：`LineageOS/android_kernel_xiaomi_sm8350`，分支 `lineage-23.2`
- 内核：Linux `5.4.302`，高通 QGKI 树（`vendor/lahaina-qgki_defconfig`）
- 设备：小米 11 Pro（`mars`，代号来自 `TARGET_PRODUCT=mars`），LineageOS 23.2（Android 16）

### 1.2 集成了什么

1. **BakaSU**（[`Baka-SU/BakaSU`](https://github.com/Baka-SU/BakaSU)，KernelSU 的下游分支，前身 ReSukiSU）：
   以 git submodule 引入，钉在 `61e2ce83`（2026-10-06，`manager: Update maven group in manager (#462)`）。
2. **SUSFS v2.3.0** 内核侧代码：BakaSU 只带 KernelSU 侧接口，SUSFS 的 `fs/susfs.c` 等必须自己
   反向移植到 5.4。
3. **设备配置片段**：`arch/arm64/configs/vendor/xiaomi_QGKI.config` 里打开 `CONFIG_KSU*` 与 MTD 日志。
4. **CI**：GitHub Actions 编译 + 打包 + 抓配套管理器，产出可直刷的 zip / img。

### 1.3 适用条件

- 已解锁 BL、已禁用 vbmeta 校验、已刷 LineageOS 23.2 的小米 11 Pro（`mars`）
- **只替换 boot 分区里的内核 `Image`**，ramdisk / dtb / dtbo 保持 ROM 原样

---

## 2. 当前状态（已实测）

以下都是真机上验证过的，不是"编译通过"而已：

| 验证项 | 结果 |
| --- | --- |
| 内核启动 | 正常进系统（`uname -r` = `5.4.302-qgki-g<commit>`） |
| root | 管理器显示已安装，`su` 可用 |
| SUSFS | 管理器问内核 `susfs_show_version` / `susfs_show_enabled_features` / `susfs_show_variant`，返回 `ret: 0` |
| 子功能 | SUS_PATH / SUS_MOUNT / SUS_KSTAT（除 `mnt_id`）/ SPOOF_UNAME / SPOOF_CMDLINE / OPEN_REDIRECT / SUS_MAP 均可用 |
| 模块兼容 | `/vendor/lib/modules` 与 boot 里的 `BOOT_KERNEL_MODULES`（显示、触摸、充电）正常加载 |
| CI | push 与手动触发都能产出 AnyKernel3 zip + boot.img + 管理器 APK |
| Release | 4 个资产齐全（见 [§10](#10-release-与资产)） |

验证命令（刷完后在手机上跑）：

```sh
uname -r                     # 期望 5.4.302-qgki-g<当前构建 commit>
dmesg | grep -i susfs        # 期望看到 susfs version / susfs enabled features 且 ret: 0
```

---

## 3. 仓库结构、分支与标签

### 3.1 目录结构（只列与本项目相关的部分）

```
.
├── BAKASU.md                     # 本文档（接手入口）
├── README.md                     # LineageOS 上游原文，未改动
├── .gitmodules                   # KernelSU 子模块：Baka-SU/BakaSU
├── .github/workflows/build-kernel.yml   # CI 主流程
├── ci/
│   ├── build-kernel.sh           # 配置合并 + 编译 Image
│   ├── package-anykernel.sh      # 打 AnyKernel3 zip
│   └── make-bootimg.sh           # 本地版：把 Image 塞进官方 boot.img
├── KernelSU/                     # submodule，指向 Baka-SU/BakaSU 的 61e2ce83
├── drivers/
│   ├── kernelsu -> ../KernelSU/kernel   # 符号链接（CONFIG_KSU 时递归进子模块）
│   ├── Kconfig                   # + source "drivers/kernelsu/Kconfig"
│   └── Makefile                  # + obj-$(CONFIG_KSU) += kernelsu/
├── fs/
│   ├── susfs.c                   # SUSFS 内核实现（新文件）
│   └── ...                       # exec/namei/open/stat/readdir/statfs/... 里的调用点
├── include/linux/
│   ├── susfs.h                   # SUSFS 版本与对外接口（新文件）
│   └── susfs_def.h               # SUSFS 内部宏/线程标志（新文件）
└── arch/arm64/configs/vendor/xiaomi_QGKI.config   # 设备片段：KSU/SUSFS/MTD 开关
```

SUSFS 在既有文件里改了 19 个调用点：`fs/Makefile`、`fs/exec.c`、`fs/namei.c`、`fs/namespace.c`、
`fs/notify/fdinfo.c`、`fs/open.c`、`fs/proc/base.c`、`fs/proc/cmdline.c`、`fs/proc/fd.c`、
`fs/proc/task_mmu.c`、`fs/proc_namespace.c`、`fs/read_write.c`、`fs/readdir.c`、`fs/stat.c`、
`fs/statfs.c`、`kernel/kallsyms.c`、`kernel/sys.c`、`security/selinux/avc.c`、`drivers/input/input.c`。
v2.3.0 移植时另加了 `fs/super.c`、`security/selinux/hooks.c`、`security/selinux/selinuxfs.c`、`mm/memory.c`。

### 3.2 分支

只有一条：`lineage-23.2`（默认分支）。没有 feature 分支、没有 `main`。所有改动都直接推到这里。

### 3.3 三个标签的用途（**保留，别删**）

| 标签 | 指向 | 用途 |
| --- | --- | --- |
| `backup-lineage-23.2-orig` | `4e223c65`（`remove permission test file`） | 打 BakaSU 之前的 **LineageOS 原树状态**。用来对照"哪些是后加的"：`git diff backup-lineage-23.2-orig HEAD`；也可整体回退到纯原生内核树 |
| `backup-bakasu-before-rename` | `797c093f`（当前整理前的 HEAD） | **改名/整理前的 BakaSU 状态**快照（CI 已能出包的那一版）。整理后若发现问题，可用它回到"整理前" |
| `boot-img-LOS23.2-20260930-bakasu` | `34c6fac0`（SUSFS 首次移植完成） | 2026-09-30 那次 Release 的构建点，Release 页面用的就是这个 tag |

恢复方法（示例，按需选用）：

```sh
git switch -c restore-orig backup-lineage-23.2-orig     # 从原树拉一条临时分支
git diff backup-lineage-23.2-orig HEAD -- fs/ drivers/   # 只看 SUSFS/BakaSU 的改动
git restore --source=backup-bakasu-before-rename --worktree BAKASU.md   # 单文件回退
```

> 注意：这些是**轻量标签**（直接指向 commit）。如果哪天重写了历史，标签也会跟着失效，
> 需要按新 SHA 重新打。

---

## 4. 已完成的关键工作

### 4.1 BakaSU 接入（子模块 + 符号链接 + hook 埋点）

```sh
git submodule update --init --recursive    # 第一次
git -C KernelSU rev-parse --short HEAD     # 应为 61e2ce83
```

接线方式（与 BakaSU 官方 `setup.sh` 一致）：

```
KernelSU/            -> https://github.com/Baka-SU/BakaSU （submodule）
drivers/kernelsu     -> ../KernelSU/kernel （符号链接）
drivers/Makefile     + obj-$(CONFIG_KSU) += kernelsu/
drivers/Kconfig      + source "drivers/kernelsu/Kconfig"
```

5.4 是 non-GKI，BakaSU 的 tracepoint（GKI2 / 5.10+）hook 不可用；开 SUSFS 后走
**SUSFS Inline Hook**（`CONFIG_KSU_SUSFS=y`，与 `CONFIG_KSU_MANUAL_HOOK` 互斥）。埋点：

| 文件 | 埋点 | 作用 |
| --- | --- | --- |
| `fs/exec.c` | `ksu_handle_execveat()` / `ksu_handle_execveat_sucompat()` / `ksu_handle_post_execveat_sucompat()`，在 `__do_execve_file()` 内、`putname()` 之前 | `su` 兼容、提权识别 |
| `fs/open.c` | `ksu_handle_faccessat()` in `do_faccessat()` | `su` 路径重定向 |
| `fs/stat.c` | `ksu_handle_stat()` in `vfs_statx()`、`ksu_handle_newfstat_ret()`、`ksu_handle_fstat64_ret()` | 隐藏/伪装 stat |
| `fs/read_write.c` | `ksu_handle_sys_read(fd, &buf, &count)` in `SYSCALL_DEFINE3(read)`（static key 控制） | init.rc 注入 |
| `kernel/reboot.c` | `ksu_handle_sys_reboot()` + `KSU_REBOOT_MAGIC1` | ksud 安装通道 |
| `kernel/sys.c` | `ksu_handle_setresuid()` in `__sys_setresuid()` | 管理器提权、模块 umount |
| `drivers/input/input.c` | `ksu_handle_input_handle_event()` in `input_handle_event()`（static key 控制） | 音量键安全模式 |

BakaSU 编译时用 `kernel/tools/inline_hook_check.mk` 逐个校验这些埋点，**缺一个就编译失败**——
所以"CI 编译通过"本身就证明 hook 没漏。

### 4.2 SUSFS v2.3.0 反向移植（5.10 → 5.4）

背景：SUSFS 官方 `kernel-5.4` 分支早在 2025-02 就冻结在 **v2.1.0**，缺 BakaSU 需要的
`susfs_add_sus_map` / `susfs_show_version` / `susfs_get_enabled_features` 等接口；
v2.3.0 只提供 `gki-android13-5.10` 的补丁。所以必须自己做反向移植。

过程（可复用的经验）：

1. **先撤掉旧 SUSFS 得到干净底座**，再应用新补丁。否则冲突从 16 处涨到 43 处。
2. 从上游 `gki-android13-5.10` 按提交导出补丁，统计 **122 hunk / 24 文件**。
3. 按文件 `patch -p1 -F3` 分批打：**113 hunk 自动命中，16 处 reject 手工合并**；
   `-F3` 的模糊匹配造成 **5 处静默错位**，必须人工复核（见下）。
4. `fs/susfs.c`、`include/linux/susfs.h`、`include/linux/susfs_def.h` 直接整文件替换为新版，
   再补 5.4 缺失的 include/宏。
5. 每个 hunk 落位后确认：**它落在哪个函数里、函数返回类型对不对、有没有掉进块注释**。
6. 编译收敛（见 §4.7）→ 真机验证。

`-F3` 静默错位的真实案例（以后移植必查）：

| 现象 | 根因 | 检查方法 |
| --- | --- | --- |
| 编译过但功能异常、莫名 `BUG_ON` | hunk 被塞进**块注释**里 | `grep -n susfs <file>` 看是否落在 `/* ... */` 内 |
| `ksu_handle_vfs_fstat` 永远返回 `-EINVAL` | 钩子插在某条 `return -EINVAL;` 之后 | 看钩子调用是否在 return 之后 |
| void 函数 `show_smap_vma()` 里出现 `return 0;` | 上下文匹配把别的函数尾巴拼进来 | `make -k` 报 `return with a value in void function` |
| `atomic_open()` 里出现 `ND_STATE_OPEN_ORDER` | 上游同名变量 5.4 不存在 | 编译报未声明 |
| `__lookup_slow()` 里 `dput` 顺序不对 | 上下文错位 | 人工比对函数前后 10 行 |

> 通用做法：每个 reject 手工合完 `git diff` 逐块读一遍，别只看"编译过了"。

### 4.3 5.10 → 5.4 适配点清单（本次全部踩过并解决）

| 子系统 | 5.10（上游补丁写法） | 5.4 实际 | 处理方式 |
| --- | --- | --- | --- |
| fsnotify 回调 | `fsnotify_ops.handle_inode_event`（6 参） | 只有 `handle_event`（8 参） | `#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,9,0)` 两套并存，`fs/susfs.c` 里两种签名都保留 |
| `struct kstat` | 有 `mnt_id`，有 `STATX_MNT_ID` | **都没有** | 相关代码删掉并留注释；**绝不给结构体加字段**（见 §5） |
| bootconfig | `fs/proc/bootconfig.c` | 文件不存在 | `SPOOF_CMDLINE_OR_BOOTCONFIG` 改由 `fs/proc/cmdline.c` 承接（导出的 `susfs_spoof_cmdline_or_bootconfig()` 签名一致） |
| `do_last()` | `open_last_lookups()` + `do_open()` 分离 | `do_last()` 内部就 `vfs_open()` | open_redirect 改成"命中后重走一遍 + 一次性重定向标记"，否则撞 `BUG_ON(file->f_mode & FMODE_OPENED)` |
| SELinux | `selinux_state.status_lock` | 成员在 `selinux_state.ss->status_lock` | 以本树 `security/selinux/` 实际定义为准，必要时 `#include "ss/services.h"` |
| KSU 读钩子 | `ksu_handle_sys_read(fd, buf, count)` 三参 | 三参（`KernelSU/kernel/runtime/ksud_integration.c`） | 用三参声明；用 `#ifdef CONFIG_KSU_SUSFS ... #elif defined(CONFIG_KSU)` 分开写，避免调用两次 |
| exec 钩子 | `do_execveat_common()` 里 | `__do_execve_file()`，且 `filename` 可能为 `NULL`（usermode-helper） | 钩子必须在 `putname()` **之前**，并对 `filename == NULL` 加守卫 |
| 线程标志 | v2.3.0 新增 | 5.4 没有这些标志 | 补 `TIF_PROC_NO_SU(34)`、`TIF_PROC_UMOUNTED_FOR_ZYGOTE_NEXT(35)` 与 `susfs_*_no_su()` 等辅助函数 |
| 头文件依赖 | v2.3.0 靠 5.10 间接包含 | 5.4 不包含 | `include/linux/susfs_def.h` 补回 `<linux/version.h>`、`<linux/cred.h>`（否则 `current_uid()` 隐式声明） |

### 4.4 SUS_KSTAT 打开 + fdinfo 字段对齐

- `arch/arm64/configs/vendor/xiaomi_QGKI.config` 里把 `CONFIG_KSU_SUSFS_SUS_KSTAT` 从
  `not set` 改成 `=y`。5.4 上它只缺 `mnt_id` 部分，其余（fillattr / inotify fdinfo / proc fd /
  statfs 欺骗）都可用。
- `fs/proc/fd.c`：SUS_KSTAT / SUS_MOUNT 的伪造路径原本打印 `pos/flags/mnt_id/ino`，而正常路径
  只打印 `pos/flags/mnt_id`（`ino:` 是 5.10 才有的字段）——多出来的字段会被检测到"这个 fd 被伪造了"。
  现在两条路径**统一打印三个字段**。

### 4.5 KernelSU 子模块：从旧 pin 升到 main

- 最初：子模块跟 main，但内核侧 SUSFS 还是旧的 v2.1.0 接口。
- 症状：**新 KernelSU + 旧 SUSFS = 开机卡死**（细节见 §9.1）。
- 排查：先把子模块钉回 `a9216b04`（BakaSU 切"新 SUSFS 接口"之前的提交），确认能开机。
- 收尾：把内核侧 SUSFS 升到 v2.3.0（§4.2），再把子模块升回 main 的 `61e2ce83` —— 两者同代，正常开机。
- 现在：子模块 = main 的 `61e2ce83`，内核侧 = SUSFS v2.3.0，配套管理器版本见下表。

版本码与 UAPI（**管理器必须对得上**）：

| 项 | 值 | 来源 |
| --- | --- | --- |
| 提交数 | `4513` | `git -C KernelSU rev-list --count HEAD` |
| 内核版本码 | `30000 + 4513 + 700 = 35213` | `KernelSU/kernel/Kbuild` |
| `KERNEL_SU_UAPI_VERSION` | `5` | `uapi/supercall.h`（BakaSU 仓库根目录） |
| 配套管理器 | `BakaSU v4.2.0-rc3`，版本码 `35215` | Release 里的 APK 文件名 |
| 版本串 | `v4.2.0-rc3-42-g61e2ce83` | `git -C KernelSU describe --tags` |

> 管理器 35215 比内核自报的 35213 大 2：CI 抓的是 main 当时的 HEAD，比 pin 多 2 个
> **只改 manager** 的提交，UAPI 仍是 5，所以能正常工作。要绝对一致就在 CI 里钉死管理器来源。

### 4.6 CI 完善

`.github/workflows/build-kernel.yml`：

- 触发：`push`（任意分支，但 `paths-ignore: "**.md"`）、`workflow_dispatch`、`pull_request`
- runner `ubuntu-22.04`，AOSP clang `clang-r563880c`（`android-16.0.0_r4`，与 LineageOS 23.2 一致），
  带 `actions/cache` 缓存工具链
- **先把 BakaSU 子模块 unshallow**：否则 `rev-list --count` 只有 1，内核自报 `30701`，管理器会报"需要更新内核"
- 编译用 `make -k`：一次拿到全部编译错误
- 三个产物：
  1. `BakaSU-mars-<kernelver>-<ksu describe>.zip` —— AnyKernel3（`device.name1=mars`、`BLOCK=boot`、`IS_SLOT_DEVICE=1`、`do.modules=0`）
  2. `boot-bakasu-mars.img` —— 用 magiskboot 把新 `Image` 塞进官方 boot（**校验 ramdisk sha256 未变**，`continue-on-error`）
  3. 管理器 APK —— 先按 tag 找 release 资产，失败再回退 nightly
     （`https://nightly.link/Baka-SU/BakaSU/workflows/build-manager/main/Manager-release.zip`）

### 4.7 编译错误收敛（5 处）

首轮 CI 报 5 组错误，全部是 5.10-vs-5.4（或 KernelSU-main）不匹配：

1. `include/linux/susfs_def.h` 缺 `<linux/cred.h>` → `current_uid()` 隐式声明
2. `fs/susfs.c` 的 `fsnotify_ops` 没有 `handle_inode_event` → 按版本分两套签名
3. `fs/exec.c` 的 SUSFS extern 块在使用点之后 → 移到 `__do_execve_file()` 之前，签名对齐 KernelSU main
4. `fs/read_write.c` 的 `ksu_handle_sys_read` 多参数 → 改成三参，并用 `#elif` 防止重复调用
5. `security/selinux/selinuxfs.c` 的 `status_lock` 成员不存在 → 用 `selinux_state.ss->status_lock`

第二轮即零错误。经验：**`make -k` + 按"文件+错误类型"分组批量改**，比逐个改快一个数量级。

---

## 5. 已知限制与取舍（含红线）

### 5.1 `SUS_KSTAT` 的 `mnt_id` 部分无法移植

- 5.4 的 `struct kstat` **没有 `mnt_id`**，也没有 `STATX_MNT_ID`。
- 想让 `mnt_id` 也伪造，只能给 `struct kstat` 加字段 —— **绝对不行**：
  `generic_fillattr()` / `vfs_getattr()` 等都是 `EXPORT_SYMBOL`，改结构体会改导出符号 CRC，
  vendor 模块（`msm_drm`、触摸、充电）加载失败 → 开机黑屏/触摸失灵。

### 5.2 open_redirect 在 5.4 的语义差异

5.4 的 `do_last()` 自己就完成 `vfs_open()`，没有 5.10 的"查找"与"打开"分离。因此实现是
"命中后重走一遍 open + `is_open_redirect_retry` 标记保证只重定向一次"。
**代价**：`O_CREAT` / `O_TRUNC` 这类打开对原路径可能多一次副作用（与 v2.1.0 同款做法）。

### 5.3 不要动的配置（会破坏模块 ABI）

- `CONFIG_LOCALVERSION`、`CONFIG_LOCALVERSION_AUTO`（版本串差异本身不影响模块加载，见下）
- `CONFIG_MODVERSIONS`、`CONFIG_MODULE_SIG`、`CONFIG_CFI_CLANG`、`CONFIG_LTO_CLANG`、`SMP`/`PREEMPT`

为什么版本串不同也能加载 ROM 自带模块：`CONFIG_MODVERSIONS=y` 时 `same_magic()`（`has_crcs=true`）
**跳过第一个字段（版本号）**，只比对 `SMP PREEMPT mod_unload modversions aarch64`；且
`CONFIG_MODULE_SIG` 未开、我们没有改任何既有类型/函数签名，`__crc_*` 与官方一致。

反过来：**不许为了编译通过给导出函数加参数/改返回类型，也不许在 `struct cred` / `task_struct`
这类核心结构体里顺手加字段** —— 都是 CRC 红线。

### 5.4 其它取舍

- **不含 `sus_su`**（SUSFS 自带的 su 替换实现），Shamiko 支持上游已移除。
- **产物不含内核模块**（`do.modules=0`）：只替换 `Image`，触摸/显示模块仍用 ROM 自带的
  （设备片段里 `CONFIG_TOUCHSCREEN_*` 依然是 `not set`）。
- **vermagic 带构建 commit**：我们自己编的模块装不进官方 ROM 的内核，反之亦然（模组需求见 §11）。

---

## 6. 如何构建

> 本仓库只出 `Image`（内核本体）+ 打包，不编内核模块。

### 6.1 GitHub Actions（推荐）

- push 到任意分支（`.md` 改动除外）或手动 `workflow_dispatch` 即触发
- Actions 页面下载产物：
  - `BakaSU-mars-anykernel3`（含 `*.zip` 与 `*.img`）
  - `BakaSU-manager-apk`（配套管理器）
- 只改文档不会触发构建：`paths-ignore: "**.md"`；提交信息里再加 `[skip ci]` 做双保险

### 6.2 本地构建

```sh
# 依赖：build-essential bc bison flex libssl-dev libelf-dev cpio rsync zip unzip
# 工具链：AOSP clang-r563880c（Android 16 / LineageOS 23.2 用的就是它）
git submodule update --init --recursive
git -C KernelSU fetch --unshallow --tags    # 否则版本码算成 30701

CLANG_DIR=/path/to/clang-r563880c ./ci/build-kernel.sh    # 产物 out/arch/arm64/boot/Image
./ci/package-anykernel.sh                                 # 产物 dist/BakaSU-mars-*.zip
```

`ci/build-kernel.sh` 做的事（手敲等价）：

```sh
export PATH=/path/to/clang-r563880c/bin:$PATH
MAKEFLAGS_K=(O=out ARCH=arm64 LLVM=1 CROSS_COMPILE=aarch64-linux-gnu- TARGET_PRODUCT=mars)

# 1) 基础 defconfig（三段叠加的第一段）
make "${MAKEFLAGS_K[@]}" vendor/lahaina-qgki_defconfig
# 2) 叠加 debugfs.config 与 xiaomi_QGKI.config
scripts/kconfig/merge_config.sh -m -O out out/.config arch/arm64/configs/vendor/debugfs.config
scripts/kconfig/merge_config.sh -m -O out out/.config arch/arm64/configs/vendor/xiaomi_QGKI.config
# 3) 收敛配置并编译（-k：一次收集全部错误）
make "${MAKEFLAGS_K[@]}" olddefconfig
make "${MAKEFLAGS_K[@]}" -k -j"$(nproc)" Image
```

环境变量：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `CLANG_DIR` | `$ROOT/toolchain/clang` | clang 目录（需含 `bin/clang`） |
| `OUT` | `$ROOT/out` | 输出目录 |
| `JOBS` | `nproc` | 并行度 |
| `NO_DEBUG_INFO` | `1` | 去掉 `CONFIG_DEBUG_INFO`（只影响调试符号，不改生成代码，省内存/磁盘） |
| `MAKE_TARGET` | `Image` | 需要模块时可设 `"Image modules"` |

配置是**三段叠加**：`vendor/lahaina-qgki_defconfig` + `vendor/debugfs.config` +
`vendor/xiaomi_QGKI.config`（最后一段是设备/功能开关，SUSFS 就在里面）。改功能就是往第三段加 `CONFIG_*`。

编完自检：

```sh
grep -E '^CONFIG_KSU|^# CONFIG_KSU' out/.config      # KSU/SUSFS 是否都是 =y
grep KSU_SUSFS out/.config
```

### 6.3 产物长什么样

- `Image`：arm64 头部魔数 `ARMd`，内含 BakaSU 运行时代码（`KernelSU:` 等字符串）
- AnyKernel3 zip：`Image` + `anykernel.sh`（`device.name1=mars`、`do.devicecheck=1`、`BLOCK=boot`、
  `IS_SLOT_DEVICE=1`、`do.modules=0`、`do.systemless=0`）
- `boot.img`：官方 boot 的 ramdisk/dtb 原样 + 我们的 `Image`（打包脚本会校验 ramdisk sha256）

---

## 7. 如何刷入

前置：解锁 BL、vbmeta 校验已禁用、当前是 LineageOS 23.2。

### 7.1 试机：`fastboot boot`（不写分区，推荐先这样）

```sh
adb reboot bootloader
fastboot boot boot-bakasu-mars.img    # 只加载到内存，重启即恢复原内核
```

能开机、root 正常，再决定是否持久刷入。

### 7.2 持久：`fastboot flash boot`

```sh
fastboot flash boot boot-bakasu-mars.img
fastboot reboot
```

> 本机 recovery 与内核同在 `boot` 分区，所以刷 boot 就是刷内核。
> 回退：`fastboot flash boot boot-stock-LOS23.2-20260930.img`（Release 里那份原版 boot，解压自 `boot-stock-LOS23.2-20260930.zip`）。

### 7.3 AnyKernel3 zip（recovery / 内核刷写 App）

1. 先装**配套**管理器 APK（UAPI 必须与内核相等，见 §4.5）。
2. 选一种方式刷 `anykernel3-BakaSU-susfs-v2.3.0-mars.zip`：
   - 内核刷写 App（KernelFlash / Horizon Kernel Flasher / FKM）→ 选 boot 分区刷 zip；
   - 第三方 recovery → 直接刷 zip。
3. 重启，打开管理器应显示"已安装 / 工作中"。

> LineageOS 官方 recovery 对 `adb sideload` 的包做签名校验，未签名的 AnyKernel3 可能被拒；
> 这种情况用 §7.1 / §7.2 的 fastboot 方式。

### 7.4 管理器版本必须与内核 UAPI 一致

- 内核 `KERNEL_SU_UAPI_VERSION = 5`（`61e2ce83`）
- 管理器 APK：`BakaSU_v4.2.0-rc3_35215-manager.apk`
- 不匹配的症状：管理器显示"需要更新内核"（`su` 通常还能用，但 SUSFS 设置页不可用）

---

## 8. 如何更新 SUSFS / KernelSU

### 8.1 配对规则（最重要）

`管理器 ↔ KernelSU commit ↔ UAPI 版本 ↔ SUSFS 大版本` 四者必须**同一世代**。
跨世代通常不是"少个功能"，而是**根本起不来**（见 §9.1）。

| 现象 | 根因 | 处理 |
| --- | --- | --- |
| 第一屏无限重启，pstore/mtdoops 一条记录都没有 | 新 KernelSU 侧 + 旧 SUSFS 侧（钩子/接口不匹配） | 内核侧 SUSFS 升到与 KSU 同代，或把 KSU 钉回旧 commit |
| 能开机但 SUSFS 新功能没有 | 旧 KernelSU + 新内核侧 | 升 KSU 到与内核侧同代 |
| 管理器提示"需要更新内核"/功能灰掉 | 管理器 UAPI ≠ 内核 UAPI | 用同一 KSU commit 构建管理器 |
| 能开机、管理器正常，但某个子功能没反应 | 设备片段里对应 `CONFIG_KSU_SUSFS_*` 没开 | `grep KSU_SUSFS out/.config` 逐项核对 |

### 8.2 升级 SUSFS（反向移植流程）

1. 确认新版本提供了哪些分支（通常只有 `gki-android13-5.10` / `gki-android14-6.1`）。
2. **先撤掉当前 SUSFS**（`git revert` 移植提交，或从 `backup-lineage-23.2-orig` 拉干净底座），
   否则补丁上下文全是旧代码，冲突率翻倍。
3. 逐提交导出补丁 → 按文件 `patch -p1 -F3` 分批打 → 统计 hunk 数与 reject 数。
4. `fs/susfs.c` / `include/linux/susfs.h` / `include/linux/susfs_def.h` 整文件替换。
5. 逐个 reject 手工合并；**每个 hunk 复核落位**（见 §4.2 的错位表）。
6. 对照 §4.3 的适配清单，把 5.10 专有 API 全部换掉。
7. `grep -E '^#define SUSFS_VERSION' include/linux/susfs.h` 确认版本号。
8. `make -k` 收敛编译错误 → CI 出包 → **真机按 §2 验证**（尤其 manager 的 three-show 调用）。
9. 更新本文档的版本号/适配清单。

### 8.3 升级 KernelSU 子模块

```sh
git -C KernelSU fetch --tags origin
git -C KernelSU checkout <new-commit>
git add KernelSU && git commit -m "KernelSU: bump to <new-commit>"
```

注意事项：

- **main 在 `61e2ce83` 之后又前进了 72 个提交**（截至本文档整理时），其中包含
  `kernel: suspend susfs build`、`kernel, ksud, manager: sync with latest susfs`、
  模块黑名单/热安装等改动，会动 SUSFS 接口与 hook 结构。**直接 `git submodule update --remote` 大概率重现"开机卡死"**。
- 升级后版本码变化：`30000 + 新提交数 + 700`；`KERNEL_SU_UAPI_VERSION` 也可能变 →
  **管理器必须一起换**。
- `inline_hook_check.mk` 会校验 hook 埋点，升级后若编译失败，先看是不是删了/改了某个 `ksu_handle_*`。
- 别忘了 CI 里"unshallow 子模块"的步骤（否则版本码算错）。

---

## 9. 排障

### 9.1 开机卡死（第一/二屏无限重启）

**特征**：能进 fastboot / recovery，但系统反复重启；`pstore`、`mtdoops` 一条记录都没有
→ 说明内核在 **userspace 起来之前**就挂了。

**最常见原因**：新 KernelSU + 旧 SUSFS（内核侧接口不匹配）。BakaSU 自己的
`052ca277`（*avoid old version of susfs hang in boot*）就是在描述这个失败模式。

**处理**：
1. 核对 §8.1 的四代配对；先把 KernelSU 钉回旧 commit（如 `a9216b04`）确认能开机；
2. 确认后再按 §8.2 把内核侧 SUSFS 升到同代；
3. 不要指望日志通道 —— 见下。

### 9.2 抓日志的教训（别重复踩）

| 通道 | 结论 |
| --- | --- |
| `pstore` / `ramoops` | 该机型**没有合适的内存区**：`no-map` 区域 `pfn_valid()` 为假，驱动走 `request_mem_region()` 失败，`/sys/fs/pstore` 一直空；`splash_region` 虽符合条件但被显示驱动占用，写进去会**破坏启动**。所以 ramoops 实际不可用 |
| `mtdoops` | 平台 cmdline 有 `block2mtd.block2mtd=/dev/block/sda15,2097152 mtdoops.mtddev=0`；设备片段已打开 `CONFIG_MTD` / `CONFIG_MTD_BLOCK2MTD` / `CONFIG_MTD_OOPS`，但 `block2mtd` 打开 `/dev/block/sda15` 只重试 3 秒，而节点由 ueventd 创建，**经常来不及** → 实测常抓不到；`/dev/block/sda15` 里现有内容是 HyperOS 时代留下的 |
| `androidboot.init_fatal_panic=1` | 能让 init 失败时直接 panic（配合上面的通道才有意义） |
| 二分回滚 | **最可靠**：换回旧 KernelSU commit 确认能开机，再逐段加回 SUSFS |

### 9.3 交付前验证清单

1. `uname -r` 符合预期（含目标 commit）
2. `dmesg | grep -i susfs`：manager 能调到 `susfs_show_version` / `susfs_show_enabled_features` /
   `susfs_show_variant`，且 `ret: 0`
3. 管理器显示"工作中"，无"需要更新内核"
4. 抽查子功能：`/proc/cmdline`（SPOOF_CMDLINE）、路径隐藏（SUS_PATH）、`/proc/mounts`（SUS_MOUNT）、
   open_redirect、uname 伪装（SPOOF_UNAME）
5. 显示/触摸正常（说明 vendor 模块 CRC 没被破坏）
6. 回退包在手（`boot-stock-*.zip`）

---

## 10. Release 与资产

Tag：`boot-img-LOS23.2-20260930-bakasu`（prerelease，2026-10-06 发布）

| 资产 | 用途 | sha256 |
| --- | --- | --- |
| `anykernel3-BakaSU-susfs-v2.3.0-mars.zip` | AnyKernel3，管理器 KernelFlash / 第三方 recovery 刷入 | `7169c9331f288d06a2aff4047fc1554b1c116da0b749b0ee6a79901f5f9560eb` |
| `boot-bakasu-susfs-v2.3.0-mars.zip` | 解压得 `boot-bakasu-mars.img`，`fastboot flash boot` 用 | `8db0737d0127f82bd4ade7894b38e3a69a0d138149fd9a101efe4da036b1e78c` |
| `BakaSU_v4.2.0-rc3_35215-manager.apk` | 配套管理器（UAPI 5，版本码 35215） | `95c588e3e5664a59496fa7defa38fede12e8cff51aab8fa409b3543f449be11b` |
| `boot-stock-LOS23.2-20260930.zip` | 原版 boot 备份，**回退用**（解压得 `boot-stock-LOS23.2-20260930.img`） | `2d43ebd2ceec78a4d4b8d8302ef40a40b9bf213498101198b856a90fe9e67709` |

推荐流程：

1. 首次：`fastboot boot` 试（不写分区）→ 满意后 `fastboot flash boot`
2. 以后更新：管理器 KernelFlash 刷 AnyKernel3 zip（或 fastboot 刷 img）
3. 任何异常：`fastboot flash boot boot-stock-LOS23.2-20260930.img`

> 资产名是发布时手工命名的，与 CI artifact 名（`BakaSU-mars-<ver>-<ksu>.zip`）不一定相同；
> 下载后建议先比对上面的 sha256（`sha256sum <文件>`）。

---

## 11. 待办清单

按优先级排列，做之前先读对应章节。

1. **跟进 BakaSU main**（高）
   pin `61e2ce83` 之后 main 又走了 72 个提交，含 SUSFS 接口/行为的大改
   （`kernel: suspend susfs build`、`sync with latest susfs`、模块黑名单、热安装等）。
   要么继续钉在 `61e2ce83`（现状，稳定），要么按 §8.2/§8.3 完整重做一次移植并从 §9.3 验证。
   **不要只升子模块不升 SUSFS。**
2. **管理器版本码对齐**（中）
   内核自报 35213，Release 里 APK 是 35215（UAPI 相同，可用）。想完全一致：CI 里把管理器来源
   钉到与 submodule 同一个 commit（现在只有 tag 匹配 + nightly 回退，nightly 会漂）。
3. **`ci/package-anykernel.sh` 的 `(manual hook)` 字样**（低）
   实际是 SUSFS inline hook（`CONFIG_KSU_MANUAL_HOOK` 是 not set）。改动 `ci/` 会触发一次完整
   CI 构建，所以留到下次确实要动 CI 时一起改（生成的 `anykernel.sh` 里也有这个字样）。
4. **`ci/make-bootimg.sh` 与 workflow 内联 repack 重复**（低）
   本地脚本保留（有 ramdisk sha256 校验），但两处逻辑要同步改；或在 CI 里直接调用该脚本去重。
5. **日志通道**（中）
   ramoops 该机型不可用（§9.2）；mtdoops 已开配置但时序不稳。可考虑：把 `block2mtd` 改成
   等节点出现再挂载的机制，或直接接受"开机卡死靠二分"。
6. **产物不含模块**（按需）
   现在 `do.modules=0`、只替换 `Image`。若将来要给 recovery 或自编触摸/显示模块用，需要在
   `arch/arm64/configs/vendor/xiaomi_QGKI.config` 打开对应 `CONFIG_*`（参考 `vendor/star_QGKI.config`）
   并改 `do.modules=1`，同时注意 vermagic 差异（§5.3）。
7. **`sus_su` / Shamiko**（低）
   未集成 SUSFS 自带 su 替换；Shamiko 支持上游已移除。需要的话得单独评估，不要直接抄别家内核。
8. **CI 静态校验**（低）
   目前 CI 只编译内核，没有对 `ci/*.sh` 做 `bash -n`、对 workflow 做 YAML 校验。可加一个秒级 lint job。

---

## 12. 仓库纪律（提交前必看）

- **不要提交**：真实设备序列号、内网地址、服务器/隧道域名、密码、token、私钥、带个人信息的日志或截图。
  文档里的示例一律用占位符：`<SN>`、`<构建机>`、`<密码>`、`192.0.2.10`（保留网段）。
- 只改文档时用 `[skip ci]`（`paths-ignore` 已含 `**.md`，双保险）。
- 不要强推、不要改写历史（除非确实提交过敏感信息，且已备份 + 与使用者确认）。
- 改/删分支或标签前先 `git bundle create /tmp/kernel-$(date +%F).bundle --all` 留底。
- 备份标签（§3.3）保留，不要清理。

### 相关仓库

- 恢复系统（OrangeFox，`recovery-as-boot` 的 boot.img）：`https://github.com/S0SL/orangefox_mars`
  （注意：设备树里的产品名/`lunch` 目标仍是 `twrp_mars`，那是 TWRP/OrangeFox 的标准命名，只有仓库名改成了 orangefox）

---

## 附录 A：关键提交

| commit | 内容 |
| --- | --- |
| `b85135a696c6` | 接入 BakaSU（manual hook 版） |
| `5eea38d2c2fd` | CI 修权限、BakaSU 版本回退 |
| `e67728fbf5e7` | CI unshallow 子模块（版本码算对） |
| `921475f34691` | 模块兼容性说明 + 构建验证结果 |
| `34c6fac0fe8c` | SUSFS 首次移植（v2.1.0 基线）→ Release tag |
| `805b23cb0312` | 加 `ci/make-bootimg.sh`，文档写 fastboot 刷法 |
| `dd0552d2f30b` | 打开 MTD/mtdoops（想抓 panic） |
| `bafe5a2e10cf` | 把 KernelSU 临时钉回 `a9216b04`（排查开机卡死） |
| `168cbb89bdf0` | CI 按 pin 抓配套管理器 |
| `1dd42b844e14` | 文档记录 pin 与管理器/UAPI 配对规则 |
| `3eff65d812d3` | **SUSFS v2.3.0 移植（round 1，27 文件 +1249/-775）** |
| `9519469751a7` | 修 5 组 5.4 编译错误 |
| `fbb18062d87e` | 文档 + CI 回退 nightly 管理器 |
| `aa14561ad646` | 打开 SUS_KSTAT + fdinfo 字段对齐 |
| `797c093f5b52` | CI 追加 fastboot 可刷的 boot.img |

## 附录 B：常用命令

```sh
# 看 SUSFS 版本
grep -E '^#define SUSFS_VERSION' include/linux/susfs.h

# 看集成了哪些 KSU/SUSFS 开关
grep -E 'KSU' arch/arm64/configs/vendor/xiaomi_QGKI.config

# 看某个 SUSFS 钩子落在哪个函数
grep -n -B3 -A3 'susfs_' fs/namei.c

# 与"打 BakaSU 之前"的原树对比
git diff --stat backup-lineage-23.2-orig HEAD

# 确认子模块版本/版本码
git -C KernelSU rev-parse --short HEAD
echo $((30000 + $(git -C KernelSU rev-list --count HEAD) + 700))
```
