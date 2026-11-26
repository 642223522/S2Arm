#!/usr/bin/env python3
"""Switch 2 SDK 接管（安卓 s2a_direct_lookup）宿主测试：真 direct_session.c + 真选择事务，假 nvn2 入口。

编译：direct_session.c 在宿主 cc 上要 <android/log.h> / <sys/system_properties.h>，用 host-fake/ 里的夹具头代替（只给本测，
不进 run.py 的 NDK 编译）。链接集合同 run.py 的 session-test。
负对照：把 direct_session.c 里调用 ns2_sdk_entry 的那一行换成不接管，同一份测试必须红（direct + switch2 一组失败）。
平台：链接集合里的 wsi_lease.c 用 pthread_condattr_setclock、direct/selection.c 用 getrandom，这两个只在 Linux / bionic 上有，Darwin 编不过。
所以「编译 + 6 组 + 负对照」只在 Linux 跑；非 Linux 宿主传 --wiring-only，只跑末尾的接线检查（纯源码次序，不编译），
android/test.sh 对应登记「未测」，不静默当绿。
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

wiring_only = "--wiring-only" in sys.argv[1:]
if [a for a in sys.argv[1:] if a != "--wiring-only"]:
    sys.exit("用法：run_ns2_lookup.py [--wiring-only]")
root = Path(__file__).resolve().parents[3]
test_dir = Path(__file__).resolve().parent
native = root / "android/native"
cc = os.environ.get("CC", "cc")
link = "-Wl,--gc-sections"   # 同 run.py：用不到的自定义驱动路径（引用窄 shim）随未引用函数一起剔掉
flags = [cc, "-std=c11", "-D_GNU_SOURCE", "-DS2A_ANDROID_GAME_RUNTIME=1", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread",
         "-ffunction-sections", "-fdata-sections", link,
         "-I" + str(test_dir / "host-fake"), "-I" + str(test_dir / "include"),
         "-I" + str(root / "graphics/nvn/third_party/vulkan-headers/include"),
         "-I" + str(native), "-I" + str(root / "runtime/include")]
selection = [native / "direct" / name for name in
             ("selection.c", "attempt.c", "graphics.c", "json.c", "sha256.c", "s2a_direct_abi.c")]
others = [native / "direct_vk.c", native / "direct_choice.c", native / "wsi_lease.c", *selection]
states = ("none", "generic", "direct")
switches = ("switch2", "switch1")


def build(session_source, binary):
    subprocess.run(flags + [str(session_source), *map(str, others), str(test_dir / "ns2_lookup_test.c"),
                            "-ldl", "-lm", "-o", str(binary)], check=True)


def run_all(binary):
    """每个进程只能发布一次选择，所以每组一个进程；返回失败的组合。"""
    bad = []
    for state in states:
        for sw in switches:
            p = subprocess.run([str(binary), state, sw], timeout=20, capture_output=True, text=True)
            sys.stdout.write(p.stdout)
            if p.returncode != 0:
                sys.stderr.write(p.stderr)
                bad.append((state, sw))
    return bad


def lookup_tests():
    with tempfile.TemporaryDirectory(prefix="s2a-ns2-lookup-") as tmp:
        tmp = Path(tmp)
        session = native / "direct_session.c"
        binary = tmp / "ns2-lookup"
        build(session, binary)
        bad = run_all(binary)
        if bad:
            sys.exit("ns2 lookup 红：" + ", ".join("%s/%s" % b for b in bad))
        # 负对照：不接管版本（marker 变了就要改这里，不许悄悄跳过）
        marker = "void *ns2 = name ? ns2_sdk_entry(name) : NULL;"
        text = session.read_text()
        if text.count(marker) != 1:
            raise RuntimeError("ns2 接管调用点 marker 变了：" + marker)
        mutated = tmp / "direct_session_no_ns2.c"
        mutated.write_text(text.replace(marker, "void *ns2 = NULL; (void)ns2_sdk_entry;   /* 负对照：不接管 */"))
        mbin = tmp / "ns2-lookup-mutant"
        build(mutated, mbin)
        p = subprocess.run([str(mbin), "direct", "switch2"], timeout=20, capture_output=True, text=True)
        if p.returncode == 0:
            sys.exit("负对照没红：不接管的 direct_session.c 也过了 direct/switch2，这条测试证明不了接线")
        lines = [x for x in p.stderr.strip().splitlines() if x.startswith("FAIL")]
        sys.stdout.write("负对照红（符合预期）：" + (lines[0] if lines else "退出码 %d" % p.returncode) + "\n")


if wiring_only:
    sys.stdout.write("本机跳过：ns2 lookup 6 组 + 负对照（链 wsi_lease.c / direct/selection.c，Darwin 没有 pthread_condattr_setclock / getrandom），"
                     "在 Linux / 离线容器里跑；只跑下面的接线检查\n")
else:
    lookup_tests()

# 接线检查：重定位时 s2a_direct_lookup 逐个导入问「是不是 Switch 2」（nvn2_on = s2a_platform_ounce），这个标志只有读过 NPDM 才有；
# 苹果侧装载经 s2a_mem_mod_base 读，安卓装载不经那条路，所以 runtime.c 要在两条装载调用之前自己读一次（s2a_npdm_ounce）。
# 主机不链接运行时，做源码次序检查；单元行为（回 1 / 0 / −1 并设标志）由 vm_test.c 的 npdm-ounce 用例管。
def probe_order_error(text):
    lines = text.splitlines()
    def first(needle):
        for i, line in enumerate(lines):
            if needle in line and not line.lstrip().startswith(("//", "int ", "void ")):   # 跳过注释与声明
                return i
        raise RuntimeError("runtime.c 里找不到 " + needle + "（接线检查的锚点变了，要同步改这里）")
    probe = first("s2a_npdm_ounce(npdm)")
    loads = (first("load_modules_from_source(r->module_source"), first("load_modules(r->module_dir"))
    if not all(probe < x for x in loads):
        return "s2a_npdm_ounce(npdm) 在第 %d 行，装载调用在第 %s 行：探针必须在两条装载调用之前" % (probe + 1, "/".join(str(x + 1) for x in loads))
    return None

runtime_c = (native / "runtime/runtime.c").read_text()
err = probe_order_error(runtime_c)
if err:
    sys.exit("ns2-probe-wired 红：" + err)
rows = runtime_c.splitlines(keepends=True)
probe_i = next(i for i, x in enumerate(rows) if "s2a_npdm_ounce(npdm)" in x and not x.lstrip().startswith(("//", "int ")))
tail_i = next(i for i, x in enumerate(rows) if "else load_modules(r->module_dir" in x)
moved = rows[:probe_i] + rows[probe_i + 1:tail_i + 1] + [rows[probe_i]] + rows[tail_i + 1:]   # 负对照：探针挪到装载之后
if probe_order_error("".join(moved)) is None:
    sys.exit("ns2-probe-wired 负对照没红：探针挪到装载之后也过了，这条检查证明不了次序")
print("PASS ns2-probe-wired：s2a_npdm_ounce 在装载调用之前，探针挪到装载之后则红")
if not wiring_only:
    print("PASS ns2 lookup 6 组全绿，负对照红")
