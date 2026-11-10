#!/bin/bash
# tests/autoplay/vision.sh 解释器 / timeout 口径单测：bash tests/vision_env_test.sh（不联网：claude 是假的，没有中转站 / OpenRouter 钥匙）
# 判据：PATH 上的 python3 不能用（模拟没装钉版包的系统 / Homebrew Python）、PATH 上的 timeout 是坏的，
#   S2A_PY 指到能用的解释器时，驾驶员照常走到 claude CLI 后端答出按键（退出 0、回答里有 keys）；
#   S2A_PY 没设、tools/machine.local 也没写时退回 PATH 上的 python3（同 runtime/run_mac.sh），坏 python3 → 驾驶员失败（负对照：口径没被改成别的探测）。
set -u
H=$(cd "$(dirname "$0")"/.. && pwd); V=$H/tests/autoplay/vision.sh
PY=$(command -v python3); bad=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p "$T/bin" "$T/home"
printf '#!/bin/sh\necho "坏 python3：$*" >&2\nexit 1\n' > "$T/bin/python3"
printf '#!/bin/sh\necho "坏 timeout" >&2\nexit 127\n' > "$T/bin/timeout"
cat > "$T/bin/claude" <<'EOS'
#!/bin/sh
cat > /dev/null
echo '{"type":"result","result":"{\"keys\":[\"A\"],\"playable\":false,\"why\":\"标题画面\"}"}'
EOS
chmod +x "$T/bin/"*
"$PY" -c 'import struct, sys, zlib
raw = b"\x00\x00\x00\x00"; ch = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))' "$T/s.png"
run() { env -u OPENROUTER_API_KEY -u ANTHROPIC_API_KEY -u S2A_PYTHON HOME="$T/home" PATH="$T/bin:/usr/bin:/bin" S2A_VISION_BACKEND=claude \
          S2A_VISION_RELAY_KEY="$T/none" S2A_VISION_OR_KEY="$T/none" "$@" bash "$V" "$T/s.png" "$T/$N.json" > /dev/null 2>&1; }
[ -f "$H/tools/machine.local" ] && grep -q '^S2A_PY=' "$H/tools/machine.local" && { echo "跳过：本机 tools/machine.local 写了 S2A_PY，负对照不成立"; exit 75; }

N=good; run S2A_PY="$PY"; rc=$?
ck "① S2A_PY 能用、PATH 上 python3 / timeout 都坏：退出 0（实为 ${rc}）、回答有 keys A（实为 $(cat "$T/good.json" 2> /dev/null)）" \
  '[ $rc = 0 ] && grep -q "\"keys\": \[\"A\"\]" "$T/good.json"'
N=nopy; run; rc=$?
ck "② 负对照：没设 S2A_PY → 退回 PATH 上的坏 python3，驾驶员失败（退出 ${rc}）" '[ $rc != 0 ]'
[ $bad = 0 ] && echo "vision.sh 解释器 / timeout 口径单测全过" || { echo "vision.sh 解释器 / timeout 口径单测有不通"; exit 1; }
