#!/usr/bin/env python3
# 门禁收尸进程（11-10 门禁减压 C）：gate_reap.py <门禁主进程 pid> <结果目录 $L>
#   起因：门禁顶层被 KILL（gate_stop 兜底 / 外层按组 KILL）后，在跑的步成了孤儿续跑——每步的命令在 tools/bin/timeout 自立的进程组里，
#   组 KILL 只杀到门禁那一组，步的命令组留着（11-10 启动器线一份旧预跑留下 51 个孤儿、活 1 小时 15 分）。
#   做法：脱离成守护进程（setsid、关掉继承的 fd，不攥调用方管道），不在门禁的进程组里、组 KILL 杀不到它；用 kqueue NOTE_EXIT（Linux pidfd）盯门禁主进程，不轮询。
#   主进程一退出：结果目录还在（被 KILL，没走到收尾删目录）就把各步记下的 timeout 进程号（$L/*.tp）与心跳（$L/hb.pid）的进程组 TERM，5 秒后还在的 KILL；
#   收完删掉结果目录（TMPDIR 下 tmp.* 才删）；正常退出时门禁收尾已删结果目录，什么都不做。只动命令行带本份字样的进程（步：本份结果目录；心跳：gate.sh），防进程号被复用误伤
import glob, os, select, signal, subprocess, sys, time
gp, L = int(sys.argv[1]), sys.argv[2]
if os.fork():
    sys.exit(0)
os.setsid()
nul = os.open(os.devnull, os.O_RDWR)
for i in (0, 1, 2):
    os.dup2(nul, i)
os.closerange(3, 65536)
try:
    if hasattr(select, "kqueue"):
        kq = select.kqueue()
        kq.control([select.kevent(gp, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT, select.KQ_NOTE_EXIT)], 0, 0)
        kq.control(None, 1, None)
    else:
        p = select.poll(); p.register(os.pidfd_open(gp), select.POLLIN); p.poll()
except OSError:   # 主进程已不在：照样收
    pass
if not os.path.isdir(L):
    sys.exit(0)
def nums(pat):
    out = []
    for f in glob.glob(os.path.join(L, pat)):
        try:
            out.append(int(open(f).read().split()[0]))
        except (OSError, ValueError, IndexError):
            pass
    return [x for x in out if x > 1]
def looks_ours(pid, mark):
    # 命令行必须带本份的字样（11-11 合入运维线：原先认 timeout / bash / sleep / nostall 任一，进程号被复用给别的单测的 bash 也认成自己的，
    #   本机进程号约 80 秒转一圈，陈旧记录必打中别人）：步的 timeout 命令行里有本份结果目录（bash -c "echo $$ > '<$L>/<步>.pg'; …"），心跳是门禁主进程的子 shell、命令行是 gate.sh
    c = subprocess.run(["ps", "-ww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
    return mark in c
def hit(sig):
    n = 0
    # 各步命令自立的进程组（步开跑时写的组号 = 组长进程号）：经 tools/safe_killpg.sh 发（进程组信号唯一入口，tests/killpg_lint_test.sh 守）；
    #   字样 = 这份 .pg 的路径——组长是 bash -c "echo $$ > '<.pg 路径>'; …"，命令行里必有它，进程号被复用给别的组时对不上、不杀
    sk = os.path.join(os.path.dirname(os.path.abspath(__file__)), "safe_killpg.sh"); name = signal.Signals(sig).name[3:]
    for f in glob.glob(os.path.join(L, "*.pg")) if os.path.exists(sk) else []:
        try:
            g = int(open(f).read().split()[0])
        except (OSError, ValueError, IndexError):
            continue
        if subprocess.run(["bash", "-c", 'source "$1"; safe_killpg "$2" "$3" "$4"', "_", sk, name, str(g), f],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            n += 1
    for pid, mark in [(x, L.rstrip("/") + "/") for x in nums("*.tp")] + [(x, "gate.sh") for x in nums("hb.pid")]:   # timeout 本身（转给它的组）与心跳
        if looks_ours(pid, mark):
            try:
                os.kill(pid, sig); n += 1
            except OSError:
                pass
    return n
if hit(signal.SIGTERM):
    time.sleep(5)
    hit(signal.SIGKILL)
# 收完再删结果目录（11-11 合入运维线：门禁被 KILL 时 EXIT trap 不跑，本机那份临时目录 tmp.* 留在 TMPDIR，积了 5800 多个）。
#   只删 mktemp 出来的那种（TMPDIR 下 tmp.<随机>）；远端那份（仓库 build/gate_out 下）不动
import re, shutil, tempfile
def tmp_roots():   # mktemp -d 落的目录：Linux 按 TMPDIR；macOS 不认 TMPDIR、用系统用户临时目录（getconf DARWIN_USER_TEMP_DIR）
    r = {os.path.realpath(tempfile.gettempdir())}
    try:
        d = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        if d: r.add(os.path.realpath(d))
    except OSError:
        pass
    return r
if re.fullmatch(r"tmp\.[A-Za-z0-9]+", os.path.basename(L.rstrip("/"))) and os.path.realpath(os.path.dirname(L.rstrip("/"))) in tmp_roots():
    shutil.rmtree(L, ignore_errors=True)
