#!/usr/bin/env python3
"""安卓设备能力预检：不用真机，拿一份设备的 Vulkan 能力数据，判断 S2Arm 安卓直连在这台设备上
能不能起、哪些功能会缺、哪些路径会降级。

规则从源码里取（不是手抄一份会过期的清单）：
  - 硬门槛：android/native/direct/vk_device.c 建设备时的 required[] 特性表、Vulkan 版本下限、
    shaderDrawParameters、图形+计算队列；NVN 款与 Vulkan 款共用这一个建设备入口（nvn_vk_session.c）。
    再加 VK_EXT_swapchain_maintenance1：NVN 款 swapchain 准备阶段与 Vulkan 款 commit 前都会拒绝缺它的设备。
  - 功能缺口 / 性能降级：手工维护的表，每条都带源码锚点（文件 + 原文片段），
    tests/android_devcaps_test.py 校验锚点仍在，源码改了表就报红。

输入：Khronos Vulkan Profiles JSON（profiles-0.8.x 格式）。两种来源：
  - 真机能力：vulkaninfo --json 产出的 VP_VULKANINFO_* 文件，或 gpuinfo.org 报告页导出的 profile JSON。
  - 平台保证：Khronos/Google 发布的 VP_ANDROID_* 档（如 VP_ANDROID_15_minimums），表示“该安卓版本起所有
    设备都必须有”的能力；档里没写的项判“不保证”，不是“缺”。--kind 默认按档名自动判。
这份 JSON 同时可以喂给 Khronos 的 VK_LAYER_KHRONOS_profiles 模拟层，让桌面显卡按这台设备的能力上报。

只用标准库，Windows / macOS / Linux 都能跑：
  python tools/android_devcaps.py rules
  python tools/android_devcaps.py check 设备1.json 设备2.json [--kind auto|device|guarantee] [--json]
退出码：0 = 全部输入都过硬门槛（或保证档全覆盖）；1 = 有输入不过或数据不全；2 = 用法 / 读源码失败。
"""
import argparse
import json
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
VK_DEVICE_C = "android/native/direct/vk_device.c"
SHIPPED_DEFINES = {"S2A_ANDROID_VK_BACKEND_NVN_VK"}  # android/CMakeLists.txt 发行构建定义的宏

HARD, PARTIAL, DEGRADE = "硬门槛", "功能缺口", "性能降级"
TIER_ORDER = {HARD: 0, PARTIAL: 1, DEGRADE: 2}

BC_FORMATS = [
    "VK_FORMAT_BC1_RGBA_UNORM_BLOCK", "VK_FORMAT_BC1_RGBA_SRGB_BLOCK",
    "VK_FORMAT_BC2_UNORM_BLOCK", "VK_FORMAT_BC2_SRGB_BLOCK",
    "VK_FORMAT_BC3_UNORM_BLOCK", "VK_FORMAT_BC3_SRGB_BLOCK",
    "VK_FORMAT_BC4_UNORM_BLOCK", "VK_FORMAT_BC4_SNORM_BLOCK",
    "VK_FORMAT_BC5_UNORM_BLOCK", "VK_FORMAT_BC5_SNORM_BLOCK",
    "VK_FORMAT_BC6H_UFLOAT_BLOCK", "VK_FORMAT_BC6H_SFLOAT_BLOCK",
    "VK_FORMAT_BC7_UNORM_BLOCK", "VK_FORMAT_BC7_SRGB_BLOCK",
]

# 手工维护的规则：(id, 层级, 检查, 缺了会怎样, 锚点文件, 锚点原文)。
# 检查：("feature", 名) / ("ext", 名) / ("ext_feature", 扩展, 特性位) / ("ext_any", [名...]) / ("ext_all", [名...]) / ("bc",)
MANUAL_RULES = [
    ("ext:VK_KHR_swapchain", HARD, ("ext", "VK_KHR_swapchain"),
     "无法出画面", VK_DEVICE_C, '"VK_KHR_swapchain"'),
    ("ext:VK_EXT_swapchain_maintenance1", HARD,
     ("ext_feature", "VK_EXT_swapchain_maintenance1", "swapchainMaintenance1"),
     "直连拒绝起（缺呈现退休证明）：NVN 款 swapchain 准备失败，Vulkan 款退回通用路径",
     "android/native/nvn/nvn_vk_swapchain.c", "presentation retirement proof unavailable"),
    ("feature:vertexPipelineStoresAndAtomics", PARTIAL, ("feature", "vertexPipelineStoresAndAtomics"),
     "顶点阶段写存储的着色器程序被拒（该部分画面不画）",
     "android/native/nvn/nvn_vk_draw.c", "missing vertexPipelineStoresAndAtomics"),
    ("feature:dualSrcBlend", PARTIAL, ("feature", "dualSrcBlend"),
     "用双源混合因子的管线被拒", "android/native/nvn/backend_vulkan.c", "设备未启用 dualSrcBlend"),
    ("feature:imageCubeArray", PARTIAL, ("feature", "imageCubeArray"),
     "立方体数组纹理建不了", "android/native/nvn/backend_vulkan.c", "立方体数组需要 imageCubeArray"),
    ("feature:shaderStorageImageReadWithoutFormat", PARTIAL, ("feature", "shaderStorageImageReadWithoutFormat"),
     "无格式读存储图像的着色器被拒", "android/native/nvn/backend_vulkan.c",
     "!g.dev->core_features.shaderStorageImageReadWithoutFormat"),
    ("ext:VK_EXT_index_type_uint8", PARTIAL, ("ext", "VK_EXT_index_type_uint8"),
     "8 位索引改 CPU 展开（多一次拷贝）；间接绘制的 8 位索引没有回退，直接不画",
     "android/native/nvn/backend_vulkan.c", "u8 间接索引无 CPU 展开回退"),
    ("format:BC", DEGRADE, ("bc",),
     "缺的 BC 格式改用计算着色器解码（多占 GPU 时间与显存）", VK_DEVICE_C, "缺的格式走 compute 解码"),
    ("feature:geometryShader", DEGRADE, ("feature", "geometryShader"),
     "几何着色器改走转计算路径（另需 capprobe 实测 GS+遮挡查询可用才会启用）", VK_DEVICE_C, "走已验证的转计算"),
    ("ext:AHB+queue_family_foreign", DEGRADE,
     ("ext_all", ["VK_ANDROID_external_memory_android_hardware_buffer", "VK_EXT_queue_family_foreign"]),
     "零拷贝共享内存关闭，改走上传拷贝", VK_DEVICE_C, "整条零拷贝路径关掉"),
    ("ext:calibrated_timestamps", DEGRADE, ("ext_any", ["VK_KHR_calibrated_timestamps", "VK_EXT_calibrated_timestamps"]),
     "GPU 时间戳换算改用完成点兜底（计时精度降低）", VK_DEVICE_C, "都没有时时间戳走"),
]


class RulesError(Exception):
    pass


def _read(rel):
    path = os.path.join(ROOT, rel)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise RulesError(f"读不到 {rel}：{e}") from e


def _strip_ifndef(text, defines):
    """去掉 `#ifndef X ... #endif` 里 X 已定义的块（只处理 required[] 里出现的这种单层写法）。"""
    out, skip = [], False
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"#ifndef\s+(\w+)", s)
        if m:
            skip = m.group(1) in defines
            continue
        if s.startswith("#endif"):
            skip = False
            continue
        if not skip and not s.startswith("//"):
            out.append(line)
    return "\n".join(out)


def source_hard_rules(defines=SHIPPED_DEFINES):
    """从 vk_device.c 读出建设备的硬门槛。读不出来就报错，不回退到旧清单。"""
    src = _read(VK_DEVICE_C)
    m = re.search(r"const char \*required\[\]\s*=\s*\{(.*?)\};", src, re.S)
    if not m:
        raise RulesError(f"{VK_DEVICE_C} 里找不到 required[] 特性表，规则需要跟着源码更新")
    names = re.findall(r'"(\w+)"', _strip_ifndef(m.group(1), defines))
    if not names:
        raise RulesError(f"{VK_DEVICE_C} 的 required[] 解析出来是空的")
    rules = [("feature:" + n, HARD, ("feature", n), "建设备失败，游戏起不来", VK_DEVICE_C,
              f'"{n}"') for n in names]
    if "required feature missing: shaderDrawParameters" in src:
        rules.append(("feature:shaderDrawParameters", HARD, ("feature", "shaderDrawParameters"),
                      "建设备失败，游戏起不来", VK_DEVICE_C, "required feature missing: shaderDrawParameters"))
    v = re.search(r"if \(api < VK_API_VERSION_1_(\d)\)", src)
    if not v:
        raise RulesError(f"{VK_DEVICE_C} 里找不到 Vulkan 版本下限")
    rules.insert(0, (f"api:1.{v.group(1)}", HARD, ("api", (1, int(v.group(1)))),
                     "Vulkan 版本过低，建设备失败", VK_DEVICE_C, f"if (api < VK_API_VERSION_1_{v.group(1)})"))
    if "no graphics+compute queue family" in src:
        rules.insert(1, ("queue:graphics+compute", HARD, ("queue",), "没有图形+计算队列，建设备失败",
                         VK_DEVICE_C, "no graphics+compute queue family"))
    return rules


def all_rules():
    rules = source_hard_rules() + list(MANUAL_RULES)
    return sorted(rules, key=lambda r: TIER_ORDER[r[1]])


def check_anchors(rules):
    """返回锚点已不在源码里的规则 id 列表。"""
    cache, stale = {}, []
    for rid, _tier, _chk, _eff, rel, anchor in rules:
        if rel not in cache:
            cache[rel] = _read(rel)
        if anchor not in cache[rel]:
            stale.append(rid)
    return stale


# ---------------- 读 profile JSON ----------------

def _parse_version(v):
    if isinstance(v, int):
        return (v >> 22) & 0x7F, (v >> 12) & 0x3FF
    if isinstance(v, str):
        m = re.match(r"(\d+)\.(\d+)", v)
        if m:
            return int(m.group(1)), int(m.group(2))
    return None


class Caps:
    def __init__(self, name, kind):
        self.name, self.kind = name, kind
        self.features, self.extensions, self.formats = {}, set(), {}
        self.api = None
        self.queue_flags = None  # None = 数据里没有
        self.device_name = None
        self.have_features = self.have_formats = False

    def merge_capability(self, cap):
        for struct in (cap.get("features") or {}).values():
            if isinstance(struct, dict):
                self.have_features = True
                for k, val in struct.items():
                    if isinstance(val, bool):
                        self.features[k] = self.features.get(k, False) or val
        ext = cap.get("extensions") or {}
        self.extensions.update(ext.keys() if isinstance(ext, dict) else ext)
        props = (cap.get("properties") or {}).get("VkPhysicalDeviceProperties") or {}
        if "apiVersion" in props:
            self.api = _parse_version(props["apiVersion"]) or self.api
        if props.get("deviceName"):
            self.device_name = props["deviceName"]
        for fname, fp in (cap.get("formats") or {}).items():
            self.have_formats = True
            opt = ((fp or {}).get("VkFormatProperties") or {}).get("optimalTilingFeatures") or []
            self.formats.setdefault(fname, set()).update(opt)
        for q in cap.get("queueFamiliesProperties") or []:
            flags = ((q or {}).get("VkQueueFamilyProperties") or {}).get("queueFlags") or []
            self.queue_flags = (self.queue_flags or []) + [set(flags)]


def _profile_capability_names(entry):
    """profile 的 capabilities 列表：字符串 = 必有；嵌套列表 = 多选一（保守只取不了，跳过）。"""
    return [c for c in entry.get("capabilities", []) if isinstance(c, str)]


def load_caps(path, kind="auto", _seen=None):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    profiles = doc.get("profiles") or {}
    caps_defs = doc.get("capabilities") or {}
    if not profiles or not caps_defs:
        raise ValueError(f"{path} 不是 Vulkan Profiles JSON（缺 profiles / capabilities）")
    pname, entry = next(iter(profiles.items()))
    if kind == "auto":
        kind = "guarantee" if pname.startswith("VP_ANDROID_") or pname.startswith("VP_KHR_") else "device"
    c = Caps(pname, kind)
    seen = _seen if _seen is not None else set()
    seen.add(pname)
    # 保证档的继承：VP_ANDROID_16_minimums → 15 → baseline_2022，按同目录同名文件找。
    for parent in entry.get("profiles", []) or []:
        if parent in seen:
            continue
        ppath = os.path.join(os.path.dirname(path), parent + ".json")
        if os.path.exists(ppath):
            pc = load_caps(ppath, kind, seen)
            c.features.update({k: v or c.features.get(k, False) for k, v in pc.features.items()})
            c.extensions |= pc.extensions
            for k, v in pc.formats.items():
                c.formats.setdefault(k, set()).update(v)
            c.api = c.api or pc.api
            c.have_features |= pc.have_features
            c.have_formats |= pc.have_formats
        else:
            c.missing_parent = getattr(c, "missing_parent", []) + [parent]
    for cname in _profile_capability_names(entry):
        if cname in caps_defs:
            c.merge_capability(caps_defs[cname])
    api = _parse_version(entry.get("api-version"))
    if api and (c.api is None or api > c.api):
        c.api = api
    return c


# ---------------- 判定 ----------------

OK, MISSING, UNKNOWN, PARTLY = "有", "缺", "不知道", "部分"


def evaluate_rule(caps, chk):
    """返回 (状态, 说明)。保证档里没写的项是“不保证”，用 MISSING 表示、由调用方换词。"""
    t = chk[0]
    if t == "api":
        if caps.api is None:
            return UNKNOWN, "数据里没有 apiVersion"
        return (OK if caps.api >= chk[1] else MISSING), f"{caps.api[0]}.{caps.api[1]}"
    if t == "queue":
        if caps.queue_flags is None:
            # Vulkan 规范：有图形队列的实现，至少一个队列族同时支持图形和计算
            return OK, "数据里没有队列族，按 Vulkan 规范保证计"
        good = any({"VK_QUEUE_GRAPHICS_BIT", "VK_QUEUE_COMPUTE_BIT"} <= f for f in caps.queue_flags)
        return (OK if good else MISSING), ""
    if t == "feature":
        if chk[1] in caps.features:
            return (OK if caps.features[chk[1]] else MISSING), ""
        if caps.kind == "guarantee" or caps.have_features:
            # 设备数据：vulkaninfo / gpuinfo 列全了特性；扩展特性结构不在说明扩展不支持
            return MISSING, "数据里没有这一项"
        return UNKNOWN, "数据里没有特性表"
    if t == "ext":
        return (OK if chk[1] in caps.extensions else MISSING), ""
    if t == "ext_feature":
        if chk[1] not in caps.extensions:
            return MISSING, ""
        if chk[2] in caps.features:
            return (OK if caps.features[chk[2]] else MISSING), "" if caps.features[chk[2]] else "扩展在但特性位没开"
        return OK, f"按扩展计（数据里没有 {chk[2]} 特性位）"
    if t == "ext_any":
        hit = [e for e in chk[1] if e in caps.extensions]
        return (OK if hit else MISSING), ",".join(hit)
    if t == "ext_all":
        miss = [e for e in chk[1] if e not in caps.extensions]
        return (OK if not miss else MISSING), ("缺 " + ",".join(miss)) if miss else ""
    if t == "bc":
        if not caps.have_formats:
            return UNKNOWN, "数据里没有格式表"
        native = [f for f in BC_FORMATS if "VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT" in caps.formats.get(f, ())]
        if len(native) == len(BC_FORMATS):
            return OK, "14/14 原生"
        return (PARTLY if native else MISSING), f"{len(native)}/14 原生"
    raise ValueError(chk)


def evaluate(caps, rules):
    rows = []
    for rid, tier, chk, effect, _rel, _anchor in rules:
        status, note = evaluate_rule(caps, chk)
        rows.append({"id": rid, "tier": tier, "status": status, "note": note, "effect": effect})
    hard = [r for r in rows if r["tier"] == HARD]
    if any(r["status"] == MISSING for r in hard):
        verdict = "保证档不覆盖" if caps.kind == "guarantee" else "起不来"
    elif any(r["status"] == UNKNOWN for r in hard):
        verdict = "数据不全"
    elif any(r["status"] in (MISSING, PARTLY) for r in rows if r["tier"] == PARTIAL):
        verdict = "能起，有功能缺口"
    elif any(r["status"] in (MISSING, PARTLY) for r in rows if r["tier"] == DEGRADE):
        verdict = "能起，有降级"
    else:
        verdict = "全满足"
    return verdict, rows


def _status_word(caps, status):
    if caps.kind == "guarantee" and status == MISSING:
        return "不保证"
    return status


def render_markdown(results):
    out = []
    for caps, verdict, rows in results:
        title = caps.device_name or caps.name
        kind = "平台保证档" if caps.kind == "guarantee" else "设备实测"
        out.append(f"## {title}（{kind}）：{verdict}")
        if getattr(caps, "missing_parent", None):
            out.append("注意：继承的档 {} 不在同目录，没并进来。".format(", ".join(caps.missing_parent)))
        out.append("")
        out.append("| 层级 | 能力 | 状态 | 说明 | 缺了会怎样 |")
        out.append("|---|---|---|---|---|")
        for r in rows:
            out.append("| {} | {} | {} | {} | {} |".format(r["tier"], r["id"], _status_word(caps, r["status"]),
                                                    r["note"], r["effect"] if r["status"] != OK else ""))
        out.append("")
    if len(results) > 1:
        out.append("## 汇总")
        out.append("")
        out.append("| 输入 | 结论 | 硬门槛缺 | 功能缺口 | 降级 |")
        out.append("|---|---|---|---|---|")
        for caps, verdict, rows in results:
            def bad(tier, rows=rows):
                return ", ".join(r["id"].split(":", 1)[1] for r in rows
                                 if r["tier"] == tier and r["status"] in (MISSING, PARTLY, UNKNOWN)) or "—"
            out.append(f"| {caps.device_name or caps.name} | {verdict} | {bad(HARD)} | {bad(PARTIAL)} | {bad(DEGRADE)} |")
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="S2Arm 安卓设备能力预检（不用真机）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("rules", help="列出当前源码要求的能力")
    ck = sub.add_parser("check", help="拿 profile JSON 判定")
    ck.add_argument("files", nargs="+")
    ck.add_argument("--kind", choices=["auto", "device", "guarantee"], default="auto")
    ck.add_argument("--json", action="store_true", help="输出 JSON 而不是 Markdown")
    args = ap.parse_args(argv)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")  # Windows 控制台默认不是 UTF-8
    try:
        rules = all_rules()
    except RulesError as e:
        print(f"规则读取失败：{e}", file=sys.stderr)
        return 2
    if args.cmd == "rules":
        print("| 层级 | 能力 | 缺了会怎样 | 源码 |")
        print("|---|---|---|---|")
        for rid, tier, _chk, effect, rel, _a in rules:
            print(f"| {tier} | {rid} | {effect} | {rel} |")
        return 0
    results = []
    for path in args.files:
        try:
            caps = load_caps(path, args.kind)
        except (OSError, ValueError) as e:
            print(f"读不了 {path}：{e}", file=sys.stderr)
            return 2
        verdict, rows = evaluate(caps, rules)
        results.append((caps, verdict, rows))
    if args.json:
        print(json.dumps([{"input": c.name, "device": c.device_name, "kind": c.kind, "verdict": v, "rules": r}
                          for c, v, r in results], ensure_ascii=False, indent=1))
    else:
        sys.stdout.write(render_markdown(results))
    return 0 if all(v not in ("起不来", "数据不全", "保证档不覆盖") for _c, v, _r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
