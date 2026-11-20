using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档请求日志里 nvdrv 按语义收住的几类（SnapLog.NvStep）：固定的活状态 + 大量重复 / 成对请求，日志只跟活状态走。期望按下面的剧本手算：
        //   ctrl fd 5 注册槽 0 / 1 / 2（3 条照常记）；每槽 EventWaitAsync 各 1 万次 → 只留 3 条；Signal 槽 1（记 1 条）→ 留 2；槽 1 再等 1 次 → 3；Kill 槽 0 和 2（记 1 条）→ 1
        //   通道 fd 7 映射句柄 {10, 11}（记 1 条）；再 Map {10, 11} + Unmap 各 1 万次 → 都不记；Map {11, 12}（12 是新的，记）；Free 10（记）；Map {10}（释放后要重新映射，记）
        //   照常进日志合计 3 + 1 + 1 + 1 + 1 + 1 + 1 = 9 条，按槽留 1 条
        //   负对照：规则关掉，照常进日志的随次数涨（> 2 万）
        [SoloTest("--snap-nvrules")]
        private static int SnapNvRules()
        {
            var rows = new List<(string N, string E, string A)>();
            (int logged, int kept) Run(int rounds)
            {
                SnapLog.NvReset(); int logged = 0;
                byte[] e = new byte[] { 1 };
                void Step(uint fd, uint ioc, byte[] arg) { int r = SnapLog.NvStep(1, fd, ioc, arg, () => e, out int[] map); if (r == 0) { logged++; SnapLog.NvMapped(map); } }
                byte[] U32(uint v) => BitConverter.GetBytes(v);
                byte[] Wait(uint slot) { byte[] a = new byte[16]; BitConverter.TryWriteBytes(a.AsSpan(12), slot); return a; }
                byte[] Map(params int[] hs) { byte[] a = new byte[12 + hs.Length * 8]; BitConverter.TryWriteBytes(a.AsSpan(0), hs.Length); for (int i = 0; i < hs.Length; i++) BitConverter.TryWriteBytes(a.AsSpan(12 + i * 8), hs[i]); return a; }
                const uint Reg = 0xC004001F, Sig = 0xC004001C, Kill = 0xC0080021, WaitA = 0xC010001E, MapI = 0xC0A40009, UnmapI = 0xC0A4000A, Free = 0xC0180105;
                for (uint s = 0; s < 3; s++) Step(5, Reg, U32(s));
                for (int i = 0; i < rounds; i++) for (uint s = 0; s < 3; s++) Step(5, WaitA, Wait(s));
                Step(5, Sig, U32(1)); Step(5, WaitA, Wait(1));
                Step(5, Kill, BitConverter.GetBytes(0b101UL));
                Step(7, MapI, Map(10, 11));
                for (int i = 0; i < rounds; i++) { Step(7, MapI, Map(10, 11)); Step(7, UnmapI, Map(10, 11)); }
                Step(7, MapI, Map(11, 12)); Step(7, Free, U32(10)); Step(7, MapI, Map(10));
                return (logged, SnapLog.NvWaitsKept);
            }
            var big = Run(10000); var small = Run(10);
            rows.Add(("① 1 万轮后：照常进日志 / 按槽留", "9 / 1", $"{big.logged} / {big.kept}"));
            rows.Add(("② 10 轮与 1 万轮相同（不随次数涨）", $"{small.logged} / {small.kept}", $"{big.logged} / {big.kept}"));
            SnapLog.NvRulesOn = false;
            try { var neg = Run(10000); rows.Add(("③ 负对照：规则关掉，照常进日志 > 2 万", "是", neg.logged > 20000 ? "是" : $"否（{neg.logged}）")); }
            finally { SnapLog.NvRulesOn = true; SnapLog.NvReset(); }
            int failures = 0;
            foreach ((string n, string ex, string a) in rows) { bool ok = ex == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{ex} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
