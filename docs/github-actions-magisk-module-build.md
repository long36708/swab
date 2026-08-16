# GitHub Actions 自动打包 Magisk 模块经验总结

> 场景：每次 push 自动将 `module/` 目录打包为 Magisk / KernelSU 模块 zip，
> 上传为 Actions Artifact 提供下载；推送 tag 时额外发布到 GitHub Releases。

## 一、最终成果

- **每次 push**（任意分支）→ 自动构建，产出 `swab_protect-v1.0.0.zip`，上传为 Actions Artifact。
- **推送 tag**（如 `git tag v1.0.0 && git push origin v1.0.0`）→ 额外发布到 GitHub Releases，附带模块 zip。
- **手动触发**：Actions 页面点 `Run workflow`（`workflow_dispatch`）。

工作流文件：`.github/workflows/build.yml`。

## 二、踩过的坑（按严重程度排序）

### 1. push 事件默认不匹配 tag —— 打 tag 不触发构建

这是"Releases 里只有源码、没有模块 zip"的根本原因。

```yaml
on:
  push:
    branches: ["**"]   # 只匹配分支推送
  workflow_dispatch: {}
```

推送 `v1.0` tag 时 workflow **根本没运行**，Release 发布步骤从未执行。
Releases 页面看到的 `Source code (zip)` 是 GitHub 为 tag 自动生成的源码包，不是我们的模块包。

**修复**：显式声明 `tags` 触发条件：

```yaml
on:
  push:
    branches: ["**"]
    tags: ["**"]       # ← 关键，tag 推送也会触发
  workflow_dispatch: {}
```

### 2. 创建 Release 需要写权限

```yaml
permissions:
  contents: write   # 否则 softprops/action-gh-release 可能无权创建 Release
```

若仓库默认限制 Actions 权限，还需在
**Settings → Actions → General → Workflow permissions → Read and write permissions** 手动开启。

### 3. 产物名要带版本号，且与 module.prop 保持单一数据源

用 `module.prop` 的 `id` / `version` 驱动文件名，改版本只改一处：

```yaml
- name: 读取模块信息 (module.prop)
  id: module
  run: |
    prop="module/module.prop"
    echo "id=$(sed -n 's/^id=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"
    echo "version=$(sed -n 's/^version=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"
    echo "versionCode=$(sed -n 's/^versionCode=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"
```

产物命名建议三位版本号，与 git tag 保持一致：

```yaml
zip -r9 "../release/swab_protect-${{ steps.module.outputs.version }}.zip" .
files: release/swab_protect-${{ steps.module.outputs.version }}.zip
```

`module.prop` 中 `version=v1.0.0`，tag 也用 `v1.0.0`，避免"v1.0 与 v1.0.0"不一致的混乱。

### 4. Magisk 模块 zip 打包规范

- **zip 根目录必须直接包含 `module.prop` / `service.sh` 等**，刷入才能识别。
  所以在 `module/` 目录内执行 zip（`cd module` 后再打包），而不是对 `module/` 目录本身打包。
- 用 `zip -r9` 打包会保留 shell 脚本的**执行权限位**（Linux runner 上）。
- 打包后 `unzip -l` 校验内容，防止产出空包 / 错包。

### 5. Windows 终端中文乱码是显示问题，不要误改

PowerShell 默认代码页（GBK）下 `git commit` 的中文提交信息**显示为乱码**，
但实际存储是正确的 UTF-8。验证方法：

```bash
git cat-file commit HEAD   # 或 git log -1 --format="%B" > file.txt 后用 UTF-8 打开
```

确认字节无误即可，不要为此反复 amend。

## 三、验证手段：优先用 GitHub API

网页可能缓存旧状态，用 API 查询更准确：

```bash
# 最近构建记录（含触发事件 / 分支 tag / 状态）
curl https://api.github.com/repos/<owner>/<repo>/actions/runs?per_page=5

# Release 列表及其附件
curl https://api.github.com/repos/<owner>/<repo>/releases
```

## 四、发布新版的固定流程

```bash
# 1. 改 module.prop 的 version / versionCode
# 2. 提交并推送
git add module/module.prop && git commit -m "chore: bump to v1.1.0" && git push

# 3. 打 tag 并推送（触发 Release 发布）
git tag v1.1.0 && git push origin v1.1.0
```

如需重发（例如误打 tag 或构建失败）：

```bash
git push origin --delete v1.1.0   # 删除远程 tag
git tag -d v1.1.0                 # 删除本地 tag
git tag v1.1.0 && git push origin v1.1.0
```

## 五、完整 workflow 参考

```yaml
name: Build Magisk Module

on:
  push:
    branches: ["**"]
    tags: ["**"]
  workflow_dispatch: {}

permissions:
  contents: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: 读取模块信息 (module.prop)
        id: module
        run: |
          prop="module/module.prop"
          echo "id=$(sed -n 's/^id=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"
          echo "version=$(sed -n 's/^version=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"
          echo "versionCode=$(sed -n 's/^versionCode=//p' "$prop" | head -1)" >> "$GITHUB_OUTPUT"

      - name: 打包为 Magisk 模块 zip
        run: |
          mkdir -p release
          cd module
          zip -r9 "../release/swab_protect-${{ steps.module.outputs.version }}.zip" . \
            -x '*.git*' '*/.DS_Store'
          cd ..

      - name: 校验 zip 内容
        run: |
          unzip -l "release/swab_protect-${{ steps.module.outputs.version }}.zip"

      - name: 上传 Artifact（提供下载）
        uses: actions/upload-artifact@v4
        with:
          name: swab_protect-${{ steps.module.outputs.version }}-${{ github.sha }}
          path: release/*.zip
          if-no-files-found: error

      - name: 发布到 GitHub Release（打 tag 时）
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: release/swab_protect-${{ steps.module.outputs.version }}.zip
          tag_name: ${{ github.ref_name }}
          name: Swab ${{ steps.module.outputs.version }}
          body: |
            自动构建：`${{ steps.module.outputs.id }}` v${{ steps.module.outputs.version }} (versionCode ${{ steps.module.outputs.versionCode }})

            - 提交：${{ github.sha }}
            - 直接下载 zip 后在 KernelSU / Magisk 中刷入即可。
          draft: false
          prerelease: false
```
