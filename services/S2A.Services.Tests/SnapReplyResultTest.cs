using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // 即时存档请求日志的成败判定（SnapLog.ReplyResult）：只在这条应答的原始数据段里取结果码。期望按 HIPC / CMIF / TIPC 格式手写，不跑实现推：
        //   ① TIPC 应答成功（原始数据第 1 字 0），缓冲后面留着上一条 CMIF 应答的 "SFCO" + 0xE401 → 0（大金刚第 125 条 sm 取 hid 的情形）
        //   ② CMIF 应答失败：原始数据段里 16 字节对齐处 "SFCO"，结果 0x1234 → 0x1234
        //   ③ 关对象应答（原始数据 0 字），缓冲里留着旧 "SFCO" + 0xE401 → 0
        //   ④ 带特殊头（移交 1 个句柄）的 CMIF 应答：原始数据段从 0x10 起，"SFCO" 结果 0x77 → 0x77
        //   ⑤ TIPC 应答失败：原始数据第 1 字 0xC0A → 0xC0A
        //   负对照：原先「前 0x100 字节里找 SFCO」的判法在 ① ③ 上给出 0xE401（判据确实分得开新旧）
        [SoloTest("--snap-reply-result")]
        private static int SnapReplyResult()
        {
            byte[] buf = new byte[0x100];
            void Reset() { Array.Clear(buf); }
            void W(int off, uint v) => BitConverter.TryWriteBytes(new Span<byte>(buf, off, 4), v);
            void Sfco(int off, uint rc) { W(off, 0x4F434653u); W(off + 4, 0); W(off + 8, rc); }
            uint New(bool tipc) { fixed (byte* p = buf) return SnapLog.ReplyResult(p, buf.Length, tipc); }
            uint Old() { for (int i = 0; i + 12 <= buf.Length; i += 4) if (BitConverter.ToUInt32(buf, i) == 0x4F434653u) return BitConverter.ToUInt32(buf, i + 8); return 0; }
            var rows = new List<(string N, string E, string A)>();

            Reset(); Sfco(0x40, 0xE401); W(0, 0); W(4, 1); W(8, 0);
            rows.Add(("① TIPC 成功 + 缓冲里旧 SFCO 0xE401：新判法 / 旧判法", "0x0 / 0xE401", $"0x{New(true):X} / 0x{Old():X}"));

            Reset(); W(0, 0); W(4, 8); Sfco(0x10, 0x1234);
            rows.Add(("② CMIF 失败（段内 SFCO 0x1234）", "0x1234", $"0x{New(false):X}"));

            Reset(); Sfco(0x10, 0xE401); W(0, 0); W(4, 0);
            rows.Add(("③ 关对象应答（原始数据 0 字）+ 旧 SFCO：新判法 / 旧判法", "0x0 / 0xE401", $"0x{New(false):X} / 0x{Old():X}"));

            Reset(); W(0, 0); W(4, 8u | 1u << 31); W(8, 1u << 5); W(12, 0x1234); Sfco(0x10, 0x77);
            rows.Add(("④ 特殊头移交 1 个句柄、段内 SFCO 0x77", "0x77", $"0x{New(false):X}"));

            Reset(); W(0, 0); W(4, 1); W(8, 0xC0A);
            rows.Add(("⑤ TIPC 失败（原始数据第 1 字 0xC0A）", "0xC0A", $"0x{New(true):X}"));

            int failures = 0;
            foreach ((string n, string e, string a) in rows)
            {
                bool ok = e == a;
                if (!ok) failures++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{e} → {a}");
            }
            return failures == 0 ? 0 : 1;
        }
    }
}
