using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档请求日志按活对象有界（ReqTable，维护者 11-19 判据）：固定一批活对象 + 大量「开对象 → 发几条请求 → 关对象」，
        //   条目数 / 字节只随活对象数变，不随循环次数变。期望值按活对象数手算（每个活对象：建它 1 条 + 发给它 R 条），不跑被测实现推。
        //   负对照：关掉收集（Collecting = false），同样的序列条目数随循环次数涨 → 判据确实分得开
        [SoloTest("--snap-reqtable")]
        private static int SnapReqTable()
        {
            const int Live = 5, PerLive = 3, Cycles = 10000, PerCycle = 4, Bytes = 100;
            (int count, long bytes) Run(bool collecting, int cycles, Func<int, bool> live)
            {
                var t = new ReqTable { Collecting = collecting, HasLiveHandles = live };
                int seq = 0; var root = new ReqTable.Key(1, 0); t.Add(seq++, new byte[Bytes], root);   // sm 会话的建立（根，一直活着）
                for (int i = 0; i < Live; i++)
                {   // 活对象：根上一条建它的请求 + 发给它的 PerLive 条
                    int c = seq++; t.Add(c, new byte[Bytes], root); var k = new ReqTable.Key(100 + (ulong)i, 0); t.Created(c, k);
                    for (int r = 0; r < PerLive; r++) t.Add(seq++, new byte[Bytes], k);
                }
                for (int n = 0; n < cycles; n++)
                {   // 开文件：活对象 0 上一条建域对象的请求 → 发 PerCycle 条 → 关它（关的那条也发给它）
                    var owner = new ReqTable.Key(100, 0); int c = seq++; t.Add(c, new byte[Bytes], owner); var f = new ReqTable.Key(100, 1000 + n); t.Created(c, f);
                    for (int r = 0; r < PerCycle; r++) t.Add(seq++, new byte[Bytes], f);
                    t.Add(seq++, new byte[Bytes], f); t.Close(f);
                }
                return (t.Count, t.Bytes);
            }
            int want = 1 + Live * (1 + PerLive);
            var rows = new List<(string N, string E, string A)>();
            var a = Run(true, Cycles, _ => false); var b = Run(true, 10, _ => false);
            rows.Add(("① 1 万次开关后：条目 / 字节（期望按活对象手算）", $"{want} / {want * Bytes}", $"{a.count} / {a.bytes}"));
            rows.Add(("② 循环 10 次与 1 万次条目相同（不随次数涨）", $"{b.count}", $"{a.count}"));
            var c = Run(false, Cycles, _ => false);
            rows.Add(("③ 负对照：关掉收集，条目随次数涨（> 1 万）", "是", c.count > Cycles ? "是" : $"否（{c.count}）"));
            // ④ 建过还活着的句柄的请求不能删：开关循环里每次的建对象请求都建了活句柄 → 这些建的请求留着（对象收了、建它的留着）
            int first = 1 + Live * (1 + PerLive), step = 1 + PerCycle + 1;   // 每轮 = 建 1 + 发 PerCycle + 关 1，建的那条序号 = first + 轮数 × step
            var d = Run(true, 100, s => s >= first && (s - first) % step == 0);
            rows.Add(("④ 建对象那条建了还活着的句柄：留下（100 次留 100 条 + 活对象那些）", $"{want + 100}", $"{d.count}"));
            // ⑤ 会话句柄关了：它和它的域对象一起收（父对象等子对象收完再收）
            {
                var t = new ReqTable(); var root = new ReqTable.Key(1, 0); t.Add(0, new byte[Bytes], root);
                t.Add(1, new byte[Bytes], root); var s = new ReqTable.Key(7, 0); t.Created(1, s);   // 取服务建会话 7
                t.Add(2, new byte[Bytes], s); var dom = new ReqTable.Key(7, 3); t.Created(2, dom);   // 会话 7 上建域对象 3
                t.Add(3, new byte[Bytes], dom);
                t.CloseSession(7);
                rows.Add(("⑤ 会话句柄关：会话与其域对象的请求、建会话那条全收（剩根 1 条）", "1", $"{t.Count}"));
            }
            // ⑥ 句柄依赖：会话 1 上第 1 条建了句柄（日志编号 7），会话 2 上第 3 条递了它。关会话 1 → 第 1 条被钉住，4 条都在；
            //   关会话 2 → 第 3 条删掉、解钉 → 第 1 条、会话 1、建会话 1 的第 0 条一起收，0 条；解钉调用 1 次、编号 7。负对照（不登记依赖）关会话 1 后剩 2 条
            foreach (bool dep in new[] { true, false })
            {
                var unused = new List<uint>(); var t = new ReqTable { Unuse = u => unused.Add(u) }; var root = new ReqTable.Key(0, 0);
                var s1 = new ReqTable.Key(1, 0); var s2 = new ReqTable.Key(2, 0);
                t.Add(0, new byte[Bytes], root); t.Created(0, s1); t.Add(1, new byte[Bytes], s1);
                t.Add(2, new byte[Bytes], root); t.Created(2, s2); t.Add(3, new byte[Bytes], s2);
                if (dep) t.Use(3, 7, 1);
                t.CloseSession(1); int afterS1 = t.Count;
                t.CloseSession(2); int afterS2 = t.Count;
                if (dep) rows.Add(("⑥ 句柄依赖：关会话 1 后 / 关会话 2 后条数、解钉调用", "4 / 0 / 7", $"{afterS1} / {afterS2} / {string.Join(",", unused)}"));
                else rows.Add(("⑥ 负对照：不登记依赖，关会话 1 后条数", "2", $"{afterS1}"));
            }
            int failures = 0;
            foreach ((string n, string e, string ac) in rows) { bool ok = e == ac; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{e} → {ac}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
