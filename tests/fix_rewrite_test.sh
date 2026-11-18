#!/bin/bash
# 游戏缺陷修补表单测（S2A_FIX_TSV → runtime/rewriter/rewriter.c fix_rows，合成 NSO 同 tests/fps_rewrite_test.sh，约 10 秒）：bash tests/fix_rewrite_test.sh
# 合成模块代码段 0x100 起：ldr x8,[x0] = 0xf9400008、ldr x1,[x8] = 0xf9400101、br x1 = 0xd61f0020、ret（期望按 AArch64 编码手算，不跑被测实现）
# ① 表 c main 0x100 word f9400008 d65f03c0：产物 0x100 = ret（0xd65f03c0），0x104 / 0x108 原样，改写日志有「游戏缺陷修补」行，0 缺口、退出码 0
# ② 原字写错（deadbeef）：0x100 原样、记缺口 fix、退出码 3
# ③ 别的模块（sdk）的行：不碰 main（0x100 原样、0 缺口、退出码 0）
# ④ 不给表：产物与 ③ 逐字节相同（没有修补行 = 改写产物不变）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mkdir -p "$T/exefs"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
code = [0xf9400008, 0xf9400101, 0xd61f0020, 0xd65f03c0]
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * len(code))
text, ro, data = bytes(text), bytes(ro), bytes(0x1000)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = bytes(range(16))
open(sys.argv[1], 'wb').write(bytes(h) + text + ro + data)
EOF
w() { $PY -c "import struct,sys; b=open(sys.argv[1],'rb').read(); print(' '.join('%08x' % struct.unpack_from('<I', b, a)[0] for a in (0x100, 0x104, 0x108)))" "$1/main.patched.bin"; }
gaps() { local c; c=$(grep -vc '^#' "$1/main.gaps.tsv" 2>/dev/null); echo "${c:-0}"; }
run() { mkdir -p "$T/$1"; if [ -n "$2" ]; then S2A_FIX_TSV="$2" "$REW" "$T/exefs/main" "$T/$1" main > "$T/$1.log" 2>&1; else env -u S2A_FIX_TSV "$REW" "$T/exefs/main" "$T/$1" main > "$T/$1.log" 2>&1; fi; echo $?; }
printf 'c\tmain\t100\tword\tf9400008\td65f03c0\t# release → ret\n' > "$T/ok.tsv"
printf 'c\tmain\t100\tword\tdeadbeef\td65f03c0\n' > "$T/bad.tsv"
printf 'c\tsdk\t100\tword\tf9400008\td65f03c0\n' > "$T/other.tsv"
r1=$(run ok "$T/ok.tsv"); w1=$(w "$T/ok")
ck "① 0x100 改成 ret、其余原样、日志有修补行、0 缺口、退出码 0（实：${w1}，缺口 $(gaps "$T/ok")，rc ${r1}）" '[ "${w1}" = "d65f03c0 f9400101 d61f0020" ] && grep -q "游戏缺陷修补：main+0x100 f9400008 → d65f03c0" "$T/ok.log" && [ "$(gaps "$T/ok")" = 0 ] && [ "${r1}" = 0 ]'
r2=$(run bad "$T/bad.tsv"); w2=$(w "$T/bad")
ck "② 原字写错：0x100 原样、记缺口 fix、退出码 3（实：${w2}，rc ${r2}）" '[ "${w2}" = "f9400008 f9400101 d61f0020" ] && grep -q "fix" "$T/bad/main.gaps.tsv" && [ "${r2}" = 3 ]'
r3=$(run other "$T/other.tsv"); w3=$(w "$T/other")
ck "③ 别的模块的行不碰 main（实：${w3}，缺口 $(gaps "$T/other")，rc ${r3}）" '[ "${w3}" = "f9400008 f9400101 d61f0020" ] && [ "$(gaps "$T/other")" = 0 ] && [ "${r3}" = 0 ]'
r4=$(run none ""); 
ck "④ 不给表：产物与 ③ 逐字节相同（rc ${r4}）" '[ "${r4}" = 0 ] && cmp -s "$T/none/main.patched.bin" "$T/other/main.patched.bin"'
[ $bad = 0 ] && echo "✓ fix_rewrite_test" || { echo "✗ fix_rewrite_test"; exit 1; }
