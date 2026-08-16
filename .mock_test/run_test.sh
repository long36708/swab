#!/bin/bash
# 本地 mock 验证: 只加载 swab.sh 函数定义(不含主流程), 用模拟 misc 测试移植逻辑
set -u
BASE="F:/learn-front/learn-hook/swab"
WORK="$BASE/.mock_test/tmp"
MOCK="$BASE/.mock_test/mock_misc"
mkdir -p "$WORK"

python "$BASE/.mock_test/gen_mock.py" "$MOCK" || exit 1

# 提取 swab.sh 的函数定义部分(1-392 行, 不含主流程)
sed -n '1,392p' "$BASE/swab.sh" > "$WORK/swab_funcs.sh"
. "$WORK/swab_funcs.sh"

# 注意: 必须在 source 之后覆盖, 否则被 swab.sh 内部的 /dev/block/... 覆盖
TMPDIR="$WORK"
MISC="$MOCK"

# 本地环境用 python zlib 模拟 busybox crc32 / xxd
crc32_of() { python -c "import sys,zlib;print('{:08x}'.format(zlib.crc32(open(sys.argv[1],'rb').read())&0xffffffff))" "$1"; }
write_crc_le() { python -c "
import sys
p, h = sys.argv[1], sys.argv[2]
with open(p,'r+b') as f:
    f.seek(28); f.write(bytes.fromhex(h)[::-1])
" "$TMPDIR/ab_new.bin" "$1"; }

echo '===== 1) 初始 dump ====='
dump_metadata

echo; echo '===== 2) set_meta_active 1 (B 槽) ====='
set_meta_active 1

echo; echo '===== 3) active 后 dump ====='
dump_metadata

echo; echo '===== 4) protect_meta 1 (B 槽) ====='
protect_meta 1

echo; echo '===== 5) protect 后 dump ====='
dump_metadata

echo; echo '===== 6) set_meta_active 0 (A 槽, 恢复) ====='
set_meta_active 0

echo; echo '===== 7) 恢复后 dump ====='
dump_metadata
