# swab

> 一键切换 Android A/B 分区槽位的 root 脚本。

`swab`（**sw**itch **a/b** 的缩写）是一个纯 shell 实现的 A/B 槽位切换工具，
通过 Boot Control HAL 配合手动重写 `misc` 分区中的 `boot_ctrl` 块，
在重启后安全地引导到目标槽位。

## 特性

- **纯 shell**：仅依赖 `busybox`（`crc32` / `xxd`）与系统 `service call`，无需编译。
- **HAL + 手动对齐**：调用 `setActiveBootSlot()` 后，因部分厂商 HAL 不会更新
  `misc` 偏移 2048 的槽位后缀，脚本会手动对齐后缀并重算 **CRC-32**，确保 `lk`
  引导器按正确的 `boot_ctrl` 选槽。
- **安全回退**：每次切换前自动备份当前 `boot_ctrl` 块，并给出 `dd` 回退命令。
- **状态自检**：只读查看当前运行槽、待生效槽、可启动性、`boot_ctrl` 的 CRC-32 校验。
- **结构体级操作**（移植自 `abslot-tool`）：`-d` 位域级 dump、`-a` 直接设置 active、
  `-p` 保护模式（`successful_boot=0` + `tries_remaining=6`，引导失败时 preloader 自动回退另一槽，防变砖兜底）。

## 适用环境

| 项目 | 说明 |
| --- | --- |
| 设备 | Vivo V2419A (PD2415) / MT6991（其他 A/B 设备可参考适配） |
| 系统 | Android 15 |
| Root | KernelSU / Magisk |
| 依赖 | `busybox`（需 `crc32`、`xxd`） |

> 注意：`/sdcard` 通常为 `noexec`，请用 `sh swab.sh` 运行，
> 或复制到 `/data/local/tmp` 后 `chmod +x` 直接执行。

### 运行前提：仅限已开机的正常系统

本工具**只能在设备已开机、系统正常运行的情况下使用**，原因是它依赖以下
仅存在于 Android 用户空间的能力：

- `service call android.hardware.boot.IBootControl/default` —— 运行中的
  Boot Control HAL (AIDL) binder 服务，关机 / recovery / fastboot 下不存在；
- `getprop ro.boot.slot_suffix` —— Android 属性系统，仅系统启动后才有；
- `busybox`（`crc32` / `xxd`）与 `/data/local/tmp` —— 用户空间工具与可写分区；
- `reboot` 命令。

**工作流**是「在正常运行的系统里提前改好下次重启要进的槽位」：

```
开机进系统 → 运行 swab.sh 改写 boot_ctrl → reboot → lk 按新的 boot_ctrl 选槽引导
```

> ⚠️ 如果设备**已经无法开机**（卡 logo、无限重启），本工具**不可用**，
> 此时需借助 recovery / fastboot / EDL 等底层方式修复 `misc` 分区，
> 这超出了 `swab` 的能力范围。这也意味着：一旦写入出错导致开不了机，
> `swab` 自身无法自我修复。

## 用法

```bash
sh swab.sh              # 查看当前槽位状态（只读）
sh swab.sh a           # 切换到 A 槽
sh swab.sh b           # 切换到 B 槽
sh swab.sh -o          # 切换到对位槽（以当前运行槽为基准自动判断）
sh swab.sh a -r        # 切换到 A 槽并重启
sh swab.sh -r b        # 参数顺序无关：-r 可与目标槽任意排列
sh swab.sh -d          # 完整 dump boot_ctrl 元数据（移植自 abslot-tool）
sh swab.sh -a a        # 设置 A 槽 active（priority=15, tries=7, 其他槽降级）
sh swab.sh -p b        # 保护模式（successful_boot=0, tries=6, 防变砖兜底）
sh swab.sh -h          # 帮助
```

参数说明：

| 参数 | 含义 |
| --- | --- |
| `a` / `b` | 切换到 A / B 槽 |
| `-o`（`opp`/`other`/`opposite`） | 切换到对位槽 |
| `-r`（`--reboot`） | 切换后重启 |
| `-s`（`--status`） | 仅查看状态（默认） |
| `-d`（`--dump`） | 完整 dump `boot_ctrl` 结构体（位域级元数据） |
| `-a <a\|b>`（`--active`） | 直接改结构体设置槽位 active，不依赖 HAL |
| `-p <a\|b>`（`--protect`） | 保护模式：置 `successful_boot=0`、`tries=6` |
| `-h`（`--help`） | 显示帮助 |

> `-a` / `-p` 为**结构体级操作**（移植自 `abslot-tool`），不走 Boot Control HAL，
> 直接在 `misc` 中读写 `boot_ctrl` 的 `slot_info` 位域并重算 CRC-32。
> `-d` 可在操作前检查槽位元数据与布局假设是否与设备实际一致。

## 原理

1. 通过 Boot Control HAL (AIDL) 调用 `setActiveBootSlot()`：
   ```text
   service call android.hardware.boot.IBootControl/default 9 i32 <0|1>
   ```
2. 因该 HAL 不更新 `misc` 偏移 2048 的槽位后缀，手动对齐后缀并重算
   CRC-32（`boot_ctrl` 块 = `misc[2048:2076]`，28 字节，标准 CRC-32）。
3. 重启后由引导器 (`lk`) 按 `boot_ctrl` 选槽引导。

### `boot_ctrl` 结构体布局（`-d` / `-a` / `-p` 使用）

`misc` 偏移 2048 处为标准 AOSP `bootloader_control` 结构（32 字节），
前 28 字节参与 CRC-32（小端存储），移植自 `abslot-tool` 的位域布局：

```text
[0:4]   slot_suffix       [4:8] magic(0x42414342)   [8:9]  version
[9:10]  nb_slot:3 | recovery_tries_remaining:3
[10:11] merge_status:3
[11:12] reserved0
[12:20] slot_info[4] × 2 字节 = priority:4 | tries_remaining:3 | successful_boot:1 | verity_corrupted:1
[20:28] reserved1        [28:32] crc32_le
```

`-a` / `-p` 与 HAL 切换（`set_slot`）的区别：

| 操作 | 走的路径 | 改动字段 |
| --- | --- | --- |
| `a`/`b`/`-o`（HAL 切换） | Boot Control HAL + 手动对齐后缀 | 仅后缀 + CRC |
| `-a <a\|b>`（active） | 直接写结构体 | `priority=15`、`tries=7`，其他槽 `priority>=15` 降为 14 |
| `-p <a\|b>`（protect） | 直接写结构体 | `successful_boot=0`、`tries_remaining=6` |

> 建议先 `-d` dump 一次，核对 `slot_info` 位域解析结果与设备实际一致后再写操作。

## 安全

- 切换前自动备份 `boot_ctrl` 块到 `/data/local/tmp/bootctrl_before_*.bin`。
- 写入后做后缀字节 + CRC-32 双重校验，不一致则报错并提示**不要重启**。
- 回退命令示例（将备份写回并重启）：
  ```bash
  dd if=/data/local/tmp/bootctrl_before_*.bin of=/dev/block/by-name/misc \
     bs=1 seek=2048 conv=notrunc && reboot
  ```

## ⚠️ 安全风险告知

本工具直接读写 `misc` 分区并修改 `boot_ctrl` 块，**属于底层、危险操作**。
使用前请务必完整阅读以下风险：

1. **变砖风险（最高）**：`misc` 分区存储着引导相关的关键数据。
   一旦 `boot_ctrl` 写入错误、CRC-32 校验失效或断电中断，设备可能无法正常引导，
   表现为卡开机 logo / 无限重启，即俗称的「变砖」。
   部分机型可能需要借助 EDL / 9008 线刷等底层方式才能恢复，**有丢失数据的风险**。

2. **需要 root**：脚本必须以 root（KernelSU / Magisk）运行。
   使用 root 权限本身就会绕过系统安全机制，误操作可能影响系统稳定性。

3. **对位切换依赖运行槽判断**：`-o`（对位槽）以 `ro.boot.slot_suffix` 或 HAL
   返回值判断当前槽。若该属性在特殊状态下缺失或异常，可能切到非预期槽位。

4. **厂商差异**：脚本针对 Vivo V2419A (PD2415) / MT6991 / Android 15 验证。
   其他机型/系统的 Boot Control HAL 事务编号、misc 偏移、`boot_ctrl` 布局可能不同，
   **未经验证的设备请勿直接使用**，否则极易损坏引导数据。

5. **环境依赖**：依赖 `busybox` 的 `crc32` / `xxd`。若 busybox 缺失或版本不符，
   脚本会主动报错退出；但误用残缺环境仍可能导致计算错误。

6. **操作中断**：写入 `misc` 过程中（尤其是 `dd` 写回后、校验前）如果设备断电、
   强制重启或 shell 被杀死，分区可能处于不一致状态。

### 使用前提与缓解措施

- ✅ 操作前**已备份当前 `boot_ctrl`**（脚本自动备份到
  `/data/local/tmp/bootctrl_before_*.bin`，请确认备份生成成功）。
- ✅ 设备**电量充足（建议 >50%）**且不会中途断电。
- ✅ 了解如何通过 `dd` 回退命令将备份写回 `misc` 并重启（见上方「安全」一节）。
- ✅ 仅在**已确认支持 A/B 且已知 boot_ctrl 布局**的设备上使用。
- ❌ 不要在重要数据未备份的生产机上试验。
- ❌ 不要在厂商明确禁止 bootloader / 槽位操作的设备上使用。

> 本程序以「原样」提供，**无任何担保**。因使用本工具导致的设备变砖、数据丢失、
> 保修失效等任何后果，作者与贡献者**不承担任何责任**。一切风险由使用者自行承担。

## 构建与模块下载

`module/` 目录是一个开箱即用的 KernelSU / Magisk 模块（开机自动进入保护模式，
防变砖兜底）。仓库已配置 [GitHub Actions](./.github/workflows/build.yml)：

- **每次 push** 自动将 `module/` 打包为面具模块 zip（如
  `swab_protect-v1.1.0.zip`）。
- 推送 **tag**（如 `git tag v1.1.0 && git push --tags`）时，会发布到
  **GitHub Releases** 页面，附件即为可直接刷入的模块 zip。
- 也可以在 **Actions** 页面手动触发（`workflow_dispatch`）重新构建。

### ⚠️ 下载请用 Releases 附件，不要用 Actions Artifacts

GitHub 的 **Actions Artifacts 是双层封装**：下载后的 zip 内部还套了一层
（如 `swab_protect-v1.1.0-<sha>.zip` 里面才是 `swab_protect-v1.1.0.zip`），
直接丢给 KernelSU / Magisk 会因外层目录导致无法识别。

> **正确做法**：进入仓库 **Releases** 页 → 选择对应版本 → 下载
> `swab_protect-v1.1.0.zip`（单层、顶层直接含 `module.prop`），再在
> 「模块」页「从本地安装」刷入即可。

下载 zip 后，在 KernelSU / Magisk 的「模块」页点击「从本地安装」刷入即可；
模块会在每次开机后自动对当前运行槽执行 `swab.sh -p <槽位>`（保护模式）。

## 模块 WebUI（仅 KernelSU）

模块内置了 `webroot/` 页面，在 **KernelSU Manager → 模块 → Swab 开机保护模式**
详情页即可看到图形界面（Magisk 不支持此机制）：

- **槽位状态**：一键查看当前运行槽、待生效槽、可启动性与 `boot_ctrl` CRC-32 校验。
- **切换槽位**：切 A / 切 B / 切对位槽，以及切换后直接重启；危险操作均带二次确认。
- **结构体级操作**：设置 active（`-a`）与保护模式（`-p`）。
- **诊断 / 日志**：dump `boot_ctrl` 元数据、查看每次开机保护模式的执行日志
  （`/data/local/tmp/swab_protect.log`）。

> 按钮背后以 root 权限调用 `swab.sh`，与命令行行为完全一致。

## 许可证

[GPL-3.0](./LICENSE)
