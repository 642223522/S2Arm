#!/bin/bash
# 拉取基础管线随包归档单测（graphics/tools/direct/base_pipelines.py + pack/stage_direct_cpso.sh；要本机 Metal 工具链与 Metal 4 GPU，约 30 秒）：bash graphics/tools/direct/tests/t_base_pipelines.sh
# 夹具：合成直连库目录。库容器（lib.idx + lib.000.pak，格式同 graphics/nvn/lib_pack_core.inc）：
#   顶点键 A、B、N、L 各有种类 55 拉取库（入口 main0 / main0_z，不带 [[stage_in]]，A 与 B 的 main0 函数体不同）与反射（种类 1）：A、B 带 pull {main0, slot 16}，
#   N 没有 pull，L 带 pull 但 writes_layer；片元键 P、Q、R 的种类 0 指向同一段批库（s<P>_main0 不声明函数常量、s<Q>_main0 声明一个带缺省的常量、s<R>_main0 不用），
#   反射 fn_prefix「s<键>_」+ entry main0。shader_pairs.tsv：A P、A Q、B P、N P、L P、A M（M 不在库里）、再一行 A P（重复）、一行 # 注释。
# 期望（不跑被测实现就写得出）：
#   ① 出 3 个文件，名字 = 「p」+ sha256("<顶点键>_b\t<片元键>_b\tmain0") 前 40 位 + .mtl4archive（shasum 现算，同设备 nvn_hybrid.inc hybrid_pkg_name）：A×P、A×Q、B×P；
#      读数「着色器对 6 对（跳过：顶点没有拉取库 1、写层号 1、片元不在库里 1），出 3 对」
#   ①b 归档只带本对两个函数：A×P 的归档里没有 s<Q>_main0 / s<R>_main0 / main0_z 这些串，读数「按整段库带函数 0 次」
#   ② 设备同一描述（t_base_pipelines.m：拉取库与批库整份载入、8 个颜色附件留空、采样 1）：A×P、A×Q（片元带常量 → 特化描述）、B×P 都命中，且能按画布特化
#   ③ 反证：A×P 的归档 + B 的顶点 / + Q 的片元 / + A 的 main0_z 不中；附件 1–7 写 Invalid（改之前的设备写法）不中；采样 4 不中；按上一个系统大版本出的不中
#   ④ 再跑同参数：缓存命中 3、现编 0，文件逐字节相同
#   ⑤ metal-tt 失败（S2A_METAL_TT 换成退 1 的假工具、空缓存）：退出 3、0 个文件、读数「失败 3 对」
#   ⑥ 阶段 pack/stage_direct_cpso.sh（假产物根、S2A_PACK_PLAT=macos、S2A_PSO_ARCHS=本机架构）：现行根 pipelines/ 里恰是这 3 个 .mtl4archive（夹具没有计算键）、记键，
#      出的 A×P 按设备描述命中；缓存落在直连缓存 store/cpso/
set -u; H=$(cd "$(dirname "$0")/../../../.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/t_base_pipelines.XXXXXX"); trap 'rm -rf "$T"' EXIT
n=0; fail=0
ck() { n=$((n + 1)); if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; fail=$((fail + 1)); fi; }
die() { echo "✗ $1"; echo "t_base_pipelines：0 项，失败 1"; exit 1; }
S2A_TC_QUIET=1 source "$H/tools/toolchain.sh" > /dev/null 2>&1 || die "统一工具链解析失败（tools/toolchain.sh）"
for t in metal metallib metal-tt; do xcrun -sdk macosx -f "$t" > /dev/null 2>&1 || die "本机没有 Metal 工具链（${t}）"; done
clang -fobjc-arc -O1 -o "$T/gpu_arch" "$H/graphics/tools/shbake/gpu_arch.m" -framework Metal -framework Foundation 2> /dev/null && ARCH=$("$T/gpu_arch") && [ -n "$ARCH" ] || die "取不到本机 GPU 架构"
clang -fobjc-arc -O1 -o "$T/probe" "$H/graphics/tools/direct/tests/t_base_pipelines.m" -framework Metal -framework Foundation 2> "$T/cc.log" || die "编探针失败：$(head -3 "$T/cc.log")"
MAJ=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJ" -ge 26 ] || die "本机 macOS ${MAJ} 没有 Metal 4（要 26 起）"
A=00000a0000000001 B=00000b0000000002 N=00000e0000000005 L=00000f0000000006 P=00000c0000000003 Q=00000c0000000004 R=00000c0000000007 M=00000d0000000008
F=$T/fx/shaders/direct; mkdir -p "$F/b-t1"
bp() {   # 拉取库：main0 读槽 16 的 float4 数组（乘 $2），main0_z 另一个函数体
  printf '#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 p [[position]]; float4 a [[user(locn0)]]; };\n' > "$T/$1.metal"
  printf 'vertex VO main0(constant float4 *dm_lay [[buffer(16)]], uint v [[vertex_id]]) { VO o; o.p = float4(dm_lay[v].xy, 0, 1); o.a = dm_lay[v] * %s; return o; }\n' "$2" >> "$T/$1.metal"
  printf 'vertex VO main0_z(constant float4 *dm_lay [[buffer(16)]], uint v [[vertex_id]]) { VO o; o.p = float4(dm_lay[v].xy, 0.5, 1); o.a = dm_lay[v]; return o; }\n' >> "$T/$1.metal"
  xcrun -sdk macosx metal -mmacosx-version-min=15.0 -c "$T/$1.metal" -o "$T/$1.air" && xcrun -sdk macosx metallib "$T/$1.air" -o "$T/$1.metallib"; }
bp vA 1.0 && bp vB 2.0 && bp vN 3.0 && bp vL 4.0 || die "夹具拉取库编不出"
cat > "$T/fb.metal" <<EOF
#include <metal_stdlib>
using namespace metal;
constant bool S2A_AT [[function_constant(7)]];
constant bool at_on = is_function_constant_defined(S2A_AT) ? S2A_AT : false;
struct F0 { float4 a [[user(locn0)]]; };
fragment float4 s${P}_main0(F0 i [[stage_in]]) { return i.a; }
fragment float4 s${Q}_main0(F0 i [[stage_in]]) { if (at_on && i.a.w < 0.5) discard_fragment(); return i.a * 0.5; }
fragment float4 s${R}_main0(F0 i [[stage_in]]) { return i.a.zyxw; }
EOF
xcrun -sdk macosx metal -mmacosx-version-min=15.0 -c "$T/fb.metal" -o "$T/fb.air" && xcrun -sdk macosx metallib "$T/fb.air" -o "$T/fb.metallib" || die "夹具批库编不出"
: > "$F/shader_map.tsv"   # 没有计算键：⑥ 阶段里计算管线那半出 0 支
printf '# 注释\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n%s\t%s\n' $A $P $A $Q $B $P $N $P $L $P $A $M $A $P > "$F/shader_pairs.tsv"
python3 - "$F/b-t1" "$T" $A $B $N $L $P $Q $R <<'EOF'
import json, struct, sys
out, T = sys.argv[1], sys.argv[2]; A, B, N, L, P, Q, R = sys.argv[3:]
pak, recs = bytearray(), []
def put(key, kind, data):
    recs.append((int(key, 16), kind, len(pak), len(data))); pak.extend(data)
pull = {'entry': 'main0', 'entry_z': 'main0_z', 'slot': 16, 'inputs': [0]}
for k, tag, j in ((A, 'vA', {'pull': pull}), (B, 'vB', {'pull': pull}), (N, 'vN', {}), (L, 'vL', {'pull': pull, 'writes_layer': True})):
    put(k, 55, open(f'{T}/{tag}.metallib', 'rb').read())
    put(k, 1, json.dumps(dict(j, stage='vs', entry='main0', entry_z='main0_z', fn_prefix=f's{k}_')).encode())
seg = open(f'{T}/fb.metallib', 'rb').read(); off = len(pak); pak.extend(seg)
for k in (P, Q, R):
    recs.append((int(k, 16), 0, off, len(seg)))
    put(k, 1, json.dumps({'stage': 'ps', 'entry': 'main0', 'fn_prefix': f's{k}_'}).encode())
recs.sort()
hd = bytearray(48); hd[:8] = b'S2ALIB\0\0'; struct.pack_into('<III', hd, 8, 1, len(recs), 1); hd[24:26] = b't1'
idx = hd + struct.pack('<QQ', len(pak), 0) + b''.join(struct.pack('<QBBHIQ', k, kind, 0, 0, ln, off) for k, kind, off, ln in recs)
open(out + '/lib.idx', 'wb').write(idx); open(out + '/lib.000.pak', 'wb').write(pak)
EOF
[ -s "$F/b-t1/lib.idx" ] || die "夹具库容器没写出来"
pfile() { printf '%s_b\t%s_b\tmain0' "$1" "$2" | shasum -a 256 | cut -c1-40 | sed 's/^/p/;s/$/.mtl4archive/'; }
FAP=$(pfile $A $P) FAQ=$(pfile $A $Q) FBP=$(pfile $B $P)
BP() { python3 "$H/graphics/tools/direct/base_pipelines.py" "$F" "$1" --plat macos "${@:2}"; }
probe() { "$T/probe" "$1" "$T/v$2.metallib" "$3" "$T/fb.metallib" "s$4_main0" "${5:-u}" "${6:-1}" 2>> "$T/probe.err"; }   # 打不开的原因进 probe.err，输出只留一行

# ① ①b ②
o=$(BP "$T/o1" --os "$MAJ" --arch "$ARCH" --cache "$T/cache" -j 2 2>&1); r=$?
ck "① 退出 0、恰好 3 个文件且就是 A×P / A×Q / B×P 的设备名（实：$(ls "$T/o1" 2> /dev/null | tr '\n' ' ')）" '[ $r = 0 ] && [ "$(ls "$T/o1" | sort)" = "$(printf "%s\n" "$FAP" "$FAQ" "$FBP" | sort)" ]'
ck "① 读数：6 对、跳过 顶点没有拉取库 1 / 写层号 1 / 片元不在库里 1、出 3 对（$(tail -1 <<< "$o" | cut -c1-160)）" \
   '[[ "$(tail -1 <<< "$o")" == *"着色器对 6 对（跳过：顶点没有拉取库 1、写层号 1、片元不在库里 1），出 3 对"* ]]'
ck "①b A×P 的归档只带本对函数：有 s<P>_main0，没有 s<Q>_main0 / s<R>_main0 / main0_z；读数「按整段库带函数 0 次」" \
   'grep -aq "s${P}_main0" "$T/o1/$FAP" && ! grep -aq "s${Q}_main0" "$T/o1/$FAP" && ! grep -aq "s${R}_main0" "$T/o1/$FAP" && ! grep -aq "main0_z" "$T/o1/$FAP" && [[ "$(tail -1 <<< "$o")" == *"按整段库带函数 0 次"* ]]'
ck "② A×P：命中、能特化（$(probe "$T/o1/$FAP" A main0 $P)）" '[ "$(probe "$T/o1/$FAP" A main0 $P)" = "hit=1 spec=1" ]'
ck "② A×Q（片元声明函数常量 → 特化描述）：命中、能特化（$(probe "$T/o1/$FAQ" A main0 $Q)）" '[ "$(probe "$T/o1/$FAQ" A main0 $Q)" = "hit=1 spec=1" ]'
ck "② B×P：命中、能特化（$(probe "$T/o1/$FBP" B main0 $P)）" '[ "$(probe "$T/o1/$FBP" B main0 $P)" = "hit=1 spec=1" ]'
# ③
ck "③ 反证：A×P 的归档 + B 的顶点不中（$(probe "$T/o1/$FAP" B main0 $P)）" '[ "$(probe "$T/o1/$FAP" B main0 $P)" = "hit=0 spec=-" ]'
ck "③ 反证：A×P 的归档 + Q 的片元不中（$(probe "$T/o1/$FAP" A main0 $Q)）" '[ "$(probe "$T/o1/$FAP" A main0 $Q)" = "hit=0 spec=-" ]'
ck "③ 反证：A×P 的归档 + A 的 main0_z 不中（$(probe "$T/o1/$FAP" A main0_z $P)）" '[ "$(probe "$T/o1/$FAP" A main0_z $P)" = "hit=0 spec=-" ]'
ck "③ 反证：附件 1–7 写 Invalid 的描述不中（$(probe "$T/o1/$FAP" A main0 $P i)）" '[ "$(probe "$T/o1/$FAP" A main0 $P i)" = "hit=0 spec=-" ]'
ck "③ 反证：采样 4 的描述不中（$(probe "$T/o1/$FAP" A main0 $P u 4)）" '[ "$(probe "$T/o1/$FAP" A main0 $P u 4)" = "hit=0 spec=-" ]'
BP "$T/o2" --os $((MAJ - 1)) --arch "$ARCH" > /dev/null 2>&1
ck "③ 反证：按系统大版本 $((MAJ - 1)) 出的不中（$(probe "$T/o2/$FAP" A main0 $P)）" '[ -s "$T/o2/$FAP" ] && [ "$(probe "$T/o2/$FAP" A main0 $P)" = "hit=0 spec=-" ]'
# ④
o=$(BP "$T/o3" --os "$MAJ" --arch "$ARCH" --cache "$T/cache" 2>&1); r=$?
ck "④ 再跑：缓存命中 3、现编 0、文件逐字节相同（$(tail -1 <<< "$o" | grep -o '缓存命中[^）]*')）" \
   '[ $r = 0 ] && [[ "$o" == *"缓存命中 3、现编 0"* ]] && cmp -s "$T/o1/$FAP" "$T/o3/$FAP" && cmp -s "$T/o1/$FAQ" "$T/o3/$FAQ" && cmp -s "$T/o1/$FBP" "$T/o3/$FBP"'
# ⑤
printf '#!/bin/sh\necho "fake metal-tt: broken" >&2; exit 1\n' > "$T/badtt"; chmod +x "$T/badtt"
o=$(S2A_METAL_TT=$T/badtt BP "$T/o4" --os "$MAJ" --arch "$ARCH" --cache "$T/cache4" 2>&1); r=$?
ck "⑤ metal-tt 失败：退出 3、0 个文件、读数失败 3 对（退出 ${r}，$(ls "$T/o4" 2> /dev/null | wc -l | tr -d ' ') 个文件）" '[ $r = 3 ] && [ -z "$(ls "$T/o4")" ] && [[ "$(tail -1 <<< "$o")" == *"失败 3 对"* ]]'
# ⑥ 阶段：假产物根（只有直连库目录与直连库阶段键），私有根
RT=$T/roots; mkdir -p "$RT/fx@v1/shaders"; cp -R "$F" "$RT/fx@v1/shaders/"; echo k1 > "$RT/fx@v1/.stage_direct"; printf 'title_id\t0100aaaa00000000\n' > "$RT/fx@v1/unpack.tsv"; ln -s fx@v1 "$RT/fx@现行"
cur() { cd -P "$RT/fx@现行" && pwd; }
o=$(S2A_ROOTS=$RT S2A_ROOTS_SHARED=$T/shared S2A_RUN_ROOT=$T/run S2A_PACK_PLAT=macos S2A_MAC_OS=$MAJ S2A_PSO_ARCHS=$ARCH J=2 bash "$H/pack/stage_direct_cpso.sh" fx 2>&1); r=$?; [ $r = 0 ] || echo "$o" | tail -5
ck "⑥ 阶段：退出 ${r}、现行根 pipelines/ 恰是这 3 个、记了键（$(grep -o '拉取基础管线归档[^；]*' <<< "$o" | head -1 | cut -c1-100)）" \
   '[ $r = 0 ] && [ "$(ls "$(cur)/shaders/direct/pipelines" 2> /dev/null | sort)" = "$(printf "%s\n" "$FAP" "$FAQ" "$FBP" | sort)" ] && [ -s "$(cur)/.stage_direct_cpso" ]'
ck "⑥ 阶段出的 A×P 按设备描述命中（$(probe "$(cur)/shaders/direct/pipelines/$FAP" A main0 $P)）、缓存 3 条落在直连缓存 store/cpso/" \
   '[ "$(probe "$(cur)/shaders/direct/pipelines/$FAP" A main0 $P)" = "hit=1 spec=1" ] && [ "$(find "$T/run/s2arm/cache/direct/0100AAAA00000000/store/cpso" -name "*.e" | wc -l | tr -d " ")" = 3 ]'
echo "t_base_pipelines：$n 项，失败 $fail"
[ $fail = 0 ]
