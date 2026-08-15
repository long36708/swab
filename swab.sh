#!/system/bin/sh
###############################################################
# swab - 一键切换 A/B 分区槽位脚本
#
# Copyright (C) 2026  <你的名字/昵称>
#
# 本程序是自由软件：你可以再发布和/或修改它，依据 GNU 通用公共许可证
# （GPL）第 3 版或（你选择的）任何更高版本，由自由软件基金会发布。
#
# 本程序以“原样”提供，无任何担保，包括但不限于适销性和特定用途适用性
# 的默示担保。详见 GNU 通用公共许可证。
#
# 你应已随本程序收到一份 GNU 通用公共许可证副本；
# 若未收到，请访问 <https://www.gnu.org/licenses/>。
###############################################################
# 适用: Vivo V2419A (PD2415) / MT6991 / Android 15 / KernelSU
#
# 原理:
#   1) 通过 Boot Control HAL (AIDL) 调用 setActiveBootSlot()
#      service call android.hardware.boot.IBootControl/default 9 i32 <0|1>
#   2) 因该 HAL 不更新 misc 偏移 2048 的槽位后缀, 手动对齐后缀并重算
#      CRC-32 (boot_ctrl 块 = misc[2048:2076], 28 字节, 标准 CRC-32)
#   3) 重启后由引导器 (lk) 按 boot_ctrl 选槽引导
#
# 用法:
#   sh swab.sh            查看当前槽位状态(只读)
#   sh swab.sh a          切换到 A 槽
#   sh swab.sh b          切换到 B 槽
#   sh swab.sh -o         切换到对位槽(以当前运行槽为基准自动判断)
#   sh swab.sh a -r       切换到 A 槽并重启
#   sh swab.sh -r b       参数顺序无关
#   sh swab.sh -h         帮助
#
# 说明: /sdcard 为 noexec, 请用 "sh swab.sh" 运行;
#       或复制到 /data/local/tmp 后 chmod +x 直接执行.
#
# ⚠️ 限制: 仅限已开机的正常系统下使用! 依赖运行中的 Boot Control HAL 服务、
#       getprop 属性、busybox 与 reboot 命令; 设备已无法开机时本工具不可用,
#       需借助 recovery/fastboot/EDL 等底层方式修复.
###############################################################

HAL=android.hardware.boot.IBootControl/default
MISC=/dev/block/by-name/misc
BOOTCTRL_OFF=2048
BOOTCTRL_LEN=32
SEG_LEN=28
TMPDIR=/data/local/tmp

# ---- busybox 解析 ----
BB=""
if [ -x /data/adb/ksu/bin/busybox ]; then
    BB=/data/adb/ksu/bin/busybox
else
    BB=$(command -v busybox 2>/dev/null)
fi

usage() {
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

require_root() {
    [ "$(id -u)" = "0" ] || { echo "[错误] 需要 root 权限 (KernelSU/Magisk)"; exit 1; }
}

# service call 返回第 2 个 32 位十六进制字
sc_hex() { # $1=txn  [$2=可选 i32 参数]
    local out
    if [ -n "$2" ]; then
        out=$(service call "$HAL" "$1" i32 "$2" 2>&1)
    else
        out=$(service call "$HAL" "$1" 2>&1)
    fi
    echo "$out" | sed -n 's/.*[[:space:]]\{1,\}\([0-9a-f]\{8\}\)[[:space:]]\{1,\}\([0-9a-f]\{8\}\).*/\2/p' | head -1
}

# 十六进制 -> 十进制 (失败返回空)
sc_dec() { # $1=txn  [$2=可选 i32 参数]
    local v; v=$(sc_hex "$1" "$2")
    [ -n "$v" ] && printf '%d' "0x$v"
}

# 当前槽位索引(HAL): 0=A 1=B (失败返回空)
current_slot() {
    local v; v=$(sc_dec 1)
    case "$v" in 0|1) echo "$v";; *) echo "";; esac
}

slot_name() { # $1=idx
    case "$1" in 0) echo "A";; 1) echo "B";; *) echo "?";; esac
}

# 读取 misc 偏移 2048 处的后缀字段 (a/b)
read_suffix() {
    local b
    b=$(dd if="$MISC" bs=1 skip=$((BOOTCTRL_OFF+1)) count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n')
    case "$b" in 61) echo "a";; 62) echo "b";; *) echo "?";; esac
}

crc32_of() { # $1=文件 -> hex
    "$BB" crc32 "$1" 2>/dev/null | awk '{print $1}'
}

show_status() {
    echo "===== A/B 槽位状态 ====="
    local run_suf run_name cur pend_name ms
    # 当前运行槽
    run_suf=$(getprop ro.boot.slot_suffix)
    case "$run_suf" in _a) run_name=A;; _b) run_name=B;; *) run_name=?;; esac
    echo "  [当前运行槽] ro.boot.slot_suffix : ${run_suf}  (${run_name} 槽)"
    # 待生效槽 (重启后进入)
    cur=$(current_slot)
    if [ -n "$cur" ]; then
        pend_name=$(slot_name "$cur")
        echo "  [待生效槽]   HAL getCurrentSlot() : $cur  (${pend_name} 槽)"
    else
        ms=$(read_suffix)
        case "$ms" in a) pend_name=A;; b) pend_name=B;; *) pend_name=?;; esac
        echo "  [待生效槽]   HAL 获取失败, misc 后缀: _${ms}  (${pend_name} 槽)"
    fi
    # 运行槽 vs 待生效槽 不一致提示
    if [ "$run_name" != "?" ] && [ "$pend_name" != "?" ] && [ "$run_name" != "$pend_name" ]; then
        echo "  ⚠️ 已切换未重启: 当前运行 ${run_name} 槽, 重启后将进入 ${pend_name} 槽"
    fi
    # 可启动性
    local b0 b1
    b0=$(sc_dec 7 0); b1=$(sc_dec 7 1)
    echo "  isSlotBootable(0)/(1)       : ${b0:-?} / ${b1:-?}  (1=可启动)"
    echo "  misc 后缀字段 (2048)        : _$(read_suffix)"
    # CRC-32 校验
    dd if="$MISC" bs=1 skip=$BOOTCTRL_OFF count=$SEG_LEN 2>/dev/null > "$TMPDIR/ab_seg.bin"
    local calc stored
    calc=$(crc32_of "$TMPDIR/ab_seg.bin")
    stored=$(dd if="$MISC" bs=1 skip=$((BOOTCTRL_OFF+SEG_LEN)) count=4 2>/dev/null | od -A n -t x4 | tr -d ' \n')
    if [ -n "$calc" ] && [ "$calc" = "$stored" ]; then
        echo "  boot_ctrl CRC-32           : $calc [OK] 有效"
    else
        echo "  boot_ctrl CRC-32           : 计算=${calc:-?} 存储=${stored:-?} [X] 无效"
    fi
    echo "  boot_ctrl 原始字节         : $(dd if="$MISC" bs=1 skip=$BOOTCTRL_OFF count=$BOOTCTRL_LEN 2>/dev/null | od -A n -t x1 | tr -d ' \n')"
}

# 写入小端 CRC-32 到 ab_new.bin 偏移 28
write_crc_le() { # $1=hex
    local rev
    rev=$(echo "$1" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/')
    echo "$rev" | "$BB" xxd -r -p | dd of="$TMPDIR/ab_new.bin" bs=1 seek=28 conv=notrunc 2>/dev/null
}

# 核心: 切换到指定槽位
set_slot() { # $1=0(A) 或 1(B)
    local idx=$1 suf cur out calc stored newcrc
    case "$idx" in 0) suf=a;; 1) suf=b;; *) echo "[错误] 无效槽位 $idx"; exit 1;; esac

    echo "===== 切换前状态 ====="
    show_status
    echo

    echo "===== 备份当前 boot_ctrl ====="
    local bk="$TMPDIR/bootctrl_before_${suf}_$(date +%Y%m%d_%H%M%S).bin"
    dd if="$MISC" of="$bk" bs=1 skip=$BOOTCTRL_OFF count=$BOOTCTRL_LEN 2>/dev/null
    if [ -s "$bk" ]; then
        echo "  已备份: $bk"
    else
        echo "  [错误] 备份失败"; exit 1
    fi

    echo "===== 1) HAL setActiveBootSlot($idx) ====="
    out=$(service call "$HAL" 9 i32 "$idx" 2>&1)
    case "$out" in *Error*|*error*|*Invalid*) echo "  [错误] HAL 调用失败: $out"; exit 1;; esac
    sleep 1
    cur=$(current_slot)
    echo "  HAL getCurrentSlot() = ${cur:-?} ($(slot_name "$cur") 槽)"
    [ "$cur" = "$idx" ] || echo "  [警告] HAL 返回槽位与目标不一致, 继续尝试手动对齐"

    echo "===== 2) 手动对齐后缀 '_$suf' + 重算 CRC-32 ====="
    dd if="$MISC" of="$TMPDIR/ab_new.bin" bs=1 skip=$BOOTCTRL_OFF count=$BOOTCTRL_LEN 2>/dev/null
    # 改写偏移 2049 字节: 'a'=0x61 'b'=0x62
    if [ "$suf" = a ]; then printf '\141'; else printf '\142'; fi \
        | dd of="$TMPDIR/ab_new.bin" bs=1 seek=1 conv=notrunc 2>/dev/null
    dd if="$TMPDIR/ab_new.bin" bs=1 count=$SEG_LEN 2>/dev/null > "$TMPDIR/ab_seg.bin"
    newcrc=$(crc32_of "$TMPDIR/ab_seg.bin")
    [ -n "$newcrc" ] || { echo "  [错误] CRC-32 计算失败"; exit 1; }
    echo "  新 CRC-32 = $newcrc"
    write_crc_le "$newcrc"
    # 写回 misc
    dd if="$TMPDIR/ab_new.bin" of="$MISC" bs=1 seek=$BOOTCTRL_OFF conv=notrunc 2>/dev/null
    sync

    echo "===== 3) 写入后验证 ====="
    dd if="$MISC" bs=1 skip=$BOOTCTRL_OFF count=$BOOTCTRL_LEN 2>/dev/null > "$TMPDIR/ab_after.bin"
    local h sufbyte
    h=$(od -A n -t x1 "$TMPDIR/ab_after.bin" | tr -d ' \n')
    echo "  boot_ctrl = $h"
    sufbyte=$(echo "$h" | cut -c3-4)
    if [ "$sufbyte" = "$( [ "$suf" = a ] && echo 61 || echo 62 )" ]; then
        echo "  后缀字节 0x$sufbyte [OK]"
    else
        echo "  后缀字节 0x$sufbyte [X] 错误"
        exit 1
    fi
    dd if="$TMPDIR/ab_after.bin" bs=1 count=$SEG_LEN 2>/dev/null > "$TMPDIR/ab_seg.bin"
    calc=$(crc32_of "$TMPDIR/ab_seg.bin")
    stored=$(od -A n -t x4 -j 28 -N 4 "$TMPDIR/ab_after.bin" | tr -d ' \n')
    if [ "$calc" = "$stored" ]; then
        echo "  CRC-32 $calc [OK] 有效"
    else
        echo "  CRC-32 计算=$calc 存储=$stored [X] 不一致, 请勿重启!"
        exit 1
    fi
    echo
    echo "[完成] 已切换到 $suf 槽 ($(slot_name "$idx") 槽), 重启后生效"
    echo "[回退] dd if=$bk of=$MISC bs=1 seek=$BOOTCTRL_OFF conv=notrunc && reboot"
}

# 计算对位槽并切换 (以当前运行槽 ro.boot.slot_suffix 为基准)
switch_opposite() {
    echo "===== 检测当前槽位 ====="
    local cur suf ms
    suf=$(getprop ro.boot.slot_suffix)
    case "$suf" in
        _a|a) cur=0 ;;
        _b|b) cur=1 ;;
        *) cur=$(current_slot) ;;  # 运行属性缺失时回退 HAL
    esac
    if [ -z "$cur" ]; then
        ms=$(read_suffix)
        case "$ms" in a) cur=0;; b) cur=1;; *) echo "[错误] 无法确定当前槽位"; exit 1;; esac
        echo "  (依据 misc 后缀 _${ms} 判定)"
    else
        echo "  依据运行槽 ro.boot.slot_suffix=($suf) 判定"
    fi
    echo "  当前运行槽: $(slot_name "$cur") → 目标对位槽: $([ "$cur" = 0 ] && echo B || echo A)"
    echo
    if [ "$cur" = 0 ]; then
        set_slot 1
    else
        set_slot 0
    fi
}

# ---------- 主流程 ----------
REBOOT=0
TARGET=""
for a in "$@"; do
    case "$a" in
        -r|--reboot) REBOOT=1 ;;
        -s|--status) TARGET="" ;;
        -h|--help) usage; exit 0 ;;
        -o|o|opp|other|opposite) TARGET=other ;;
        a|A) TARGET=a ;;
        b|B) TARGET=b ;;
        *) echo "[错误] 未知参数: $a"; usage; exit 1 ;;
    esac
done

require_root
[ -n "$BB" ] || { echo "[错误] 未找到 busybox (需 crc32/xxd)"; exit 1; }
"$BB" crc32 /dev/null >/dev/null 2>&1 || { echo "[错误] busybox 缺少 crc32"; exit 1; }
"$BB" xxd -r -p </dev/null >/dev/null 2>&1 || { echo "[错误] busybox 缺少 xxd"; exit 1; }

case "$TARGET" in
    a) set_slot 0 ;;
    b) set_slot 1 ;;
    other) switch_opposite ;;
    *) show_status ;;
esac

if [ "$REBOOT" = "1" ]; then
    if [ -n "$TARGET" ]; then
        echo "===== 重启 ====="
        reboot
    else
        echo "[提示] 未指定切换目标, 忽略 --reboot"
    fi
fi
exit 0
