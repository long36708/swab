---
name: gha-build-release
description: 配置 GitHub Actions 实现"每次 push 自动打包构建产物并上传为 Artifact 提供下载，推送 tag 时自动发布到 GitHub Releases"。当用户提到 GitHub Actions / workflow / CI / 自动构建 / 打包产物 / 上传 artifact / 发布 release / 打 tag 发布 / 面具模块打包下载 等需求时使用。本技能总结了一次真实项目（Magisk/KernelSU 模块自动打包发布）的完整踩坑经验，包含通用 workflow 模板、版本号单一数据源、产物命名规范、发布新版本固定流程等可复用内容。
---

# GitHub Actions 自动构建发布技能

## 概述

用 GitHub Actions 把项目的构建产物自动打包并提供下载。核心链路：

**每次 push → 打包产物 → 上传 Artifact（下载入口）**；**推送 tag → 额外发布到 GitHub Releases（稳定下载链接）**。

本技能适用于任意项目（前端、Android 模块、后端等），只要最终需要"自动出可下载的压缩包"。Magisk/KernelSU 模块是已验证的真实案例，详见 `references/magisk-module.md`。

## 核心原则（为什么这样设计）

1. **触发条件必须显式声明 tags**。GitHub 的 `on.push` 默认只匹配分支，不匹配 tag。只写 `branches` 会导致推送 tag 时 workflow 根本不运行 —— 这是"Releases 里只有源码（GitHub 自动附的 Source code），没有我们打的包"的常见根因。源码包 ≠ 你的产物，别被它迷惑。
2. **单一数据源驱动版本号**。版本号只维护一处（如 `module.prop` / `package.json`），workflow 用脚本读出来拼进产物名和 Release 名，避免改版本要动多处。
3. **发布前声明写权限**。`softprops/action-gh-release` 创建 Release 需要 `permissions: contents: write`，否则可能静默失败。
4. **产物名带版本号**（推荐三位格式如 `myapp-v1.0.0.zip`），且与 git tag 保持一致（`v1.0.0`），避免 `v1.0` vs `v1.0.0` 混乱。

## 标准执行流程

### 第 1 步：收集需求

向用户确认（能推断就推断，不要反复问）：
- 打包哪个目录 / 哪些文件作为产物根
- 产物是 zip 还是其他格式，产物名期望格式
- 版本号从哪个文件读（优先选已存在的单一数据源）
- 是否需要在 Releases 发布（默认：tag 时发布）

### 第 2 步：创建 workflow 文件

路径：`.github/workflows/build.yml`（或按项目语义命名，如 `release.yml`）。

直接基于模板 `assets/workflow-template.yml` 修改，要点：

```yaml
on:
  push:
    branches: ["**"]
    tags: ["**"]          # 必须有，否则 tag 推送不触发
  workflow_dispatch: {}   # 支持手动触发

permissions:
  contents: write          # Release 发布需要
```

读取版本号（单一数据源），示例读取 `module.prop`：

```yaml
- name: 读取模块信息
  id: module
  run: |
    echo "version=$(sed -n 's/^version=//p' module/module.prop | head -1)" >> "$GITHUB_OUTPUT"
```

用版本号拼产物名（注意大小写一致，后续 step 引用同一 output）：

```yaml
- run: zip -r9 "../release/myapp-${{ steps.module.outputs.version }}.zip" .
```

上传 Artifact（每次构建都有的下载入口）与发布 Release（仅 tag 触发）都要。

### 第 3 步：校验产物

打包后必须校验，防止产出空包/错包，否则用户拿到坏文件很难排查：

```yaml
- name: 校验 zip 内容
  run: unzip -l "release/xxx.zip"
```

### 第 4 步：更新 README

补充「构建与模块下载」类说明：Artifact 在哪下载、tag 如何发布 Release、手动触发方式。让使用者不用看 workflow 也能发布新版。

### 第 5 步：验证

- 本地校验 YAML 语法：`python -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml', encoding='utf-8'))"`（GitHub Actions 的 YAML 是标准 YAML，可用该方式快速检查缩进/结构错误）。
- 优先用 **GitHub API** 验证远端状态（网页可能缓存旧结果）：
  - `https://api.github.com/repos/<owner>/<repo>/actions/runs` —— 看触发事件、分支/tag、结论
  - `https://api.github.com/repos/<owner>/<repo>/releases` —— 看 Release 附件
- 若仓库默认限制 Actions 权限：**Settings → Actions → General → Workflow permissions → Read and write permissions** 手动开启。

## 发布新版固定流程（交付给用户）

```bash
# 1. 改版本号（只改单一数据源，如 module.prop）
git add module/module.prop && git commit -m "chore: bump to v1.1.0" && git push
# 2. 打 tag 并推送，自动发布 Release
git tag v1.1.0 && git push origin v1.1.0
```

误打 tag 重发：

```bash
git push origin --delete v1.1.0   # 删远程 tag
git tag -d v1.1.0                 # 删本地 tag
git tag v1.1.0 && git push origin v1.1.0
```

## 踩坑清单（真实项目验证）

| 坑 | 现象 | 解法 |
| --- | --- | --- |
| `on.push` 未声明 `tags` | 打 tag 后 Releases 只有 GitHub 自动源码包，无产物 | 加 `tags: ["**"]` |
| 缺 `permissions: contents: write` | Release 创建失败/静默失败 | 显式声明写权限 |
| 版本号多处维护 | 产物名与 module.prop/tag 不一致 | 单一数据源 + output 传递 |
| 对目录本身打包而非目录内容 | Magisk 刷入不识别 | `cd 目录` 后再 zip（zip 根直接含 `module.prop`） |
| 用普通 zip 命令 | shell 脚本执行权限位丢失 | Linux runner 上用 `zip -r9` |
| 打包后不校验 | 空包/错包直接给用户 | 必做 `unzip -l` 校验 |
| ⚠️ 从 Actions Artifact 下载刷入 | KSU/Magisk 刷不进、外边多一层目录 | **Artifact 是双层封装**（下载的 zip 里还套一层），面向用户的下载入口必须用 **Releases 附件**（单层、顶层含 module.prop）；交付时务必告知用户从 Releases 下载 |
| Windows 终端中文乱码 | `git commit` 信息显示乱码 | 多为显示问题；`git cat-file commit HEAD` 确认存储是 UTF-8，不必反复 amend |
| 只信网页看构建状态 | 缓存导致误判 | 用 GitHub API 查询 |

## 输出物清单

完成一次任务应产出（或指导用户产出）：
- `.github/workflows/*.yml` —— 构建发布工作流
- README 中「构建与下载」说明小节
- （可选）发布新版流程指引

## 相关参考

- `references/magisk-module.md` —— Magisk/KernelSU 模块打包专用细节（模块规范、module.prop、服务脚本）
- `assets/workflow-template.yml` —— 通用可复制的 workflow 模板
