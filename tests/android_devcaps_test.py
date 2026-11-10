#!/usr/bin/env python3
"""tools/android_devcaps.py 单测：合成 profile JSON，不需要真机、网络或显卡。"""
import json
import os
import subprocess
import sys
import tempfile

for _stream in (sys.stdout, sys.stderr):  # Windows 管道下默认按系统代码页编码，中文直接崩
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8")

H = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(H, "tools"))
import android_devcaps as dc  # noqa: E402

bad = 0


def ck(name, cond):
    global bad
    print(("通 " if cond else "不通 ") + name)
    if not cond:
        bad = 1


rules = dc.all_rules()
ids = {r[0] for r in rules}
hard = [r[0] for r in rules if r[1] == dc.HARD]

# ① 硬门槛从源码读出：发行构建定义 NVN_VK，vertexPipelineStoresAndAtomics 不在硬门槛；不定义时在
ck("① 硬门槛含 vk_device.c required[] 与 shaderDrawParameters、API 下限",
   {"feature:independentBlend", "feature:depthClamp", "feature:occlusionQueryPrecise",
    "feature:shaderDrawParameters", "api:1.1"} <= set(hard))
ck("① 发行构建（NVN_VK）vertexPipelineStoresAndAtomics 不算硬门槛",
   "feature:vertexPipelineStoresAndAtomics" not in hard)
legacy = [r[0] for r in dc.source_hard_rules(defines=set())]
ck("① 不定义 NVN_VK 时 vertexPipelineStoresAndAtomics 回到硬门槛",
   "feature:vertexPipelineStoresAndAtomics" in legacy)
ck("① 规则 id 不重复", len(ids) == len(rules))

# ② 每条规则的源码锚点都还在：源码改了这里报红，提醒同步规则表
stale = dc.check_anchors(rules)
ck("② 规则锚点都在源码里（失效：%s）" % (", ".join(stale) or "无"), not stale)


def profile(name, features, exts, api="1.3.0", formats=None, queues=True, dev_name="合成设备"):
    cap = {"features": {"VkPhysicalDeviceFeatures": features},
           "extensions": {e: 1 for e in exts},
           "properties": {"VkPhysicalDeviceProperties": {"apiVersion": api, "deviceName": dev_name}},
           "formats": formats or {}}
    if queues:
        cap["queueFamiliesProperties"] = [{"VkQueueFamilyProperties": {
            "queueFlags": ["VK_QUEUE_GRAPHICS_BIT", "VK_QUEUE_COMPUTE_BIT", "VK_QUEUE_TRANSFER_BIT"]}}]
    return {"$schema": "https://schema.khronos.org/vulkan/profiles-0.8.2-276.json#",
            "capabilities": {"device": cap},
            "profiles": {name: {"version": 1, "api-version": api, "label": name, "description": "",
                                "capabilities": ["device"]}}}


ALL_FEATURES = {r[2][1]: True for r in rules if r[2][0] == "feature"}
ALL_FEATURES["swapchainMaintenance1"] = True
ALL_EXTS = ["VK_KHR_swapchain", "VK_EXT_swapchain_maintenance1", "VK_EXT_index_type_uint8",
            "VK_ANDROID_external_memory_android_hardware_buffer", "VK_EXT_queue_family_foreign",
            "VK_KHR_calibrated_timestamps"]
SAMPLED = {"VkFormatProperties": {"optimalTilingFeatures": ["VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT"]}}
ALL_BC = {f: SAMPLED for f in dc.BC_FORMATS}

with tempfile.TemporaryDirectory() as t:
    def write(name, doc):
        p = os.path.join(t, name + ".json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump(doc, f)
        return p

    def verdict(path, kind="auto"):
        v, rows = dc.evaluate(dc.load_caps(path, kind), rules)
        return v, {r["id"]: r for r in rows}

    v, _ = verdict(write("VP_VULKANINFO_full", profile("VP_VULKANINFO_full", ALL_FEATURES, ALL_EXTS, formats=ALL_BC)))
    ck(f"③ 全满足的设备判「全满足」（{v}）", v == "全满足")

    f = dict(ALL_FEATURES, depthClamp=False)
    v, rows = verdict(write("VP_VULKANINFO_nodc", profile("VP_VULKANINFO_nodc", f, ALL_EXTS, formats=ALL_BC)))
    ck(f"③ 缺 depthClamp 判「起不来」（{v}）", v == "起不来" and rows["feature:depthClamp"]["status"] == dc.MISSING)

    exts = [e for e in ALL_EXTS if e != "VK_EXT_swapchain_maintenance1"]
    v, _ = verdict(write("VP_VULKANINFO_nosm1", profile("VP_VULKANINFO_nosm1", ALL_FEATURES, exts, formats=ALL_BC)))
    ck(f"③ 缺 VK_EXT_swapchain_maintenance1 判「起不来」（{v}）", v == "起不来")

    f = dict(ALL_FEATURES, swapchainMaintenance1=False)
    v, rows = verdict(write("VP_VULKANINFO_sm1off", profile("VP_VULKANINFO_sm1off", f, ALL_EXTS, formats=ALL_BC)))
    ck(f"③ 扩展在但 swapchainMaintenance1 特性位关也判「起不来」（{v}）", v == "起不来")

    f = dict(ALL_FEATURES, dualSrcBlend=False)
    v, _ = verdict(write("VP_VULKANINFO_nodsb", profile("VP_VULKANINFO_nodsb", f, ALL_EXTS, formats=ALL_BC)))
    ck(f"③ 只缺 dualSrcBlend 判「能起，有功能缺口」（{v}）", v == "能起，有功能缺口")

    half_bc = {k: SAMPLED for k in dc.BC_FORMATS[:6]}
    v, rows = verdict(write("VP_VULKANINFO_bc", profile("VP_VULKANINFO_bc", ALL_FEATURES, ALL_EXTS, formats=half_bc)))
    ck("③ 只缺部分 BC 判「能起，有降级」、注 6/14（{} / {}）".format(v, rows["format:BC"]["note"]),
       v == "能起，有降级" and rows["format:BC"]["note"] == "6/14 原生")

    v, _ = verdict(write("VP_VULKANINFO_v10", profile("VP_VULKANINFO_v10", ALL_FEATURES, ALL_EXTS, api="1.0.61", formats=ALL_BC)))
    ck(f"③ Vulkan 1.0 判「起不来」（{v}）", v == "起不来")

    v, _ = verdict(write("VP_VULKANINFO_noq", profile("VP_VULKANINFO_noq", ALL_FEATURES, ALL_EXTS, formats=ALL_BC, queues=False)))
    ck(f"③ 设备数据没有队列族按规范保证计（{v}）", v == "全满足")

    v, _ = verdict(write("VP_VULKANINFO_nofeat", {"capabilities": {"device": {"extensions": {e: 1 for e in ALL_EXTS},
        "properties": {"VkPhysicalDeviceProperties": {"apiVersion": "1.3.0"}}}},
        "profiles": {"VP_VULKANINFO_nofeat": {"capabilities": ["device"]}}}))
    ck(f"③ 设备数据没有特性表判「数据不全」（{v}）", v == "数据不全")

    # ④ 保证档：继承链按同目录文件并入；没写的项是「不保证」
    base = profile("VP_ANDROID_testbase", {"independentBlend": True}, ["VK_KHR_swapchain"], api="1.1.0")
    child = profile("VP_ANDROID_testchild", {"depthClamp": True}, [], api="1.3.0")
    child["profiles"]["VP_ANDROID_testchild"]["profiles"] = ["VP_ANDROID_testbase"]
    write("VP_ANDROID_testbase", base)
    c = dc.load_caps(write("VP_ANDROID_testchild", child))
    ck("④ VP_ANDROID_* 自动判保证档", c.kind == "guarantee")
    ck("④ 继承档并入：父档的 independentBlend / VK_KHR_swapchain 在子档里可见",
       c.features.get("independentBlend") and "VK_KHR_swapchain" in c.extensions and c.features.get("depthClamp"))
    v, rows = dc.evaluate(c, rules)
    ck(f"④ 保证档缺项判「保证档不覆盖」（{v}）", v == "保证档不覆盖")

    # ⑤ 命令行：退出码与输出
    rc = dc.main(["check", os.path.join(t, "VP_VULKANINFO_full.json")])
    ck("⑤ check 全满足退出 0", rc == 0)
    rc = dc.main(["check", os.path.join(t, "VP_VULKANINFO_nodc.json")])
    ck("⑤ check 起不来退出 1", rc == 1)
    ck("⑤ rules 子命令退出 0", dc.main(["rules"]) == 0)

    # ⑥ 带 BOM 的 JSON（PowerShell 5.1 Set-Content -Encoding UTF8 的写法）照常读
    bom = os.path.join(t, "VP_VULKANINFO_bom.json")
    with open(os.path.join(t, "VP_VULKANINFO_full.json"), encoding="utf-8") as src, \
            open(bom, "w", encoding="utf-8-sig") as dst:
        dst.write(src.read())
    ck("⑥ 带 BOM 的 profile JSON 照常判定", dc.main(["check", bom]) == 0)

# ⑦ 输出编码：模拟 Windows 管道下的非中文代码页（强制 ascii），帮助 / 规则表 / 报错都不许崩
tool = os.path.join(H, "tools", "android_devcaps.py")
env = dict(os.environ, PYTHONIOENCODING="ascii")
env.pop("PYTHONUTF8", None)
for args, want_rc, want_text in (
        (["--help"], 0, "安卓设备能力预检"),
        (["check", "-h"], 0, "输出 JSON 而不是 Markdown"),
        (["rules"], 0, "硬门槛"),
        (["check", os.path.join(H, "不存在.json")], 2, "读不了")):
    r = subprocess.run([sys.executable, "-X", "utf8=0", tool, *args], env=env, capture_output=True)
    out = (r.stdout + r.stderr).decode("utf-8", "replace")
    ck(f"⑦ 强制 ascii 输出下 {' '.join(args)} 退出 {r.returncode}（期望 {want_rc}）、中文原样输出",
       r.returncode == want_rc and want_text in out and "UnicodeEncodeError" not in out)

sys.exit(bad)
