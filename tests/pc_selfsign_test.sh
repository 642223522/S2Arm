#!/bin/bash
# 门禁覆盖：pack/selfsign/ runtime/src/selfsign.c
# 电脑侧签名小工具 s2a-selfsign（pack/selfsign）与手机端签法（runtime/src/selfsign.c，免费团队真机验过）对照，只 Mac（要 cc / codesign / openssl / cargo）。
#   期望不靠被测实现：同一份 ad-hoc 签的 arm64 dylib、同一把测试钥匙（openssl 现生成的自签名证书，带代码签名用途；不用任何真证书），
#   ① 两边输出文件一样长、签名之前的字节（含改过的 LC_CODE_SIGNATURE / __LINKEDIT）逐字节相同
#   ② SuperBlob 里 CodeDirectory(0) / Requirements(2) / XML 权限(5) / DER 权限(7) 四块逐字节相同（CMS 不比：签名时间不同；两边都只带叶证书，S2A_SELFSIGN_NOCHAIN=1）
#   ⑦ 不设 S2A_SELFSIGN_NOCHAIN（玩家路径）：CMS 里带叶证书 + WWDR G3 + Apple Root 三张
#   ③ s2a-selfsign 的结果：codesign -dvvv 读出 Identifier = 包名、TeamIdentifier = 团队号；codesign -d --entitlements 读出 application-identifier
#   ④ CMS 签名对 CodeDirectory 验得过（openssl cms -verify，信任这张测试证书）
#   ⑤ 私钥两种 PEM（PKCS#1 / PKCS#8）签出的 CodeDirectory 相同；⑥ 参数缺 → 退出码 2；坏文件 → 退出码 1、一行原因
set -u; cd "$(dirname "$0")/.." || exit 1
[ "$(uname)" = Darwin ] || { echo "（环境未就绪：只 Mac）"; exit 75; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pc_selfsign.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "  通 $1"; else echo "  【红】$1"; bad=1; fi; }
B=${S2A_SELFSIGN_BIN:-build/selfsign/release/s2a-selfsign}
[ -x "$B" ] || cargo build -q --release --manifest-path pack/selfsign/Cargo.toml --target-dir build/selfsign || { echo "✗ pc_selfsign：编不出 s2a-selfsign"; exit 1; }
cd "$T"
printf 'int f(void){return 1;}\nint g(void){return 2;}\n' > a.c && cc -arch arm64 -dynamiclib -o in.dylib a.c && codesign -f -s - in.dylib 2>/dev/null || { echo "✗ 造不出 ad-hoc dylib"; exit 1; }
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=pc_selfsign_test/OU=ABCDE12345' -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=critical,codeSigning' -keyout k8.pem -out c.pem 2>/dev/null && openssl rsa -in k8.pem -traditional -out k1.pem 2>/dev/null \
  && openssl x509 -in c.pem -outform DER -out c.der && openssl pkcs12 -export -inkey k8.pem -in c.pem -out id.p12 -passout pass:t -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null \
  || { echo "✗ 造不出测试证书"; exit 1; }
R=$OLDPWD
cc -O1 -I"$R/runtime/src" -I"$R/runtime/include" -o ref "$R/pack/selfsign/tests/ref.c" "$R/runtime/src/selfsign.c" -framework Security -framework CoreFoundation $(python3 "$R/tools/weak_link_decl.py" flags host) 2>ref.err || { echo "✗ 对照程序编不出：$(head -3 ref.err)"; exit 1; }
./ref id.p12 t ABCDE12345 io.s2arm.games.test in.dylib out_c.dylib || { echo "✗ 手机端签法签不出"; exit 1; }
cp in.dylib out_r.dylib && S2A_SELFSIGN_NOCHAIN=1 "$R/$B" --key k1.pem --cert c.der --bundle-id io.s2arm.games.test --team ABCDE12345 out_r.dylib || { echo "✗ s2a-selfsign 签不出"; exit 1; }
cp in.dylib out_r8.dylib && S2A_SELFSIGN_NOCHAIN=1 "$R/$B" --key k8.pem --cert c.der --bundle-id io.s2arm.games.test --team ABCDE12345 out_r8.dylib || { echo "✗ s2a-selfsign（PKCS#8）签不出"; exit 1; }
blobs() { python3 -I - "$1" <<'PY'
import struct, sys, hashlib
b = open(sys.argv[1], 'rb').read()
ncmds = struct.unpack_from('<I', b, 16)[0]; p = 32; dataoff = None
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', b, p)
    if cmd == 0x1d: dataoff = struct.unpack_from('<I', b, p + 8)[0]
    p += size
sb = b[dataoff:]; n = struct.unpack_from('>I', sb, 8)[0]
print('len', len(b), 'pre', hashlib.sha256(b[:dataoff]).hexdigest())
for i in range(n):
    t, o = struct.unpack_from('>II', sb, 12 + 8 * i); l = struct.unpack_from('>I', sb, o + 4)[0]
    print(hex(t), l if t == 0x10000 else hashlib.sha256(sb[o:o + l]).hexdigest())
PY
}
blobs out_c.dylib > c.txt; blobs out_r.dylib > r.txt; blobs out_r8.dylib > r8.txt
ck "① 文件长度、签名之前的字节相同" '[ "$(head -1 c.txt)" = "$(head -1 r.txt)" ]'
ck "② CodeDirectory / Requirements / XML 权限 / DER 权限四块逐字节相同" '[ "$(grep -E "^0x(0|2|5|7) " c.txt)" = "$(grep -E "^0x(0|2|5|7) " r.txt)" ] && [ $(grep -cE "^0x(0|2|5|7) " r.txt) = 4 ]'
info=$(codesign -dvvv out_r.dylib 2>&1); ents=$(codesign -d --entitlements - out_r.dylib 2>&1)
ck "③ Identifier = 包名、TeamIdentifier = 团队号、带权限" '[[ "$info" == *"Identifier=io.s2arm.games.test"* && "$info" == *"TeamIdentifier=ABCDE12345"* && "$ents" == *"ABCDE12345.io.s2arm.games.test"* ]]'
python3 -I - out_r.dylib cd.bin cms.der <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read(); ncmds = struct.unpack_from('<I', b, 16)[0]; p = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', b, p)
    if cmd == 0x1d: d = struct.unpack_from('<I', b, p + 8)[0]
    p += size
sb = b[d:]; n = struct.unpack_from('>I', sb, 8)[0]
for i in range(n):
    t, o = struct.unpack_from('>II', sb, 12 + 8 * i); l = struct.unpack_from('>I', sb, o + 4)[0]
    if t == 0: open(sys.argv[2], 'wb').write(sb[o:o + l])
    if t == 0x10000: open(sys.argv[3], 'wb').write(sb[o + 8:o + l])
PY
ck "④ CMS 签名对 CodeDirectory 验得过" 'openssl cms -verify -binary -inform DER -in cms.der -content cd.bin -CAfile c.pem -purpose any -out /dev/null 2>/dev/null'
ck "⑤ PKCS#1 / PKCS#8 私钥签出的 CodeDirectory 相同" '[ "$(grep "^0x0 " r.txt)" = "$(grep "^0x0 " r8.txt)" ]'
"$R/$B" --key k1.pem out_r.dylib 2>/dev/null; rc2=$?
printf 'x' > bad.dylib; err=$("$R/$B" --key k1.pem --cert c.der --bundle-id a.b --team ABCDE12345 bad.dylib 2>&1); rc1=$?
ck "⑥ 缺参数退出码 2、坏文件退出码 1 一行原因" '[ $rc2 = 2 ] && [ $rc1 = 1 ] && [ $(printf "%s\n" "$err" | wc -l) = 1 ]'
cp in.dylib out_full.dylib && "$R/$B" --key k1.pem --cert c.der --bundle-id io.s2arm.games.test --team ABCDE12345 out_full.dylib
python3 -I - out_full.dylib full_cms.der <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read(); ncmds = struct.unpack_from('<I', b, 16)[0]; p = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', b, p)
    if cmd == 0x1d: d = struct.unpack_from('<I', b, p + 8)[0]
    p += size
sb = b[d:]; n = struct.unpack_from('>I', sb, 8)[0]
for i in range(n):
    t, o = struct.unpack_from('>II', sb, 12 + 8 * i); l = struct.unpack_from('>I', sb, o + 4)[0]
    if t == 0x10000: open(sys.argv[2], 'wb').write(sb[o + 8:o + l])
PY
subj=$(openssl pkcs7 -inform DER -in full_cms.der -print_certs -noout 2>/dev/null | grep -c "^subject")
ck "⑦ 玩家路径带叶证书 + WWDR G3 + Apple Root 三张（实际 $subj 张）" '[ "$subj" = 3 ] && openssl pkcs7 -inform DER -in full_cms.der -print_certs -noout 2>/dev/null | grep -q "OU=G3"'
[ $bad = 0 ] && echo "✓ pc_selfsign：全过" || { echo "✗ pc_selfsign：有不通"; cat c.txt r.txt; exit 1; }
