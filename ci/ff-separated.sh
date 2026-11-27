#!/usr/bin/env bash
# FF Resonance SEPARATED pack on a GitHub-hosted xcode-27 runner
# (public fork => Actions is free; user rule: never generate a charge).
# Generated from codemagic.yaml (branch codemagic-container) so the two
# pipelines stay in lockstep; steps run in subshells with the same
# fatal/tolerant semantics as the Codemagic steps (ignore_failure).
# Products: S2Arm-shell.ipa (shell-only) + 0100B8A026F14000.s2arm,
# uploaded to the private relay release ff-resonance-container-out.
if [ -z "${S2A_BASH5:-}" ] && [ -x /opt/homebrew/bin/bash ]; then
  S2A_BASH5=1 exec /opt/homebrew/bin/bash "$0" "$@"
fi
export FF_WORK="${RUNNER_TEMP:-$HOME}/ff-work"
mkdir -p "$FF_WORK"
PACK_RC=0
cd "$(dirname "$0")/.."
echo "repo: $(pwd)  FF_WORK: $FF_WORK"
df -h / || true

echo "===== STEP: Install tools (bash 5, zstd, spirv-cross) ====="
(
set -ux
df -h /
xcodebuild -version
brew install bash zstd spirv-cross make meson ninja
bash --version | head -1
zstd --version
which spirv-cross; spirv-cross --version || true
which gmake; gmake --version | head -1
which meson; meson --version; which ninja; ninja --version
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || { echo "STEP FAILED rc=$STEP_RC: Install tools (bash 5, zstd, spirv-cross)"; exit "$STEP_RC"; }

echo "===== STEP: Download game + keys from relay repo ====="
(
set -eux
FF_WORK="$FF_WORK"
mkdir -p "$FF_WORK/game" "$FF_WORK/keys" "$FF_WORK/dl"
curl -s -H "Authorization: Bearer $RELAY_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/642223522/game-relay/releases/tags/ff-resonance \
  -o "$FF_WORK/release.json"
python3 - "$FF_WORK" <<'PYEOF'
import json, sys
ff = sys.argv[1]
d = json.load(open(f'{ff}/release.json'))
with open(f'{ff}/assets.txt', 'w') as f:
    for a in d['assets']:
        f.write(f"{a['id']} {a['name']}\n")
print(len(d['assets']), 'assets')
PYEOF
while read -r aid aname; do
  curl -L --retry 3 -H "Authorization: Bearer $RELAY_TOKEN" \
    -H "Accept: application/octet-stream" \
    "https://api.github.com/repos/642223522/game-relay/releases/assets/$aid" \
    -o "$FF_WORK/dl/$aname"
done < "$FF_WORK/assets.txt"
cat "$FF_WORK/dl/base.nsp.part-"* > "$FF_WORK/game/base.nsp"
rm -f "$FF_WORK/dl/base.nsp.part-"*
mv "$FF_WORK/dl/update.nsp" "$FF_WORK/dl/dlc1.nsp" "$FF_WORK/dl/dlc2.nsp" "$FF_WORK/dl/dlc3.nsp" "$FF_WORK/game/"
cp "$FF_WORK/dl/prod.keys" "$FF_WORK/keys/prod.keys"
cp "$FF_WORK/dl/title.keys" "$FF_WORK/keys/title.keys" 2>/dev/null || true
rm -rf "$FF_WORK/dl" "$FF_WORK/release.json" "$FF_WORK/assets.txt"
ls -la "$FF_WORK/game" "$FF_WORK/keys"
df -h /
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || { echo "STEP FAILED rc=$STEP_RC: Download game + keys from relay repo"; exit "$STEP_RC"; }

echo "===== STEP: Python venv with the pack's pinned requirements ====="
(
set -eux
FF_WORK="$FF_WORK"
python3 -m venv "$FF_WORK/venv"
"$FF_WORK/venv/bin/python" -m pip install --upgrade pip
"$FF_WORK/venv/bin/python" -m pip install \
  -r launchers/macos/requirements-runtime.txt \
  -r pack/fonts/requirements.txt
"$FF_WORK/venv/bin/python" -c "import capstone, lz4, numpy, PIL, fontTools; print('venv imports ok')"
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || { echo "STEP FAILED rc=$STEP_RC: Python venv with the pack's pinned requirements"; exit "$STEP_RC"; }

echo "===== STEP: Repo prep steps (same as ci.yml / stage-0 probe, venv python) ====="
(
FF_WORK="$FF_WORK"
PY="$FF_WORK/venv/bin/python"
"$PY" runtime/rewriter/prepare_deps.py build/rewriter-deps || echo "prep rewriter deps failed"
"$PY" pack/fonts/make_open_fonts.py "$FF_WORK/openfonts" || echo "prep open fonts failed"
bash services/systemdata/make_tzdata.sh --prepare-sources || echo "prep tzdata failed"
bash compat/fetch_base.sh || echo "prep compat base failed"
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || echo "STEP TOLERATED-FAIL rc=$STEP_RC: Repo prep steps (same as ci.yml / stage-0 probe, venv python)"

echo "===== STEP: Allow unsigned pack + commit pack-time patches in the runner ====="
(
set -eux
# oneclick.sh only accepts --sign adhoc|dev but pack/ipa.sh accepts
# S2A_SIGN=none; a one-line sed on the throwaway checkout lets
# "none" through (the user signs the IPA themselves).
sed -i '' 's/case $SIGN in adhoc|dev)/case $SIGN in adhoc|dev|none)/' pack/oneclick/oneclick.sh
grep -n 'adhoc|dev|none' pack/oneclick/oneclick.sh
# ipa.sh needs a clean tree.
git add -A
git -c user.name="s2arm-pack" -c user.email="pack@localhost" commit -m "pack-time patches: unsigned sign (runner-local, not pushed)" || echo "nothing to commit"
echo "dirty files in build dirs after commit (must be empty):"
git status --porcelain -- runtime ios graphics translator services compat Makefile || true
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || { echo "STEP FAILED rc=$STEP_RC: Allow unsigned pack + commit pack-time patches in the runner"; exit "$STEP_RC"; }

echo "===== STEP: Pre-flight translation-chain tool check (diagnostic) ====="
(
FF_WORK="$FF_WORK"
echo "spirv-cross identity path: $(which spirv-cross)"
"$FF_WORK/venv/bin/python" translator/dmsh_chain.py --check-tools || echo "check-tools FAILED (see [RED] lines above)"
echo "pre-flight done"
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || echo "STEP TOLERATED-FAIL rc=$STEP_RC: Pre-flight translation-chain tool check (diagnostic)"

echo "===== STEP: Install .NET 10 SDK + Metal components (pack prerequisites) ====="
(
set -e
VENV_PY="$FF_WORK/venv/bin/python"
"$VENV_PY" pack/jobs/applenv.py --install dotnet
ls "$HOME/.dotnet/sdk"
"$VENV_PY" pack/jobs/applenv.py --install metal
# The read-only applenv check is a DESKTOP checklist and is NOT the
# pack gate: the pack runs under S2A_PYTHON=<venv>. Advisory only.
export S2A_PYTHON="$VENV_PY"
"$VENV_PY" pack/jobs/applenv.py || echo "applenv advisory check exited $?: non-fatal, continuing to Pack"
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || { echo "STEP FAILED rc=$STEP_RC: Install .NET 10 SDK + Metal components (pack prerequisites)"; exit "$STEP_RC"; }

echo "===== STEP: Pack (unsigned oneclick; same env as the proven 2026-11-17 build) ====="
(
set +e
FF_WORK="$FF_WORK"
export S2A_PYTHON="$FF_WORK/venv/bin/python"
# Runner-class memory gate bypass (documented emergency switch in
# tools/mem_admit.sh); measured dsh peaks top out at 5.2 GB.
export S2A_MEM_ADMIT='0'
export S2A_ALL_CAPS='1'
# Keep the widen auto-table closed loop OFF: it needs the
# maintainers' out-of-repo vision-model keys, absent on a runner.
export S2A_WIDEN_AUTO_RUN='0'
mkdir -p "$FF_WORK/out"
bash pack/oneclick/oneclick.sh "$FF_WORK/game" \
  --keys "$FF_WORK/keys/prod.keys" \
  --target ios --sign none \
  --out "$FF_WORK/out" \
  --events "$FF_WORK/events.jsonl" 2>&1 | tee "$FF_WORK/pack-console.log"
RC=${PIPESTATUS[0]}
echo "oneclick exit code: $RC"
df -h / || true
exit $RC
)
PACK_RC=$?
echo "pack step rc=$PACK_RC (continuing to collect/diagnose regardless)"

echo "===== STEP: Assemble separated products (shell-only IPA + .s2arm program package) ====="
(
set -eux
set -o pipefail
FF_WORK="$FF_WORK"
PY="$FF_WORK/venv/bin/python"
# The ship_ext product root is the versioned <name>@pkg-<commit9>
# root (top-level main.npdm), NOT the oneclick seed root
# <name>@oc-<hash> (unpack.tsv, exefs/main.npdm) that img.py uses.
# Build #1 died on exactly this mix-up; the pack itself was fine.
C=$(git rev-parse HEAD | cut -c1-9)
ROOT=$(ls -d "$FF_WORK/out/roots"/*@pkg-"$C" 2>/dev/null | head -1)
[ -n "$ROOT" ] || ROOT=$(dirname "$(find "$FF_WORK/out/roots" -maxdepth 2 -name main.npdm 2>/dev/null | head -1)")
[ -n "$ROOT" ] && [ -f "$ROOT/main.npdm" ] || { echo "pkg product root (top-level main.npdm) not found:"; find "$FF_WORK/out/roots" -maxdepth 3 | head -40; exit 1; }
echo "product root: $ROOT"
# The oneclick run built the game-independent prebuilt shell into
# the shell cache (pack/ipa.sh step 1). Find it: a dir holding
# manifest.json + root/ under a *shell* path.
SHELL_DIR=""
while IFS= read -r mf; do
  d=$(dirname "$mf")
  if [ -d "$d/root" ]; then SHELL_DIR="$d"; break; fi
done <<EOF
$(find "$HOME/.s2arm" "$FF_WORK/out" -type f -name manifest.json -path '*shell*' 2>/dev/null)
EOF
[ -n "$SHELL_DIR" ] || { echo "FATAL: prebuilt shell not found"; find "$HOME/.s2arm" "$FF_WORK/out" -maxdepth 7 -type d 2>/dev/null | head -40; exit 1; }
echo "shell dir: $SHELL_DIR"
cat "$SHELL_DIR/manifest.json" | head -c 600; echo
mkdir -p "$FF_WORK/container"
# 1) Shell-only container IPA (0.6.0 通用壳: no game baked in).
"$PY" pack/ship_ext.py container \
  --shell-only \
  --shell "$SHELL_DIR" \
  --bundle-id io.s2arm.games \
  --icon launchers/macos/Branding/AppIcon-iOS.png \
  --display-name S2Arm \
  --host-abi 1 \
  --sign none \
  --out "$FF_WORK/container/S2Arm.app" 2>&1 | tee -a "$FF_WORK/container.log"
"$PY" pack/app_bundle.py write_ipa "$FF_WORK/container/S2Arm.app" "$FF_WORK/container/S2Arm-shell.ipa" 2>&1 | tee -a "$FF_WORK/container.log"
"$PY" - "$FF_WORK/container/S2Arm-shell.ipa" <<'PYEOF'
import sys, zipfile, json
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
assert 'Payload/S2Arm.app/s2a_catalogue.json' in names, 'catalogue missing'
baked = [n for n in names if '/Games/' in n or 'S2AImages-' in n]
print('baked-in game entries (want none):', baked)
assert not baked, baked
cat = json.loads(z.read('Payload/S2Arm.app/s2a_catalogue.json'))
print('shell catalogue:', json.dumps(cat, ensure_ascii=False))
print('total entries:', len(names))
PYEOF
# 2) The game's program package, packed as ONE .s2arm file.
# ship_ext program places {S2AImages-<gid>.dylib, Games/<gid>/};
# the packing below mirrors pack/jobs/program_pack.py catalogue()
# and pack/jobs/install.py push_program() for the UNSIGNED route
# (team=None: the phone re-signs with the imported cert, exactly
# like push_programs' else-branch for other tools' S2Arm).
# Meta values are derived the same way program_pack.compat does:
# host_abi = s2a_host_abi (1), chain = DMSH_CHAIN in
# graphics/nvn/gfx/nvn/dmsh_chain.h, rewriter_id =
# sha256(pack/rewriter.py source)[:16].
"$PY" pack/ship_ext.py program \
  --shell "$SHELL_DIR" \
  --root "$ROOT" \
  --out "$FF_WORK/program-pkg" 2>&1 | tee "$FF_WORK/program.json"
"$PY" - "$FF_WORK/program-pkg" "$FF_WORK/container" <<'PYEOF'
import hashlib, io, json, os, re, subprocess, sys, tarfile
from pathlib import Path
pkg, outdir = Path(sys.argv[1]), Path(sys.argv[2])
info = json.loads(Path((Path(os.environ['FF_WORK']) / 'program.json')).read_text(encoding='utf-8').strip().splitlines()[-1])
gid = info['gid'].upper()
image = pkg / f'S2AImages-{gid}.dylib'
assert image.is_file(), image
def sha(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()
chain = re.search(r'^#define DMSH_CHAIN "([0-9a-f]+)"',
                  Path('graphics/nvn/gfx/nvn/dmsh_chain.h').read_text(), re.M).group(1)
r = subprocess.run([sys.executable, '-X', 'utf8', '-B', 'pack/rewriter.py', 'source'],
                   capture_output=True, text=True, encoding='utf-8')
assert r.returncode == 0 and r.stdout.strip(), r.stderr[-300:]
meta = dict(host_abi=1, chain=chain,
            rewriter_id=hashlib.sha256(r.stdout.encode()).hexdigest()[:16],
            name=info.get('name', ''), display_version=info.get('display_version', ''),
            image_sha256=sha(image))
cat = dict(schema=1, title_id=gid, name=meta['name'], display_version=meta['display_version'],
           host_abi=meta['host_abi'], chain=meta['chain'], rewriter_id=meta['rewriter_id'],
           image=image.name, image_sha256=meta['image_sha256'], team=None)
if (pkg / 'Games' / gid / 'icon.jpg').is_file():
    cat['icon'] = f'Games/{gid}/icon.jpg'
if (pkg / 'Games' / gid / 'banner.jpg').is_file():
    cat['banner'] = f'Games/{gid}/banner.jpg'
cat_bytes = json.dumps(cat, ensure_ascii=False, indent=1).encode('utf-8')
(outdir / 'program-catalogue.json').write_bytes(cat_bytes)
files = [('program/' + p.relative_to(pkg).as_posix(), p) for p in sorted(pkg.rglob('*'))
         if p.is_file() and p.name not in ('meta.json', '.key', 'catalogue.json')]
head = dict(format='s2arm', schema=1, title_id=gid, name=cat['name'],
            display_version=cat['display_version'], host_abi=cat['host_abi'],
            chain=cat['chain'], rewriter_id=cat['rewriter_id'], image=cat['image'],
            image_sha256=cat['image_sha256'],
            bytes=len(cat_bytes) + sum(p.stat().st_size for _, p in files),
            signer=dict(mode='push', team=None))
dest = outdir / f'{gid}.s2arm'
# zstd frame with content checksum, same as programs.zstd_writer;
# fall back to the zstd CLI if the venv lacks both stdlib (3.14)
# and the zstandard module.
import contextlib
stack = contextlib.ExitStack()
try:
    from compression import zstd
    z = stack.enter_context(zstd.ZstdFile(str(dest), 'w', options={
        zstd.CompressionParameter.compression_level: 3,
        zstd.CompressionParameter.checksum_flag: 1}))
except ImportError:
    try:
        import zstandard
        raw = open(dest, 'wb')
        z = stack.enter_context(zstandard.ZstdCompressor(level=3, threads=-1, write_checksum=True).stream_writer(raw, closefd=True))
    except ImportError:
        proc = subprocess.Popen(['zstd', '-3', '--checksum', '-q', '-o', str(dest) + '.tmp'],
                                stdin=subprocess.PIPE)
        z = proc.stdin
        stack.callback(lambda: (z.close(), proc.wait(), os.replace(str(dest) + '.tmp', dest)))
with stack, tarfile.open(fileobj=z, mode='w|', format=tarfile.USTAR_FORMAT) as t:
    def add(name, data=None, path=None):
        ti = tarfile.TarInfo(name)
        ti.mode, ti.mtime = 0o644, 0
        if path is None:
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
            return
        ti.size = path.stat().st_size
        with open(path, 'rb') as f:
            t.addfile(ti, f)
    add('s2arm.json', json.dumps(head, ensure_ascii=False, indent=1).encode('utf-8'))
    add('program/catalogue.json', cat_bytes)
    for name, path in files:
        add(name, path=path)
# Verify: reopen, first entry must be s2arm.json, dylib present.
names = None
try:
    from compression import zstd
    with zstd.ZstdFile(str(dest), 'r') as z, tarfile.open(fileobj=z, mode='r|') as t:
        names = [m.name for m in t]
except ImportError:
    try:
        import zstandard
        with open(dest, 'rb') as raw, zstandard.ZstdDecompressor().stream_reader(raw) as z, \
                tarfile.open(fileobj=z, mode='r|') as t:
            names = [m.name for m in t]
    except ImportError:
        subprocess.run(['zstd', '-d', '-q', '-f', str(dest), '-o', str(dest) + '.tar'], check=True)
        with tarfile.open(str(dest) + '.tar') as t:
            names = t.getnames()
        os.unlink(str(dest) + '.tar')
print('s2arm entries:', names)
assert names[0] == 's2arm.json', names[:3]
assert f'program/S2AImages-{gid}.dylib' in names
assert 'program/catalogue.json' in names
print('s2arm OK:', dest, dest.stat().st_size, 'bytes; head:', json.dumps(head, ensure_ascii=False))
PYEOF
ls -la "$FF_WORK/container"
df -h /
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || echo "STEP TOLERATED-FAIL rc=$STEP_RC: Assemble separated products (shell-only IPA + .s2arm program package)"

echo "===== STEP: Convert pack to IMG (insurance copy for the relay) ====="
(
set -eux
FF_WORK="$FF_WORK"
PY="$FF_WORK/venv/bin/python"
# Insurance only: a failed convert must never block the upload
# (container build #2 lesson). Find the root that actually holds
# the RomFS: new code keeps it as the standard image romfs.std
# (0.6.0, "RomFS 不落散文件"), older roots keep a loose romfs/
# directory; img.py convert handles both. The seed root (@sd-)
# has neither — don't let unpack.tsv discovery pick it.
ROOT=$(dirname "$(find "$FF_WORK/out/roots" -maxdepth 2 -name 'romfs.std' 2>/dev/null | head -1)")
[ -n "$ROOT" ] || ROOT=$(dirname "$(find "$FF_WORK/out/roots" -maxdepth 2 -type d -name romfs 2>/dev/null | head -1)")
[ -n "$ROOT" ] && { [ -d "$ROOT/romfs" ] || [ -f "$ROOT/romfs.std" ]; } || { echo "product root with romfs not found:"; find "$FF_WORK/out/roots" -maxdepth 3 | head -40; exit 1; }
PACK=$(find "$FF_WORK/out" -maxdepth 1 -type d -name '*资源包' | head -1)
[ -n "$PACK" ] || { echo "resource pack folder not found in out/"; ls "$FF_WORK/out"; exit 1; }
echo "root: $ROOT"; echo "pack: $PACK"; df -h /
"$PY" pack/img.py convert "$ROOT" "$PACK" --gid 0100B8A026F14000 2>&1 | tee "$FF_WORK/img-convert.log"
head -c 8 "$PACK/game.img"; echo " <- game.img magic (want S2AIMG01)"
mkdir -p "$FF_WORK/ship"
"$PY" pack/img.py export "$PACK" "$FF_WORK/ship/game.img" 2>&1 | tee "$FF_WORK/img-export.log"
"$PY" pack/img.py ls "$FF_WORK/ship/game.img" > "$FF_WORK/img-ls.txt" 2>&1 || true
echo "img entries: $(wc -l < "$FF_WORK/img-ls.txt")"
du -sh "$FF_WORK/ship"/*; df -h /
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || echo "STEP TOLERATED-FAIL rc=$STEP_RC: Convert pack to IMG (insurance copy for the relay)"

echo "===== STEP: Collect deliverables and upload to relay ====="
(
set -eux
FF_WORK="$FF_WORK"
D="$FF_WORK/deliver"
mkdir -p "$D/logs"
# Diagnostic copies must NEVER kill the step (build #4 lesson),
# and a failed assembly must not waste the whole pack (container
# build #1 lesson): upload whatever exists — the separated
# products if present, else the standalone IPA + insurance img —
# and let RESULT.txt say plainly which case it is. Fatal only
# when no IPA at all was produced.
if [ -f "$FF_WORK/container/S2Arm-shell.ipa" ]; then
  cp "$FF_WORK/container/S2Arm-shell.ipa" "$D/"
  echo "shell IPA: OK"
else
  echo "WARNING: shell IPA missing; uploading fallback products for diagnosis"
fi
cp "$FF_WORK/container/"*.s2arm "$D/" 2>/dev/null || echo "WARNING: .s2arm package missing"
cp "$FF_WORK/container/program-catalogue.json" "$D/" 2>/dev/null || true
find "$FF_WORK/out" -maxdepth 1 -name '*.ipa' -exec cp {} "$D/" \; 2>/dev/null || true
[ -n "$(ls "$D"/*.ipa 2>/dev/null)" ] || { echo "FATAL: no IPA at all produced"; exit 1; }
cp "$FF_WORK/container/S2Arm.app/s2a_catalogue.json" "$D/" 2>/dev/null || true
cp pack/app.entitlements "$D/" 2>/dev/null || true
[ -f "$FF_WORK/ship/game.img" ] && cp "$FF_WORK/ship/game.img" "$D/" || echo "insurance img missing (non-fatal)"
cp "$FF_WORK/img-convert.log" "$FF_WORK/img-export.log" "$FF_WORK/img-ls.txt" "$D/logs/" 2>/dev/null || true
cp "$FF_WORK/events.jsonl" "$D/logs/" 2>/dev/null || true
cp "$FF_WORK/pack-console.log" "$D/logs/" 2>/dev/null || true
cp "$FF_WORK/container.log" "$D/logs/" 2>/dev/null || true
cp "$FF_WORK/program.json" "$D/logs/" 2>/dev/null || true
cp -R "$FF_WORK/out/logs" "$D/logs/out" 2>/dev/null || true
for r in "$FF_WORK/out/roots"/*@*; do
  [ -d "$r" ] || continue
  for f in s2a_caps.tsv s2a_caps.all.tsv widen_sites.tsv caps.log; do
    cp "$r/$f" "$D/logs/" 2>/dev/null || true
  done
done
{
  echo "# FF Resonance SEPARATED pack result (Codemagic, new S2Arm)"
  if [ -f "$D/S2Arm-shell.ipa" ]; then echo "SHELL IPA: PRESENT"; else echo "SHELL IPA: MISSING (assembly failed; see logs/container.log; fallback products uploaded)"; fi
  if compgen -G "$D/*.s2arm" > /dev/null; then echo "S2ARM PACKAGE: PRESENT"; else echo "S2ARM PACKAGE: MISSING (see logs/container.log)"; fi
  echo "- shell catalogue:"
  cat "$D/s2a_catalogue.json" 2>/dev/null || echo "catalogue not collected"
  echo "- program catalogue:"
  cat "$D/program-catalogue.json" 2>/dev/null || echo "program catalogue not collected"
  echo "- widen verdict (shipped caps):"
  grep -h '^widen' "$D/logs/s2a_caps.all.tsv" 2>/dev/null || grep -h '^widen' "$D/logs/s2a_caps.tsv" 2>/dev/null || echo "caps not collected"
  echo "- deliverables:"
  find "$D" -maxdepth 1 -print
  echo "- sizes:"
  du -sh "$D"/* 2>/dev/null
  echo "- events (result lines):"
  grep '"ev":"result"' "$FF_WORK/events.jsonl" 2>/dev/null || echo "no result event (pack did not finish)"
  echo "- disk:"
  df -h / || true
} | tee "$D/RESULT.txt"
(cd "$D" && zip -qr logs.zip logs && rm -rf logs)
# Split the insurance .img into <=1800 MiB parts (release cap 2 GB).
if [ -f "$D/game.img" ]; then
  (cd "$D" && split -b 1800m game.img game.img.part- && rm game.img)
fi
ls -la "$D"
# Get or create the output release, clearing any previous assets.
REL_ID=$(curl -s -H "Authorization: Bearer $RELAY_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/642223522/game-relay/releases/tags/ff-resonance-container-out \
  | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', ''))")
if [ -z "$REL_ID" ]; then
  REL_ID=$(curl -s -X POST -H "Authorization: Bearer $RELAY_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    https://api.github.com/repos/642223522/game-relay/releases \
    -d '{"tag_name":"ff-resonance-container-out","name":"最终幻想：共鸣 分离式产物（S2Arm 新版 / Codemagic）","body":"S2Arm 新版分离式：S2Arm-shell.ipa（空容器，未签名）+ 0100B8A026F14000.s2arm（FF 共鸣程序包，手机上用 S2Arm 打开导入）+ game.img 分片（保险副本，1800 MiB/片，合并：cat game.img.part-* > game.img）+ s2a_catalogue.json / program-catalogue.json + app.entitlements + 日志。"}' \
    | python3 -c "import sys, json; print(json.load(sys.stdin)['id'])")
else
  curl -s -H "Authorization: Bearer $RELAY_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/642223522/game-relay/releases/$REL_ID/assets" \
    | python3 -c "
import sys, json, os, urllib.request
tok = os.environ['RELAY_TOKEN']
for a in json.load(sys.stdin):
    req = urllib.request.Request(f\"https://api.github.com/repos/642223522/game-relay/releases/assets/{a['id']}\", method='DELETE', headers={'Authorization': f'Bearer {tok}', 'Accept': 'application/vnd.github+json'})
    urllib.request.urlopen(req)
    print('deleted old asset', a['name'])
"
fi
echo "output release id: $REL_ID"
# STREAMING upload only (curl -T): --data-binary OOMs on GB parts
# (build #3 lesson). HTTP 201 checked per file; final byte-exact
# verification of every local file against the release listing.
for f in "$D"/*; do
  [ -f "$f" ] || continue
  n=$(basename "$f")
  sz=$(stat -f%z "$f")
  echo "uploading $n ($sz bytes) [streaming curl -T]"
  resp=$(curl -s -w '\n%{http_code}' -X POST -H "Authorization: Bearer $RELAY_TOKEN" \
    -H "Content-Type: application/octet-stream" \
    -T "$f" \
    "https://uploads.github.com/repos/642223522/game-relay/releases/$REL_ID/assets?name=$n")
  code=$(printf '%s' "$resp" | tail -1)
  echo " -> HTTP $code"
  [ "$code" = "201" ] || { echo "UPLOAD FAILED for $n (HTTP $code): $(printf '%s' "$resp" | head -c 400)"; exit 1; }
done
python3 - "$D" "$REL_ID" <<'PYEOF'
import sys, json, os, urllib.request
d, rel = sys.argv[1], sys.argv[2]
tok = os.environ['RELAY_TOKEN']
req = urllib.request.Request(
    f"https://api.github.com/repos/642223522/game-relay/releases/{rel}/assets?per_page=100",
    headers={'Authorization': f'Bearer {tok}', 'Accept': 'application/vnd.github+json'})
assets = {a['name']: a['size'] for a in json.load(urllib.request.urlopen(req))}
bad = []
for name in sorted(os.listdir(d)):
    p = os.path.join(d, name)
    if not os.path.isfile(p):
        continue
    want, got = os.path.getsize(p), assets.get(name)
    print(f"{name}: local {want} remote {got}")
    if got != want:
        bad.append(name)
if bad:
    print("MISSING/MISMATCHED:", bad)
    sys.exit(1)
print("release assets verified byte-exact")
PYEOF
echo "ALL UPLOADS VERIFIED"
)
STEP_RC=$?
[ "$STEP_RC" = 0 ] || { echo "STEP FAILED rc=$STEP_RC: Collect deliverables and upload to relay"; exit "$STEP_RC"; }

echo "===== DONE pack_rc=$PACK_RC ====="
exit "$PACK_RC"
