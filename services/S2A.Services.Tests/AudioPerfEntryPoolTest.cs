// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio.Renderer.Dsp.Command;
using Ryujinx.Audio.Renderer.Server.Performance;
using Ryujinx.Common;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

namespace S2A.Services.Tests
{
    // 音频性能统计条目池（#668：Mac 玩几分钟到十几分钟后音频线程托管 OOM，栈在 PerformanceCommand.Initialize → ConcurrentBag.LocalPush）。
    //   CommandGenerator 每对 Start / End 命令只取一个 PerformanceEntryAddresses、两条命令共用；命令被复用时归还旧条目。
    //   期望手算：每轮取 1 个、还 1 个，池里的条目数恒 ≤ 1、没有同一对象的多份。跑 1000 轮：
    //   修前两条命令各还一次 → 每轮净涨 1，池里约 1000 个、全是重复引用；修后 ≤ 1、无重复
    static class AudioPerfEntryPoolTest
    {
        const int Rounds = 1000;

        static ConcurrentBag<PerformanceEntryAddresses> Items() =>
            (ConcurrentBag<PerformanceEntryAddresses>)typeof(ObjectPool<PerformanceEntryAddresses>)
                .GetField("_items", BindingFlags.NonPublic | BindingFlags.Instance)!
                .GetValue(PerformanceEntryAddresses.PerformanceEntryAddressesPool)!;

        [SoloTest("--audio-perf-entry-pool")]
        private static int Run()
        {
            var pool = PerformanceEntryAddresses.PerformanceEntryAddressesPool;
            pool.Clear();
            var start = new PerformanceCommand();
            var end = new PerformanceCommand();
            for (int i = 0; i < Rounds; i++)
            {
                PerformanceEntryAddresses entry = pool.Allocate();   // 同 PerformanceManagerGeneric.GetNextEntry
                start.Initialize(ref entry, PerformanceCommand.Type.Start, 0);   // 同 CommandBuffer.GeneratePerformance，命令从池里复用
                end.Initialize(ref entry, PerformanceCommand.Type.End, 0);
            }

            var items = Items().ToArray();
            int distinct = new HashSet<PerformanceEntryAddresses>(items, ReferenceEqualityComparer.Instance).Count;
            int bad = 0;
            bool small = items.Length <= 1;
            if (!small) bad++;
            Console.WriteLine($"{(small ? "✓" : "✗")} {Rounds} 轮 Start / End 共用条目后池里 {items.Length} 个（期望 ≤ 1，修前约 {Rounds}）");
            bool unique = distinct == items.Length;
            if (!unique) bad++;
            Console.WriteLine($"{(unique ? "✓" : "✗")} 池里没有同一对象的多份：{items.Length} 个里不同对象 {distinct} 个");

            // 负对照：End 被复用时确实归还了（不是两条都不还、靠漏掉对象让池子不涨）
            pool.Clear();
            start = new PerformanceCommand(); end = new PerformanceCommand();   // 新命令：上面循环里的 End 还拿着最后一轮的条目，复用时会先还那一个
            PerformanceEntryAddresses held = pool.Allocate();
            start.Initialize(ref held, PerformanceCommand.Type.Start, 0);
            end.Initialize(ref held, PerformanceCommand.Type.End, 0);
            PerformanceEntryAddresses none = null;
            start.Initialize(ref none, PerformanceCommand.Type.Start, 0);
            end.Initialize(ref none, PerformanceCommand.Type.End, 0);
            var back = Items().ToArray();
            bool returned = back.Length == 1 && ReferenceEquals(back[0], held);
            if (!returned) bad++;
            Console.WriteLine($"{(returned ? "✓" : "✗")} End 复用时把共用条目还回池里恰好一次（池里 {back.Length} 个）");

            pool.Clear();
            return bad == 0 ? 0 : 1;
        }
    }
}
