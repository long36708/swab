# Magisk / KernelSU 模块打包专用参考

> 本文件是 `gha-build-release` 技能针对面具模块场景的补充细节，
> 与 `SKILL.md` 配合使用。真实案例：`swab` 项目的开机保护模块。

## 模块目录规范

Magisk / KernelSU 模块的 zip 必须满足：

- **zip 根目录直接包含** `module.prop`（以及 `service.sh` / `customize.sh` / `post-fs-data.sh` 等）。
  所以打包时要在 `module/` 目录**内部**执行 zip（`cd module` 后再打包），
  而不是对 `module/` 目录本身打包（否则 zip 里多一层 `module/`，刷入无法识别）。
- `module.prop` 关键字段（范例）：

```ini
id=swab_protect
name=Swab Protect
version=v1.0.0
versionCode=1
author=xxx
description=开机自动进入保护模式，防变砖兜底
```

- `version` 建议用三位版本号（`v1.0.0`），与 git tag 保持一致。

## 打包与权限位

- 在 **Linux runner**（ubuntu-latest）上用 `zip -r9` 打包，
  shell 脚本的**执行权限位**会被保留（Windows 上打包则会丢失）。
- 排除无关文件：`-x '*.git*' '*/.DS_Store'`。

## 验证模块

刷入前可用以下方式验证 zip 结构：

```bash
unzip -l module.zip
# 期望顶层直接看到 module.prop / service.sh 等，没有多余目录层
```

## 读取版本号（单一数据源）

```yaml
- name: 读取模块信息
  id: module
  run: |
    prop="module/module.prop"
    echo "id=$(sed -n 's/^id=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"
    echo "version=$(sed -n 's/^version=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"
    echo "versionCode=$(sed -n 's/^versionCode=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"
```

产物命名：`swab_protect-${{ steps.module.outputs.version }}.zip` → 如 `swab_protect-v1.0.0.zip`。

## 发布新版流程

```bash
# 1. 只改 module.prop 的 version / versionCode
git add module/module.prop && git commit -m "chore: bump to v1.1.0" && git push
# 2. 打 tag 推送，自动发布 Release
git tag v1.1.0 && git push origin v1.1.0
```

## 刷入方式

- 下载 zip 后，在 KernelSU / Magisk 的「模块」页点击「从本地安装」刷入。
- 模块每次开机自动执行 `service.sh` 中的逻辑（真实案例：对当前运行槽执行 `swab.sh -p <槽位>` 保护模式）。
