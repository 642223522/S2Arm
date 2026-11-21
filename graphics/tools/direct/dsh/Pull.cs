// 拉取式顶点输入变体（<键>_bp）：照上游参考实现（MIT）dmsh_pull（dmsh_pull.py variant 与 dmsh_pull.metal），宽线入口（_wl）不做。
// 顶点着色器去掉 [[stage_in]]，入口开头按每笔绘制的布局块（Prelude 里的 dm_vlayout，绑在顶点缓冲槽 16）自己从游戏的顶点流读输入：dm_fetch 在运行时按 NVN 属性格式解码成
//   Maxwell 顶点抓取给着色器的 32 位寄存器字，与 Metal 顶点描述抓取逐位相同（tests/t_vs_pull.py 在 GPU 上逐格式核），输入用 as_type 接走，本体不改。
//   用它建的管线没有顶点描述，同一对着色器配游戏绑的任何顶点布局都能用：宿主在按本笔布局建的管线编好之前先用它画，不在绘制上等 Metal 编译器。
// 只留 main0 / main0_z（深度模式）；变换反馈、几何抓取、层入口等不进拉取版，它们的管线照旧带顶点描述。出包另编成 <键>_bp 库，与 <键>_b 同编译参数（-fpreserve-invariance：
//   位置是 [[invariant]]，同一笔的两种管线算出同一个位置）。设备现编不出这个变体（同 _bv / _bf，见 DshCApi.cs 文件头）。
// 宿主契约（nvn_mtl.m 读 _b.json 的 pull）：{"entry": "main0", "entry_z": "main0_z"（有才写）, "slot": 16, "inputs": [各输入的 NVN 属性号]}；布局块内存布局见 Prelude 头注释：
//   struct dm_vstream { device const uchar *base; uint stride; uint divisor; }（16 字节）× 16 + uint attr[32]（= NVN 属性状态字：格式 8 位 | 偏移 19 位 << 8 | 流号 5 位 << 27），共 384 字节
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using static S2A.Dsh.Py;

namespace S2A.Dsh
{
    public static class DshPull
    {
        public const int SLOT = 16;   // 布局块的缓冲槽：顶点缓冲的第一个槽（nvn_mtl.m VB_SLOT），没有顶点描述的管线用不到它

        /// <summary>dm_vlayout 与 dm_fetch（照上游 dmsh_pull.metal 原样，只改了注释里的文件名）：插在 using namespace metal; 之后</summary>
        public const string Prelude = """
// Vertex pulling for the <key>_bp variant of a vertex shader (S2A.Dsh DshPull, graphics/tools/direct/dsh/Pull.cs): the attribute words Maxwell's vertex fetch gives the shader, read from a per-draw layout block.
// The host fills dm_vlayout for each draw (nvn_mtl.m): per stream the base address (kept 4-byte aligned: a base's low bits go into its attributes' offsets), stride (0: every vertex
// reads element 0) and divisor (0: per vertex; else the element is base instance + (instance - base instance) / divisor, Metal's own rule for a step rate with a base instance;
// the base instance is the draw's [[base_instance]], so indirect draws, whose arguments the CPU never reads, are right too), and per NVN attribute (all 32 of NVN2's, so an input at attribute 16 or above is pulled too) the raw NVN attribute state word
// (format 8 bits, offset 19, stream 5; format 0 or one this table does not know reads zeros, as the host's zero buffer).
// The result is four 32-bit register words: float formats as float bits (unorm and snorm through the unpack builtins, which round as Metal's vertex fetch does; a plain division
// under fast math is a unit in the last place off for some values), integer formats zero- or sign-extended, the int-to-float formats converted, missing components 0, 0, 0 and
// 1 (1.0 for the float formats). The input then takes them with as_type, whatever type the translator gave it. Bit-identical to Metal's fetch for every format it has (tests/t_vs_pull.py).
// Table byte per NVN vertex format: (components - 1) | size code << 2 (0: 8, 1: 16, 2: 32 bits) | kind << 4; kinds 1 unorm, 2 snorm, 3 uint, 4 sint, 5 float, 6 / 7 unsigned /
// signed integer read as float, 8 unorm 10:10:10:2, 9 snorm 10:10:10:2, 10 R11G11B10F, 11 BGRA8 unorm. The codes are those nvn_mtl.m vfmt knows (tests/t_vs_pull.py checks every one)
struct dm_vstream { device const uchar *base; uint stride; uint divisor; };
struct dm_vlayout { dm_vstream s[16]; uint attr[32]; };
constant uchar dm_ftab[256] = {
      0,  16,  32,  48,  64,  84,  20,  36,  52,  68,  88,  56,  72,  17,  33,  49,
     65,  85,  21,  37,  53,  69,  89,  57,  73,  18,  34,  50,  66,  86,  22,  38,
     54,  70,  90,  58,  74,  19,  35,  51,  67,  87,  23,  39,  55,  71,  91,  59,
     75,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, 139,   0, 170,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,  96, 112, 100, 116, 104, 120,  97, 113, 101, 117, 105, 121,  98, 114, 102,
    118, 106, 122,  99, 115, 103, 119, 107, 123, 155,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0, 179,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0
};
// R11G11B10F component: 5-bit exponent, mb-bit mantissa, no sign; a NaN comes out as the canonical one, as from Metal's fetch
static inline uint dm_uf(uint m, uint mb) {
    uint e = m >> mb, mm = m & ((1u << mb) - 1u);
    return e == 31u ? (mm ? 0x7fc00000u : 0x7f800000u) : e == 0u ? as_type<uint>(float(mm) * exp2(-14.0f - float(mb))) : (((e + 112u) << 23) | (mm << (23u - mb)));
}
// p: the element; al: its address is a multiple of 4 (a whole-word read then stays inside the vertex's stride)
static inline uint4 dm_decode(device const uchar *p, uint fmt, bool al) {
    uint t = dm_ftab[fmt], kind = t >> 4, n = (t & 3u) + 1u, sz = (t >> 2) & 3u;
    if (kind == 0u) return uint4(0u);
    uint4 w = uint4(0u);   // 32-bit components, or the packed bytes / halves: w.x = components 0-3 (8-bit) or 0-1 (16-bit), w.y = 2-3 (16-bit)
    if (kind >= 8u && kind <= 10u) w.x = *(device const uint *)p;
    else if (sz == 2u) {
        if (n == 4u) w = uint4(*(device const packed_uint4 *)p);
        else if (n == 3u) w.xyz = uint3(*(device const packed_uint3 *)p);
        else if (n == 2u) w.xy = uint2(*(device const packed_uint2 *)p);
        else w.x = *(device const uint *)p;
    } else if (al) {
        if (sz == 1u && n > 2u) w.xy = uint2(*(device const packed_uint2 *)p); else w.x = *(device const uint *)p;
    } else if (sz == 1u) {
        device const ushort *q = (device const ushort *)p;
        w.x = uint(q[0]) | (n > 1u ? uint(q[1]) << 16 : 0u); if (n > 2u) w.y = uint(q[2]) | (n > 3u ? uint(q[3]) << 16 : 0u);
    } else {
        w.x = uint(p[0]) | (n > 1u ? uint(p[1]) << 8 : 0u) | (n > 2u ? uint(p[2]) << 16 : 0u) | (n > 3u ? uint(p[3]) << 24 : 0u);
    }
    if (kind >= 8u && kind <= 10u) {
        uint v = w.x;
        if (kind == 8u) return as_type<uint4>(unpack_unorm10a2_to_float(v));
        if (kind == 9u) {
            int4 s = int4(int(v << 22) >> 22, int(v << 12) >> 22, int(v << 2) >> 22, int(v) >> 30);
            return as_type<uint4>(max(float4(s) / float4(511.0f, 511.0f, 511.0f, 1.0f), -1.0f));
        }
        return uint4(dm_uf(v & 2047u, 6u), dm_uf((v >> 11) & 2047u, 6u), dm_uf(v >> 22, 5u), 0x3f800000u);
    }
    uint4 c = sz == 2u ? w : sz == 1u ? uint4(w.x & 0xffffu, w.x >> 16, w.y & 0xffffu, w.y >> 16) : uint4(w.x & 0xffu, (w.x >> 8) & 0xffu, (w.x >> 16) & 0xffu, w.x >> 24);
    uint sh = 32u - (8u << sz);
    uint4 r;
    switch (kind) {
        case 1u: r = as_type<uint4>(sz == 0u ? unpack_unorm4x8_to_float(w.x) : float4(unpack_unorm2x16_to_float(w.x), unpack_unorm2x16_to_float(w.y))); break;
        case 2u: r = as_type<uint4>(sz == 0u ? unpack_snorm4x8_to_float(w.x) : float4(unpack_snorm2x16_to_float(w.x), unpack_snorm2x16_to_float(w.y))); break;
        case 4u: r = as_type<uint4>(as_type<int4>(c << sh) >> sh); break;
        case 5u: r = sz == 1u ? as_type<uint4>(float4(as_type<half4>(ushort4(c)))) : c; break;
        case 6u: r = as_type<uint4>(float4(c)); break;
        case 7u: r = as_type<uint4>(float4(as_type<int4>(c << sh) >> sh)); break;
        case 11u: r = as_type<uint4>(unpack_unorm4x8_to_float(w.x).zyxw); break;
        default: r = c; break;   // 3: uint
    }
    return select(uint4(0u, 0u, 0u, kind == 3u || kind == 4u ? 1u : 0x3f800000u), r, uint4(0u, 1u, 2u, 3u) < uint4(n));
}
// NVN attribute a of this draw, for vertex vid of instance iid ([[vertex_id]] and [[instance_id]], which include the base vertex and base instance; bi: [[base_instance]])
static inline uint4 dm_fetch(constant dm_vlayout &L, uint a, uint vid, uint iid, uint bi) {
    uint w = L.attr[a], off = (w >> 8) & 0x7ffffu, st = w >> 27, stride = L.s[st].stride, div = L.s[st].divisor;
    uint idx = stride == 0u ? 0u : div != 0u ? (iid - bi) / div + bi : vid;
    uint rel = idx * stride + off;
    return dm_decode(L.s[st].base + rel, w & 0xffu, (rel & 3u) == 0u);
}

""";

        /// <summary>msl 里除 keep 之外的顶层 vertex 函数都去掉（一个函数从「vertex ...」那行到下一个单独的「}」行）</summary>
        static string DropEntries(string msl, ICollection<string> keep)
        {
            var lines = msl.Split('\n'); var o = new List<string>();
            for (int i = 0; i < lines.Length;)
            {
                var m = MatchStart(@"vertex \S+ (\w+)\(", lines[i]);
                if (m.Success && !keep.Contains(m.Groups[1].Value))
                {
                    int j = i; while (j < lines.Length && lines[j] != "}") j++;
                    i = j + 1; continue;
                }
                o.Add(lines[i]); i++;
            }
            return string.Join("\n", o);
        }

        /// <summary>入口的参数表按顶层逗号切开（模板实参表里有自己的逗号）</summary>
        static List<string> Params(string rest)
        {
            var o = new List<string>(); int depth = 0; var cur = new StringBuilder();
            foreach (char ch in rest)
            {
                if (ch == '<' || ch == '(') depth++;
                else if (ch == '>' || ch == ')') depth--;
                if (ch == ',' && depth == 0) { o.Add(cur.ToString().Trim()); cur.Clear(); }
                else cur.Append(ch);
            }
            if (cur.ToString().Trim().Length > 0) o.Add(cur.ToString().Trim());
            return o;
        }

        /// <summary>顶点着色器全部入口的库源码 → (拉取版 MSL, {entry, entry_z（有才有）, slot, inputs}) 或 (null, 原因串)；"no stage input" = 不读顶点属性，本来就没有顶点描述可变</summary>
        public static (string, object) Variant(string msl)
        {
            var m = Search(@"\nstruct main0_in\n\{\n(.*?)\n\};", msl, RegexOptions.Singleline);
            if (!m.Success) return (null, "no stage input");
            if (Has(msl, $"[[buffer({SLOT})]]")) return (null, $"buffer {SLOT} is taken");
            var members = new List<(string t, string n, int l)>();
            foreach (var ln in m.Groups[1].Value.Split('\n'))
            {
                var mm = Full(@"    (float4|uint4|int4) (m_\d+(?:_\d+)*) \[\[attribute\((\d+)\)\]\];", ln);   // m_28_0：拆成逐元素的输入数组
                if (!mm.Success) { var s = ln.Trim(); return (null, "an input declaration not understood: " + (s.Length > 60 ? s[..60] : s)); }
                members.Add((mm.Groups[1].Value, mm.Groups[2].Value, Int(mm.Groups[3].Value)));
            }
            if (members.Any(x => x.l >= 32)) return (null, "an input at attribute 32 or above");   // NVN2 有 32 个属性，布局块全装得下
            string head = msl[..m.Index] + "\nstruct main0_in\n{\n" + string.Join("\n", members.Select(x => $"    {x.t} {x.n};")) + "\n};";
            string body = DropEntries(msl[(m.Index + m.Length)..], new[] { "main0", "main0_z" });
            bool hasZ = false;
            foreach (var entry in new[] { "main0", "main0_z" })
            {
                var hdr = Search(@"\nvertex main0_out " + entry + @"\(main0_in in \[\[stage_in\]\]((?:, [^\n]*)?)\)\n\{\n", body);
                if (!hdr.Success) { if (entry == "main0") return (null, "main0 signature not recognized"); continue; }
                string rest = hdr.Groups[1].Value;
                var vid = Search(@"uint (\w+) \[\[vertex_id\]\]", rest); var iid = Search(@"uint (\w+) \[\[instance_id\]\]", rest); var bi = Search(@"uint (\w+) \[\[base_instance\]\]", rest);
                var ps = rest.Length > 0 ? Params(rest[2..]) : new List<string>();
                ps.Add($"constant dm_vlayout& dm_lay [[buffer({SLOT})]]");
                if (!vid.Success) ps.Add("uint dm_vid [[vertex_id]]");
                if (!iid.Success) ps.Add("uint dm_iid [[instance_id]]");
                if (!bi.Success) ps.Add("uint dm_bi [[base_instance]]");
                string vn = vid.Success ? vid.Groups[1].Value : "dm_vid", inn = iid.Success ? iid.Groups[1].Value : "dm_iid", bn = bi.Success ? bi.Groups[1].Value : "dm_bi";
                var pro = new StringBuilder("    main0_in in;\n");
                foreach (var (t, n, l) in members) pro.Append($"    in.{n} = as_type<{t}>(dm_fetch(dm_lay, {l}u, {vn}, {inn}, {bn}));\n");
                if (Find(body, "\n}\n", hdr.Index + hdr.Length) < 0) return (null, "end of " + entry + " not found");
                body = body[..hdr.Index] + $"\nvertex main0_out {entry}(" + string.Join(", ", ps) + ")\n{\n" + pro + body[(hdr.Index + hdr.Length)..];
                if (entry == "main0_z") hasZ = true;
            }
            int ui = Find(head, "using namespace metal;");
            if (ui < 0) return (null, "no \"using namespace metal;\"");
            ui += "using namespace metal;".Length;
            head = head[..ui] + "\n\n" + Prelude + head[ui..];
            var info = new PyDict { ["entry"] = "main0" };
            if (hasZ) info["entry_z"] = "main0_z";
            info["slot"] = (long)SLOT; info["inputs"] = members.Select(x => (object)(long)x.l).ToList();
            return (head + body, info);
        }
    }
}
