#!/system/bin/sh
# swab_protect: 每次开机后自动对当前运行槽启用保护模式 (successful_boot=0, tries=6)
# KernelSU 模块 service.sh；硬编码路径，不依赖 $0；用 sh 调用，不依赖执行位
MODDIR=/data/adb/modules/swab_protect
LOG=/data/local/tmp/swab_protect.log
SWAB="$MODDIR/swab.sh"

while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$(getprop dev.bootcomplete)" != "1" ]; do
    sleep 3
done
sleep 10

{
    echo "===== $(date '+%F %T') swab_protect(模块): 开机保护模式 ====="
    slot=$(getprop ro.boot.slot_suffix | tr -d '_')
    case "$slot" in
        a|b) echo "当前运行槽: $slot 槽" ;;
        *)   echo "[错误] 无法识别槽位: '$slot'，跳过本次"; exit 1 ;;
    esac
    if [ -f "$SWAB" ]; then
        sh "$SWAB" -p "$slot"
    else
        echo "[错误] 找不到 $SWAB"
    fi
    echo "---- 本次执行结束 ----"
} >> "$LOG" 2>&1
exit 0
