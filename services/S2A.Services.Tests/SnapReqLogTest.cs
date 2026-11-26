using System;
using System.Collections.Generic;
using System.IO;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档请求日志的内存分块压缩（SnapLog.ReqLog）：期望由写进去的字节直接比对，不跑实现推
        //   ① 写约 3 MB（跨 1 MB 块界）→ 存盘 → 读回逐字节相同
        //   ② 旧快照的原样日志（没有「SLZ1」头）读回原样
        //   ③ 内存里实际占的 < 原始的一半（日志是结构化重复数据：同样的请求头、描述符）
        //   ④ Reset 后长度归零，再写再存读照样相同
        [SoloTest("--snap-reqlog")]
        private static int SnapReqLog()
        {
            var rows = new List<(string N, string E, string A)>();
            string dir = Path.Combine(Path.GetTempPath(), $"s2a_reqlog_{Environment.ProcessId}"); Directory.CreateDirectory(dir);
            try
            {
                var log = new ReqLog(); var raw = new MemoryStream(); var bw = new BinaryWriter(raw);
                var rnd = new Random(7);
                for (int i = 0; raw.Length < 3 << 20; i++)
                {   // 一条「请求」：类型、序号、服务名、消息（头固定 + 几字节变化）
                    byte[] msg = new byte[256]; msg[0] = 0x04; msg[8] = (byte)'S'; msg[9] = (byte)'F'; msg[10] = (byte)'C'; msg[11] = (byte)'I'; BitConverter.TryWriteBytes(msg.AsSpan(16), i); msg[20 + rnd.Next(8)] = (byte)rnd.Next(256);
                    foreach (var w in new[] { log.W, bw }) { w.Write(1u); w.Write(i); w.Write("INvDrvServices"); w.Write(msg.Length); w.Write(msg); }
                    log.Seal();
                }
                bw.Flush();
                string p1 = Path.Combine(dir, "ipc.bin"); log.SaveTo(p1);
                byte[] back = ReqLog.Load(File.ReadAllBytes(p1));
                rows.Add(("① 约 3 MB 跨块存读：长度 / 逐字节", $"{raw.Length} / 相同", $"{back.Length} / {(back.AsSpan().SequenceEqual(raw.ToArray()) ? "相同" : "不同")}"));
                rows.Add(("③ 内存里占的 < 原始一半", "是", log.Stored * 2 < log.Length ? "是" : $"否（{log.Stored} / {log.Length}）"));
                byte[] legacy = raw.ToArray()[..4096];
                rows.Add(("② 旧快照原样日志读回原样", "相同", ReqLog.Load(legacy).AsSpan().SequenceEqual(legacy) ? "相同" : "不同"));
                log.Reset();
                log.W.Write(1u); log.W.Write(9); log.Seal();
                string p2 = Path.Combine(dir, "ipc2.bin"); log.SaveTo(p2);
                byte[] b2 = ReqLog.Load(File.ReadAllBytes(p2));
                rows.Add(("④ Reset 后再写 8 字节存读", "8 / 01000000-09000000", $"{b2.Length} / {Convert.ToHexString(b2.AsSpan(0, 4))}-{Convert.ToHexString(b2.AsSpan(4, Math.Min(4, Math.Max(0, b2.Length - 4))))}"));
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
            int failures = 0;
            foreach ((string n, string e, string a) in rows) { bool ok = e == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{e} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
