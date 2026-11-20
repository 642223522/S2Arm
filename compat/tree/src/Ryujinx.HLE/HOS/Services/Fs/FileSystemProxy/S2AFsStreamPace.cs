using Ryujinx.Common.Logging;
using System;
using System.Diagnostics;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.Fs.FileSystemProxy
{
    // S2Arm：流式读按真机存储速度限流（只限「同一线程、同一文件 / 存储、连续小块顺序读」）。
    //   起因（010019401051C000 开场影片必崩）：游戏给影片播放器写死一块 64 MB 的空闲表堆（main+0xab4624），
    //   里面既放影片读缓存（NuCachedSource2，64 KB 一页、读满 20 MB 为止），也放解码输出画面缓冲（每块约 2.2 MB、共 15 块）。
    //   真机从存储读 20 MB 要几百毫秒，解码器先分好画面缓冲、缓存再慢慢填；我们读宿主文件几毫秒就把 320 页读完，
    //   缓存先占满堆，第 15 块画面缓冲要不到，游戏自己的分配器主动陷阱（main+0x683584）。只给这条读缓存加每次 1 ms（约 64 MB/s）就不再崩。
    //   上游 Ryujinx 对另一款游戏也有同类「承重 sleep」（IStorage.Read 的 Xc2MenuSoftlockFix）——游戏依赖读盘比 CPU 慢的时序。
    // 速度取 100 MB/s：真机存储里最快的是内置 eMMC 与 UHS-I microSD（总线上限 104 MB/s，实测顺序读约 90–100 MB/s），卡带更慢（约 25–50 MB/s）。
    //   取最快那档的量级当上限：任何游戏的流式读都不会比在真机上慢，只是不再快到几 GB/s。
    // 只限流式读：单次请求超过 SmallMax 的（大块加载）、偏移不接着上一次的（随机读）、换了文件 / 存储或换了线程的，一律不计、不睡，
    //   并清零这条流的累计量；同一条流连续小块顺序读累计满 StreamMinBytes 之后的部分才按速度记账。
    //   依据（Mac 上逐条流量过）：读档 / 过场加载读的多是几百 KB 到 1–2 MB 的中等文件，逐个限流会把读档拖慢约半秒；
    //   大文件的连续读只有开头约 4 MB 读得比真机快，之后游戏自己就读得比真机慢。影片读缓存是一口气预读 20 MB（上面那款），
    //   实测前 8 MB 不限就照样陷阱、前 2 MB 不限不陷阱。门槛取 2 MB：中等文件整段不受限、读档不变慢；影片缓存过了 2 MB 仍按真机速度填。
    // 睡在锁外：Read 里只记该睡多久（Pending），宿主服务分发层（S2A.Services HleTarget）放开会话锁之后才睡（SleepPending，单次封顶 50 ms），
    //   不让一个线程的限流挡住同一会话里别的线程的读。
    static class S2AFsStreamPace
    {
        internal const long BytesPerSecond = 100_000_000;
        internal const long SmallMax = 256 * 1024;
        internal const long StreamMinBytes = 2L << 20;
        internal const long SleepMinTicksDiv = 1000;   // 欠账满 1 ms 才睡（Thread.Sleep 的粒度），不够的累到下次
        internal const long PendingMaxTicksDiv = 20;   // 待睡封顶 50 ms：万一有不经服务分发层的路径调 Read（只记不睡），下次经过分发层也不会一次睡一大块

        internal struct State
        {
            public object Owner;
            public long End;       // 上一次读的结束偏移
            public long Bytes;     // 这条流连续小块顺序读累计字节（含开头那次）
            public long Next;      // 按速度，这条流下一次读最早可以完成的时刻（Stopwatch 刻度）
        }

        [ThreadStatic] private static State t_state;
        [ThreadStatic] private static long t_pending;

        // 纯函数（单测直接调）：记一次成功的读，返回这次读完之后应再等的刻度数（0 = 不等）
        internal static long Account(ref State s, object owner, long offset, long length, long now, long frequency)
        {
            bool sequential = length > 0 && length <= SmallMax && ReferenceEquals(owner, s.Owner) && offset == s.End;

            s.Owner = owner;
            s.End = offset + Math.Max(length, 0);

            if (!sequential)
            {
                s.Bytes = length > 0 && length <= SmallMax ? length : 0;
                s.Next = 0;
                return 0;
            }

            long before = s.Bytes;
            s.Bytes += length;
            long paced = s.Bytes - Math.Max(before, StreamMinBytes);   // 只记跨过门槛之后的字节

            if (paced <= 0)
            {
                return 0;
            }

            s.Next = Math.Max(s.Next, now) + paced * frequency / BytesPerSecond;
            long wait = s.Next - now;

            return wait >= frequency / SleepMinTicksDiv ? wait : 0;
        }

        // IStorage / IFile 的 Read 成功后调：只记账，不睡（调用方可能还持着会话锁）
        public static void Note(object owner, long offset, long length)
        {
            long wait = Account(ref t_state, owner, offset, length, Stopwatch.GetTimestamp(), Stopwatch.Frequency);

            if (wait > 0)
            {
                if (t_pending == 0 && Interlocked.Exchange(ref s_firstLogged, 1) == 0)
                {
                    Logger.Info?.Print(LogClass.ServiceFs, $"流式读限流：开始（{owner.GetType().Name}，线程 {Environment.CurrentManagedThreadId}，每次 {length} 字节、偏移 0x{offset:X}），按 {BytesPerSecond / 1_000_000} MB/s 记账");
                }

                t_pending = Math.Min(t_pending + wait, Stopwatch.Frequency / PendingMaxTicksDiv);
            }
        }

        private static int s_firstLogged;
        private static long s_sleeps, s_sleptTicks;

        // 服务分发层放开锁之后调：取走本线程待睡的刻度数并睡掉。每睡满 4096 次汇总一行（次数、合计毫秒），现场看得出限流睡了多少
        public static void SleepPending()
        {
            long wait = t_pending;

            if (wait <= 0)
            {
                return;
            }

            t_pending = 0;
            Thread.Sleep(TimeSpan.FromTicks(wait * TimeSpan.TicksPerSecond / Stopwatch.Frequency));

            long total = Interlocked.Add(ref s_sleptTicks, wait);
            long n = Interlocked.Increment(ref s_sleeps);

            if ((n & 4095) == 0)
            {
                Logger.Info?.Print(LogClass.ServiceFs, $"流式读限流：累计睡 {n} 次、合计 {total * 1000 / Stopwatch.Frequency} ms");
            }
        }
    }
}
