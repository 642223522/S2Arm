using Ryujinx.Horizon.Common;
using Ryujinx.Memory;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Threading;

namespace S2A.Services.Tests
{
    // #1339 Horizon 服务堆在 48 位地址空间内核上落到 2^39 外：MemoryBlock 不带提示落高区时，改从 2^39 往下按 1 GiB 步试 MAP_FIXED_NOREPLACE（LowHeapBlock）。
    //   期望值按 Linux mmap 语义手写，不跑被测实现推：候选 = 2^39 − 4 MiB − k GiB（k = 0..507，k = 508 已低于 4 GiB），共 508 个。
    //   ① 假 mmap（各平台都跑）：老内核把 NOREPLACE 当提示、首个候选落在别处 → munmap 那块、拿第二个候选；Dispose 走同一个 munmap、只放一次；全部失败 → null、正好试 508 次
    //   ② 非 Linux / Android（Mac 门禁）：TryCreate 回 null，SetHeapSize 照旧用 MemoryBlock、成功且在 39 位内（苹果路径不变）
    //   ③ Linux 真内核（Mac 上跳过，在 Linux x86_64 / arm64 上跑）：先占住首个候选（2^39 − 4 MiB），MemoryBlock 本落 39 位外时
    //      SetHeapSize 拿到第二个候选、/proc/self/maps 里正好一段 4 MiB；线程注销后这段映射消失（走 munmap，不走 MemoryBlock 释放）；
    //      mmap 全部失败时仍回 OutOfMemory 并报红 +1
    static class LowHeapBlockTest
    {
        [SoloTest("--low-heap-block")]
        public static int Run()
        {
            const ulong top = 1UL << 39, gib = 1UL << 30, r = NativeSyscall.HeapReserve;
            int failures = 0;
            void Check(string name, string expected, string actual)
            {
                bool ok = expected == actual;
                if (!ok) failures++;
                Console.WriteLine($"{name}：期望 {expected} → 实 {actual} {(ok ? "✓" : "✗")}");
            }

            // ① 假 mmap：老内核语义
            {
                var unmaps = new List<(ulong, ulong)>();
                int calls = 0;
                LowHeapBlock b = LowHeapBlock.Search(r, (hint, size) => ++calls == 1 ? hint + 0x10000 : hint, (a, s) => unmaps.Add((a, s)));
                Check("① 老内核把 NOREPLACE 当提示：首个候选落别处", $"第二个候选 0x{top - r - gib:x}、试 2 次、放掉 0x{top - r + 0x10000:x}/{r >> 20} MiB",
                    $"{(b == null ? "null" : $"第二个候选 0x{b.Address:x}")}、试 {calls} 次、放掉 {string.Join(",", unmaps.ConvertAll(u => $"0x{u.Item1:x}/{u.Item2 >> 20} MiB"))}");
                unmaps.Clear();
                b?.Dispose();
                b?.Dispose();
                Check("① Dispose 走建块时的 munmap、只放一次", $"0x{top - r - gib:x}/{r >> 20} MiB",
                    string.Join(",", unmaps.ConvertAll(u => $"0x{u.Item1:x}/{u.Item2 >> 20} MiB")));

                calls = 0;
                unmaps.Clear();
                LowHeapBlock none = LowHeapBlock.Search(r, (_, _) => { calls++; return LowHeapBlock.MapFailed; }, (a, s) => unmaps.Add((a, s)));
                Check("① 全部候选失败", "null、试 508 次、不放", $"{(none == null ? "null" : "拿到块")}、试 {calls} 次、{(unmaps.Count == 0 ? "不放" : $"放 {unmaps.Count} 次")}");
            }

            bool linux = OperatingSystem.IsLinux() || OperatingSystem.IsAndroid();   // 平台例外：期望值按平台分（Linux 走真内核用例，别的平台核 TryCreate 回 null），与 LowHeapBlock.TryCreate 的平台例外同口径
            NativeSyscall sys = new(null);
            (Result Rc, ulong Addr, string Maps, string After) OnThread(Func<ulong, string> maps)
            {
                (Result, ulong, string, string) res = default;
                Thread t = new(() =>
                {
                    Result rc = sys.SetHeapSize(out ulong addr, 2UL << 20);
                    string m = maps(addr);
                    NativeSyscall.UnregisterServiceThread(0);
                    res = (rc, addr, m, maps(addr));
                });
                t.Start();
                t.Join();
                return res;
            }

            if (!linux)
            {
                // ② 苹果路径不变
                Check("② 非 Linux：LowHeapBlock.TryCreate", "null", LowHeapBlock.TryCreate(r) == null ? "null" : "拿到块");
                var res = OnThread(_ => "");
                Check("② 非 Linux：SetHeapSize 用 MemoryBlock", "Success、在 39 位内", $"{res.Rc}、{(NativeSyscall.FitsHipcAddr(res.Addr, r) ? "在 39 位内" : $"0x{res.Addr:x} 在界外")}");
                Console.WriteLine("③ Linux 真内核用例：本机不是 Linux，跳过（在 Linux x86_64 / arm64 上跑 --low-heap-block）");
                return failures == 0 ? 0 : 1;
            }

            // ③ Linux 真内核
            static string MapsAt(ulong addr)
            {
                if (addr == 0) return "无";
                foreach (string line in File.ReadLines("/proc/self/maps"))
                {
                    string[] range = line.Split(' ', 2)[0].Split('-');
                    ulong lo = ulong.Parse(range[0], NumberStyles.HexNumber), hi = ulong.Parse(range[1], NumberStyles.HexNumber);
                    if (addr >= lo && addr < hi) return lo == addr ? $"一段 {(hi - lo) >> 20} MiB" : $"落在 0x{lo:x}-0x{hi:x} 中间";
                }
                return "无";
            }

            ulong probe;
            using (MemoryBlock mb = new(r)) probe = (ulong)mb.Pointer;
            if (NativeSyscall.FitsHipcAddr(probe, r))
            {
                Console.WriteLine($"③ 本机内核 MemoryBlock 本就落在 39 位内（0x{probe:x}），走不到低地址重映射：真内核用例跳过，换 48 位地址空间的 Linux 跑");
            }
            else
            {
                ulong occupied = LowHeapBlock.Map(top - r, r);
                Check("③ 先占住首个候选", $"0x{top - r:x}", occupied == LowHeapBlock.MapFailed ? "mmap 失败" : $"0x{occupied:x}");
                var res = OnThread(MapsAt);
                Check("③ MemoryBlock 落 39 位外（0x" + probe.ToString("x") + "）：SetHeapSize 改用低地址映射",
                    $"Success、0x{top - r - gib:x}、一段 {r >> 20} MiB、注销后 无", $"{res.Rc}、0x{res.Addr:x}、{res.Maps}、注销后 {res.After}");
                if (occupied != LowHeapBlock.MapFailed) LowHeapBlock.Unmap(occupied, r);

                Func<ulong, ulong, ulong> real = LowHeapBlock.Map;
                bool strict = Red.Strict;
                LowHeapBlock.Map = (_, _) => LowHeapBlock.MapFailed;
                Red.Strict = false;
                long red0 = Red.Total;
                try
                {
                    var fail = OnThread(_ => "");
                    Check("③ 低地址候选全部失败", $"{KernelResult.OutOfMemory}、地址 0、报红 +1", $"{fail.Rc}、地址 {fail.Addr:x}、报红 +{Red.Total - red0}");
                }
                finally
                {
                    LowHeapBlock.Map = real;
                    Red.Strict = strict;
                }
            }

            return failures == 0 ? 0 : 1;
        }
    }
}
