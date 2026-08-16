#!/usr/bin/env bash
set -euo pipefail

# 模拟 CI 的本地构建脚本：同步 swab.sh 并打包为 Magisk 模块 zip
# 用法：bash build-local.sh

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# 1. 根目录 swab.sh 作为唯一源，复制到 module/
cp -f swab.sh module/swab.sh
echo "已从根目录 swab.sh 同步到 module/swab.sh"

# 2. 读取版本号（单一数据源）
VERSION="$(sed -n 's/^version=//p' module/module.prop | head -1)"
echo "构建版本: $VERSION"

# 3. 打包（优先用 zip，否则回退到 Python，保证 Windows 也可用）
mkdir -p release
OUT="release/swab_protect-${VERSION}.zip"
if command -v zip >/dev/null 2>&1; then
  ( cd module && zip -r9 "../${OUT}" . -x '*.git*' '*/.DS_Store' )
else
  echo "未找到 zip 命令，使用 Python 打包（注意：Windows 下不保留 shell 执行权限位）"
  python - <<PY
import os, zipfile, io
root = "module"
out = "$OUT"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for dp, _, fns in os.walk(root):
        for fn in fns:
            if ".git" in dp or fn == ".DS_Store":
                continue
            p = os.path.join(dp, fn)
            z.write(p, os.path.relpath(p, root))
PY
fi

echo "=== 生成的文件 ==="
ls -lh release/

# 4. 校验
echo "=== zip 内容 ==="
python - <<'PY'
import zipfile
ver = open("module/module.prop", encoding="utf-8").read().split("version=")[1].splitlines()[0]
out = "release/swab_protect-%s.zip" % ver
with zipfile.ZipFile(out) as z:
    names = z.namelist()
    for n in names:
        print(n)
    print("total:", len(names), "entries")
PY
