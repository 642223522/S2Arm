"""pack/jobs 单测公共夹具：私有目录 + 游戏库 + 真 worker 协议（main.py --request）+ 合成读取器。各 tests/test_<功能>.py 继承 JobCase。"""
import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import os
os.environ.setdefault("S2A_BANNER_FETCH", "0")   # 作业层测试一律不连商店（library.store_meta）；要测的用例自己打桩
# 补丁 / 金手指下载站同理（11-14 门禁提速）：每次出包 patches.prepare 都现取云端清单（patches.cloud_manifest），原先单测里每个出包用例都真连网
#   （经本机代理，每次约 1 秒，test_job_failure_codes 一份就 40 多次；断网 / 代理卡住时按 patches.TIMEOUT 白等）。缺省指一个不存在的本地目录
#   = 「云端取不到、只用本地」，与门禁机断网时同一条路径；要测下载站的用例（test_patches）自己把 S2A_PATCH_BASE 指到造好的目录
os.environ.setdefault("S2A_PATCH_BASE", "file:" + os.path.join(tempfile.gettempdir(), "s2a-jobtests-no-patch-site"))
# 每局结束注销 S2ArmGame 系统登记（host_update.forget_registrations，#1126）：单测起局不碰门禁机 / 本机真的应用登记库，指向不存在的工具 = 不做
os.environ.setdefault("S2A_LSREGISTER", os.path.join(tempfile.gettempdir(), "s2a-jobtests-no-lsregister"))

JOBS = Path(__file__).resolve().parents[1]
ROOT = JOBS.parents[1]
sys.path.insert(0, str(JOBS))
from core import Context, atomic
import library
import toolchain


def _windows_private_request(path, value):
    """Create this synthetic request private from its first filesystem instant."""
    import ctypes as C
    from ctypes import wintypes as W
    import msvcrt
    import os
    import uuid
    api = C.WinDLL('advapi32', use_last_error=True)
    kernel = C.WinDLL('kernel32', use_last_error=True)
    def function(library, name, result, *types):
        f = getattr(library, name); f.restype = result; f.argtypes = list(types)
        return f
    def checked(value):
        if not value: raise C.WinError(C.get_last_error())
        return value
    close = function(kernel, 'CloseHandle', W.BOOL, W.HANDLE)
    free = function(kernel, 'LocalFree', C.c_void_p, C.c_void_p)
    token = W.HANDLE()
    current = function(kernel, 'GetCurrentProcess', W.HANDLE)()
    checked(function(api, 'OpenProcessToken', W.BOOL, W.HANDLE, W.DWORD, C.c_void_p)(current, 8, C.byref(token)))
    try:
        query = function(api, 'GetTokenInformation', W.BOOL, W.HANDLE, C.c_int, C.c_void_p, W.DWORD, C.c_void_p)
        size = W.DWORD(); query(token, 1, None, 0, C.byref(size))
        data = C.create_string_buffer(size.value); checked(query(token, 1, data, size, C.byref(size)))
        sid = C.c_void_p.from_buffer(data)
        text = C.c_void_p()
        checked(function(api, 'ConvertSidToStringSidW', W.BOOL, C.c_void_p, C.c_void_p)(sid, C.byref(text)))
        try: user = C.wstring_at(text)
        finally: free(text)
    finally: close(token)
    descriptor = C.c_void_p()
    sddl = 'O:' + user + 'D:P(A;;FA;;;' + user + ')(A;;FA;;;SY)(A;;FA;;;BA)'
    checked(function(api, 'ConvertStringSecurityDescriptorToSecurityDescriptorW', W.BOOL,
                     W.LPCWSTR, W.DWORD, C.c_void_p, C.c_void_p)(sddl, 1, C.byref(descriptor), None))
    class Attributes(C.Structure):
        _fields_ = [('length', W.DWORD), ('descriptor', C.c_void_p), ('inherit', W.BOOL)]
    attributes = Attributes(C.sizeof(Attributes), descriptor, False)
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex + '.private')
    handle = None
    try:
        handle = function(kernel, 'CreateFileW', W.HANDLE, W.LPCWSTR, W.DWORD, W.DWORD,
                          C.c_void_p, W.DWORD, W.DWORD, W.HANDLE)(
            str(temporary), 0x40000000, 0, C.byref(attributes), 1, 0x80, None)
        if handle == C.c_void_p(-1).value:
            handle = None
            raise C.WinError(C.get_last_error())
        fd = msvcrt.open_osfhandle(handle, os.O_WRONLY | os.O_BINARY)
        handle = None  # CRT owns it
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(value, output, ensure_ascii=False, indent=2)
        os.replace(temporary, path)
    finally:
        if handle is not None: close(handle)
        free(descriptor)
        temporary.unlink(missing_ok=True)



class OsView:
    """只给被测模块看的 os：name 缺省 "nt"，其余转给真 os（构造时可再覆盖几个属性，如 replace）。
    不能改全进程的 os.name：Python 3.12 起 Path() 构造时看 os.name，mock 期间新建的路径变成 WindowsPath，
    「/var/folders/…/job.json」被当成反斜杠相对名写进当前目录（各线工作树根反复冒出「\\var\\folders…」杂文件、两次被 git add -A 带进提交）"""
    def __init__(self, name="nt", **override):
        self.name = name
        self.__dict__.update(override)

    def __getattr__(self, key):
        return getattr(os, key)


def as_windows(*modules, **override):
    """被测模块按 Windows 分支走：只替换这些模块的 os 属性"""
    from contextlib import ExitStack
    stack = ExitStack()
    for m in modules:
        stack.enter_context(unittest.mock.patch.object(m, "os", OsView(**override)))
    return stack

def fake_context(root, **override):
    """作业上下文替身的唯一工厂（替代各用例手写 types.SimpleNamespace）：字段与 core.Context 对齐（test_fake_context_covers_context 核：
    产品代码里用到的 c.<名> 凡是 Context 有的，这里都得有），各用例只覆盖自己关心的。
    11-16：手写的替身缺 env，put_game 新加的收回 NRO 走到 c.env()，discover 顺序全量跑时 test_win_jobs 3 红（单跑因为 push_pack 导入不到碰巧绕过）。
    普通字段给合理缺省；lock / idle 用真文件锁；emit / begin / diagnostic 记下来（events / stages / diagnostics）；
    有副作用的（run / catalog / game / finish / stop）缺省响亮报错——用到了就在用例里显式给，别让替身悄悄冒充"""
    import contextlib, threading, types
    import filelock
    root = Path(root)
    c = types.SimpleNamespace()
    c.events, c.stages, c.diagnostics = [], [], []
    def loud(name):
        def f(*a, **k):
            raise AssertionError(f"测试替身的 c.{name} 没配：这条路径会用到它，请在用例里 fake_context(..., {name}=...) 显式给")
        return f
    @contextlib.contextmanager
    def lock(name="catalog", wait=None, root=None):
        lib = Path(root or c.library); lib.mkdir(parents=True, exist_ok=True)
        with filelock.held(lib / f".{name}.lock", wait_s=60 if wait is None else wait):
            yield
    @contextlib.contextmanager
    def idle(name="execution"):
        yield True
    def diagnostic(message, code="job_failed", severity="error", **kw):
        d = dict(message=message, code=code, severity=severity, **kw); c.diagnostics.append(d); return d
    c.__dict__.update(
        r={}, operation="test", task="t", number=1, count=1,
        library=root / "library", private=root / "private", logs=root / "logs", engine=root / "engine", work_root=root / "work",
        keys=root / "private/keys/prod.keys", cancelled=False, guard=threading.RLock(), last_log=None, last_rc=None,
        job=dict(schema=1, id="t", diagnostics=[]), jobpath=root / "logs/jobs/t.json",
        check=lambda: None, require_source=lambda: None, require_library=lambda: None,
        lock=lock, idle=idle, lock_holder=lambda: dict(taskId="t"),
        emit=lambda kind="progress", message="", *a, **k: c.events.append((kind, message)),
        begin=lambda stage, number=1, count=1, key=None, keychain=False: c.stages.append(stage),
        progress=lambda done, total: None, redact=lambda value, **k: value,
        diagnostic=diagnostic, describe_failure=lambda error, *a, **k: dict(message=str(error)), report_failure=lambda error: None,
        fonts_dir=lambda: None, env=lambda: dict(os.environ),
        run=loud("run"), catalog=loud("catalog"), game=loud("game"), finish=loud("finish"), stop=loud("stop"),
    )
    c.__dict__.update(override)
    return c


class JobCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm-g01 ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stdout(self.output)
        # Keep all direct Context events out of test output (including fixtures).
        self.redirect.__enter__()
        self.addCleanup(self.redirect.__exit__, None, None, None)
        # 诊断导出收本机崩溃报告（library.MAC_CRASH_DIR）：测试里一律指到空的临时目录，不读跑测试这台机器上真实的 ~/Library/Logs/DiagnosticReports
        crash_dir = unittest.mock.patch.object(library, "MAC_CRASH_DIR", self.root / "no-crash-reports"); crash_dir.start(); self.addCleanup(crash_dir.stop)
        self.request = dict(schema=1, taskId="setup", operation="setup", engineDir=str(ROOT),
                            privateRoot=str(self.root / "private"), library=str(self.root / "library"))
        self.c = Context(self.request)
        self.request.update(library.setup(self.c))
        self.c.r.update(self.request)
        self.sequence = 0

    def worker(self, operation, *, entrypoint=None, **extra):
        self.sequence += 1
        path = self.root / "request.json"
        if sys.platform == 'win32':
            _windows_private_request(path, self.request | dict(taskId=f"g01-{self.sequence}", operation=operation) | extra)
            result = subprocess.run([sys.executable, "-I", "-X", "utf8", "-B", str(entrypoint or JOBS / "main.py"), "--request", str(path)],
                                    capture_output=True, text=True, encoding='utf-8', timeout=15)
        else:
            atomic(path, self.request | dict(taskId=f"g01-{self.sequence}", operation=operation) | extra)
            result = subprocess.run([sys.executable, "-I", "-B", str(entrypoint or JOBS / "main.py"), "--request", str(path)],
                                    capture_output=True, text=True, timeout=15)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertTrue(events, result.stderr)
        self.assertEqual([e["seq"] for e in events], list(range(1, len(events) + 1)))
        return result, events[-1]

    def assert_failure(self, terminal, code):
        self.assertEqual(terminal["state"], "failed")
        diagnostic = terminal["diagnostics"][-1]
        self.assertEqual(diagnostic["code"], code)
        self.assertTrue(diagnostic["suggestion"])
        self.assertEqual(terminal["message"], diagnostic["summary"])
        self.assertTrue(Path(diagnostic["logPath"]).is_file())
        saved = json.loads((self.c.private / "logs" / "jobs" / (terminal["taskId"] + ".json")).read_text())   # 任务记录固定在 <私有目录>/logs/jobs（剃刀 H6）
        self.assertEqual(saved["diagnostics"], terminal["diagnostics"])
        return diagnostic

    def import_keys(self):
        source = self.root / "synthetic.keys"
        source.write_text("header_key = " + "0" * 64 + "\n")
        result, event = self.worker("keys", path=str(source))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(event["state"], "succeeded")

    def install_reader_fixture(self):
        # The worker launches this through its normal tool PATH. It reads only
        # test bytes and emits the production reader's documented JSON shape.
        binary = self.c.private / "Runtime/bin/dotnet"
        binary.parent.mkdir(parents=True)
        binary.write_text(f"#!{sys.executable}\n" + '''import json, pathlib, sys
source = pathlib.Path(sys.argv[4])
if source.read_bytes() == b"temp dir fixture":   # #612：记下读取器拿到的 --temp-dir 及当时它在不在，照常出一份包信息
    tds = [x[11:] for x in sys.argv if x.startswith("--temp-dir=")]
    (source.parent / "temp_dir_seen.txt").write_text((tds[0] + "\t" + str(pathlib.Path(tds[0]).is_dir())) if tds else "")
    print(json.dumps({"schema":1,"packages":[{"titleId":"0100000000000000","baseId":"0100000000000000","type":"base","version":0,"name":"Synthetic","display":"1.0","guestIsa":"aarch64","builds":{}}]}))
    raise SystemExit(0)
if source.read_bytes() == b"truncated fixture":
    print("Beginning of synthetic reader diagnostic")
    print("long synthetic diagnostic " * 300)
    print("Authorization: Bearer synthetic-bearer")
    print("【内容截断】")
if source.read_bytes() == b"huge truncated fixture":
    print("HEAD-MARK")
    for _ in range(3000):
        print("x" * 100)
    print("TAIL-MARK")
    print("【内容截断】")
if source.read_bytes() == b"multi truncated fixture":
    # 合并包：本体和 DLC 的清单都读得出，末尾一个内容超出文件末尾。
    print("【内容截断】")
    print(json.dumps({"schema":1,"packages":[
        {"titleId":"0100000000000000","baseId":"0100000000000000","type":"base","version":0,"name":"Synthetic","display":"1.0","guestIsa":"aarch64","builds":{}},
        {"titleId":"0100000000000001","baseId":"0100000000000000","type":"dlc","version":0,"name":"","display":"","guestIsa":"unknown","builds":{}}]}))
    raise SystemExit(0)
if source.read_bytes() in (b"outdated fixture", b"ticket fixture"):
    code = "keys_missing" if source.read_bytes() == b"outdated fixture" else "ticket_missing"
    print("Container metadata could not be decrypted or verified. Check keys, tickets and file integrity.")
    print(f"【原因 {code}】")
    raise SystemExit(3)
if source.read_bytes() == b"damaged fixture":   # #1511 再判：解不开，但同代密钥的控制数据能解开 → 读取器归 content_damaged
    print("Container metadata could not be decrypted or verified. Check keys, tickets and file integrity.")
    print("【原因 content_damaged】解出来的数据对不上（分区头不是 PFS0 / HFS0）：同一份文件里控制数据（内容 0000abcd）用同一代密钥能正常解开")
    raise SystemExit(3)
if source.read_bytes().startswith(b"magic fixture"):   # #1511：分区头魔数不对（解出来是乱码 = 密钥不对），读取器归 keys_wrong；「magic fixture <行>」再带一行【密钥代】
    print("Container metadata could not be decrypted or verified. Check keys, tickets and file integrity.")
    print("【原因 keys_wrong】解出来的数据对不上（分区头不是 PFS0 / HFS0）")
    extra = source.read_bytes()[len(b"magic fixture "):].decode()
    if extra:
        print("【密钥代】" + extra.replace("|", "\t"))
    raise SystemExit(3)
if source.read_bytes() == b"unreadable fixture":
    print("Container metadata could not be decrypted or verified. Check keys, tickets and file integrity.")
    print("Authorization: Bearer synthetic-bearer")
    raise SystemExit(3)
if source.read_bytes() == b"disk full fixture":
    print("Container metadata could not be decrypted or verified. Check keys, tickets and file integrity.")
    print("【原因 disk_full】")
    raise SystemExit(3)
if source.read_bytes() == b"unknown exit fixture":
    print("Unrecognized fixture error")
    raise SystemExit(17)
if source.read_bytes().startswith(b"content id fixture"):   # 新读取器：带各 NCA 的 content ID（导入按它定原件身份，不读全文件）
    print(json.dumps({"schema":1,"packages":[{"titleId":"0100000000000000","baseId":"0100000000000000","type":"base","version":0,"name":"Synthetic","display":"1.0","guestIsa":"aarch64","builds":{},
        "contentIds":["000000000000000000000000000000bb","000000000000000000000000000000aa"]}]}))
    raise SystemExit(0)
if source.read_bytes() == b"chinese title fixture":   # 标题简体中文优先、另给英文名（文件夹取名用），封面写进 argv[5]
    pathlib.Path(sys.argv[5]).mkdir(parents=True, exist_ok=True)
    (pathlib.Path(sys.argv[5]) / "0100000000000000.jpg").write_bytes(b"ICON")
    print(json.dumps({"schema":1,"packages":[{"titleId":"0100000000000000","baseId":"0100000000000000","type":"base","version":0,"name":"空洞骑士：丝之歌",
        "englishName":"Hollow Knight: Silksong","display":"1.0","guestIsa":"aarch64","builds":{}}]}))
    raise SystemExit(0)
if source.read_bytes() == b"update only fixture":   # #797：只有更新包（本体另给）
    print(json.dumps({"schema":1,"packages":[{"titleId":"0100000000000800","baseId":"0100000000000000","type":"update","version":65536,"name":"Synthetic","display":"1.1","guestIsa":"aarch64","builds":{}}]}))
    raise SystemExit(0)
if source.read_bytes() == b"disappear fixture":
    source.unlink()
print(json.dumps({"schema":1,"packages":[{"titleId":"0100000000000000","baseId":"0100000000000000","type":"base","version":0,"name":"Synthetic","display":"1.0","guestIsa":"aarch64","builds":{}}]}))
''')
        binary.chmod(0o700)
        # Reader lookup is content-keyed in the actual worker too. Mac 起读取器直接执行缓存位上的
        # 自包含单文件（不再经 dotnet 跑 dll）：合成读取器脚本就装在缓存位，argv 与 Windows 直跑同形
        # （少了 dotnet 前缀，源 / 图标目录各前移一位）。
        from core import digest
        key = toolchain.reader_key(self.c)
        actual = self.c.private / "tools" / key
        actual.mkdir(parents=True)
        reader = actual / "nx_unpack"
        reader.write_text(
            binary.read_text()
            .replace("sys.argv[4]", "sys.argv[3]")
            .replace("sys.argv[5]", "sys.argv[4]"),
            encoding="utf-8",
        )
        reader.chmod(0o700)
        atomic(actual / "ready.json", dict(schema=1, sha256=digest(reader)))
        if sys.platform == 'win32':
            # A local copy of the installed interpreter runs the *same*
            # synthetic reader script. This is not a real .NET reader.
            import ctypes as C
            from ctypes import wintypes as W
            import shutil
            exe = binary.with_suffix('.exe')
            shutil.copyfile(sys._base_executable, exe)
            kernel = C.WinDLL('kernel32', use_last_error=True)
            module_name = kernel.GetModuleFileNameW
            module_name.restype = W.DWORD; module_name.argtypes = [W.HANDLE, W.LPWSTR, W.DWORD]
            name = C.create_unicode_buffer(32768)
            if not module_name(sys.dllhandle, name, len(name)):
                raise C.WinError(C.get_last_error())
            dll = Path(name.value)
            shutil.copyfile(dll, exe.parent / dll.name)
            (exe.parent / (dll.stem + '._pth')).write_text(
                str(Path(sys.base_prefix) / 'Lib') + '\n' + str(Path(sys.base_prefix) / 'DLLs') + '\n', encoding='utf-8')
            script = binary.read_text().split('\n', 1)[1].replace('sys.argv[4]', 'sys.argv[3]')
            (actual / 'nx_unpack.dll').write_text(script, encoding='utf-8')
            atomic(actual / 'ready.json', dict(schema=1, sha256=digest(actual / 'nx_unpack.dll')))


def synthetic_nup(path, app, packages):
    """按 NUP v1 规格（a55uka/nup SPEC.md，同 tests/ns2_nup_test.py 的拼法，只用原样存）拼一个合成容器，期望值就是写进去的字节。
    packages = [(类型 0 本体 / 1 更新 / 2 DLC, 标题号, 版本, exefs{名: 字节} 或 None, romfs{名: 字节} 或 None, 元数据{TLV 类型: 字节})]"""
    import hashlib, struct
    SUPER, TOC = struct.Struct('<4sHHQQ32sQQII16s32s'), struct.Struct('<4sIQQQQQ')
    PKG, DIR, FILE, TLV = struct.Struct('<QIIIIBBHIQI20x'), struct.Struct('<IIIIQ'), struct.Struct('<IIQQQ32sBBH12x'), struct.Struct('<HHI')
    NO_DIR = 0xFFFFFFFF
    dirs, files, recs = [], [], []   # dirs: [名字, [(是目录, 下标)]]；files: [名字, 字节]

    def mkdir(name, mapping=None):
        dirs.append([name, []])
        d = len(dirs) - 1
        for fn, data in sorted((mapping or {}).items()):
            files.append([fn.encode(), data])
            dirs[d][1].append((False, len(files) - 1))
        return d
    for kind, tid, ver, exefs, romfs, meta in packages:
        root = mkdir(b'')
        e = r = NO_DIR
        if exefs is not None:
            e = mkdir(b'exefs', exefs); dirs[root][1].append((True, e))
        if romfs is not None:
            r = mkdir(b'romfs', romfs); dirs[root][1].append((True, r))
        recs.append((tid, root, e, r, ver, kind, b''.join(TLV.pack(t, 0, len(v)) + v for t, v in sorted(meta.items()))))
    pool, slots, drecs = bytearray(), [], []
    def pname(b):
        pool.extend(b); return len(pool) - len(b), len(b)
    for name, kids in dirs:
        o, n = pname(name)
        drecs.append((o, n, len(slots), len(kids)))
        slots += [i if isdir else len(dirs) + i for isdir, i in kids]
    fnames = [pname(f[0]) for f in files]
    pool_off = TOC.size + len(recs) * PKG.size + len(dirs) * DIR.size + len(files) * FILE.size + 4 * len(slots)
    toc_size = pool_off + len(pool)
    meta_off = 0x80 + toc_size
    blob = (meta_off + sum(len(x[6]) for x in recs) + 15) & ~15
    data, frecs = bytearray(), []
    for (o, n), (_, raw) in zip(fnames, files):
        if raw:
            data += b'\0' * ((-(blob + len(data))) % 16)
            frecs.append((o, n, len(raw), blob + len(data), len(raw), hashlib.sha256(raw).digest()))
            data += raw
        else:
            frecs.append((o, n, 0, 0, 0, hashlib.sha256(b'').digest()))
    toc = bytearray(TOC.pack(b'TOC\x01', len(recs), len(dirs), len(files), pool_off, len(pool), 0))
    mo = meta_off
    for tid, root, e, r, ver, kind, m in recs:
        toc += PKG.pack(tid, root, e, r, ver, kind, 0, 0, 0, mo if m else 0, len(m)); mo += len(m)
    for d in drecs:
        toc += DIR.pack(*d, 0)
    for f in frecs:
        toc += FILE.pack(*f, 0, 0, 0)
    toc += struct.pack(f'<{len(slots)}I', *slots) + pool
    body = bytearray(SUPER.pack(b'NUP\x01', 0x80, 0, 0x80, toc_size, hashlib.sha256(toc).digest(), blob, blob + len(data), len(recs), 0, b'\0' * 16, b'\0' * 32))
    body += toc + b''.join(x[6] for x in recs)
    body += b'\0' * (blob - len(body)) + data
    Path(path).write_bytes(bytes(body))


def synthetic_npdm(app):   # 最小 META：0x70 处 ACI0 偏移 / 大小，ACI0+0x10 程序号（同 tests/ns2_nup_test.py）
    import struct
    b = bytearray(0x100)
    b[:4] = b'META'
    struct.pack_into('<II', b, 0x70, 0x80, 0x40)
    b[0x80:0x84] = b'ACI0'
    struct.pack_into('<Q', b, 0x90, app)
    return bytes(b)


def synthetic_nacp(title, display):   # 0x4000 字节：ApplicationTitle[0] 名字 0x200、0x3060 显示版本
    b = bytearray(0x4000)
    b[:len(title.encode())] = title.encode()
    b[0x3060:0x3060 + len(display)] = display.encode()
    return bytes(b)


def ios_fixture(c, gid, *, shell="SID1", pack="cafe01", compat=None, fixups=True):
    """游戏库结构 v3 里一款出好的 iPhone 版：程序缓存 cache/programs/<程序号>/kit（容器件：main.npdm + 改写产物表；常驻配方见 pack/jobs/programs.py）+ 这款文件夹 image/ios/.pack（资源包，清单带 index_sha256），
    game.json 的 ios 记出它的壳号、资源包号（compat 给了再记 hostAbi / dmshChain）→ (kit, pack)"""
    import layout
    image = layout.image_ios(c, gid)
    import programs
    kit, pk = programs.cache(c, gid) / "kit", image / ".pack"
    kit.mkdir(parents=True, exist_ok=True)
    (kit / "main.npdm").write_bytes(b"META")
    if fixups:
        (kit / "main.fixups.tsv").write_text("")
    (pk / "romfs").mkdir(parents=True, exist_ok=True)
    (pk / "romfs/a").write_bytes(b"12345"); (pk / "index.tsv").write_text("romfs/a\t5\th\n")
    (pk / "manifest.json").write_text(json.dumps({"version": 2, "index_sha256": pack}))
    layout.update_info(c, gid, ios=dict(shellId=shell, pack=pack, **(compat or {})))
    return kit, pk
