# 生成模拟 misc 镜像: 标准 AOSP boot_ctrl 布局
#   suffix "_a", magic 42414342, version 1, nb_slot=2, merge=0
#   slot0(A): priority=15 tries=7 succ=1  -> lo=0xFF
#   slot1(B): priority=14 tries=0 succ=0  -> lo=0x0E
import sys, zlib, struct

out = sys.argv[1]
misc = bytearray(2048 + 32)
ctrl = bytearray(32)
ctrl[0:4] = b"_a\x00\x00"
ctrl[4:8] = bytes.fromhex("42414342")
ctrl[8] = 1
ctrl[9] = 0x02          # nb_slot=2 | recovery=0
ctrl[10] = 0x00         # merge_status=0
ctrl[11] = 0x00         # reserved0
ctrl[12] = 0xFF         # slot0 lo: pri=15 tries=7 succ=1
ctrl[13] = 0x00         # slot0 hi
ctrl[14] = 0x0E         # slot1 lo: pri=14 tries=0 succ=0
ctrl[15] = 0x00         # slot1 hi
crc = zlib.crc32(bytes(ctrl[:28])) & 0xFFFFFFFF
ctrl[28:32] = struct.pack("<I", crc)
misc[2048:2080] = ctrl
with open(out, "wb") as f:
    f.write(misc)
print("mock ok, crc32_le = %08x" % crc)
