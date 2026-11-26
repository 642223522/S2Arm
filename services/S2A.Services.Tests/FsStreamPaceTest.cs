// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Services.Fs.FileSystemProxy;
using System;

namespace S2A.Services.Tests
{
    // fs 流式读限流（compat S2AFsStreamPace.Account，纯函数，时钟由测试给）。期望手算，不跑被测实现：
    //   刻度频率取 1e9（1 刻度 = 1 ns），速度 100 MB/s → 64 KB（65536 字节）记 655360 ns；欠账满 1 ms（1e6 ns）才回等待。
    //   ① 大块：每次 1 MB 连续顺序读 100 次，时钟不走 → 每次都回 0（超过 SmallMax 256 KB，大块加载不限流）
    //   ② 随机：64 KB 小读，偏移每次跳开（不接上一次结尾）100 次 → 每次都回 0
    //   ③ 流式：64 KB 连续顺序读、时钟不走：门槛 2 MB = 32 次，前 32 次累计不过门槛回 0；第 33 次记 655360 < 1e6 仍回 0；
    //      第 34 次欠账 1310720 ≥ 1e6 回 1310720，第 35 次 1966080
    //   ④ 换存储：③ 之后换一个存储对象读同样的偏移 → 回 0（换流清零）
    //   ⑤ 真机速度量级：400 次 64 KB 流式读、每次按回的等待推进时钟，墙钟 ≥ (400 − 32) × 65536 × 10 ns − 1 ms 欠账
    //   ⑥ 中等文件：64 KB 连续读整个 2 MB 文件（32 次）→ 每次都回 0（不到门槛，读档不变慢）
    static class FsStreamPaceTest
    {
        private const long F = 1_000_000_000;

        [SoloTest("--fs-stream-pace")]
        static int Run()
        {
            int bad = 0;
            void Row(string what, string expect, string got)
            {
                bool ok = expect == got;
                if (!ok) bad++;
                Console.WriteLine($"{(ok ? "✓" : "✗")} {what}：期望 {expect} → 真结果 {got}");
            }

            object a = new(), b = new();

            // ① 大块
            var s = new S2AFsStreamPace.State();
            long sum = 0;
            for (int i = 0; i < 100; i++) sum += S2AFsStreamPace.Account(ref s, a, (long)i << 20, 1 << 20, 0, F);
            Row("大块 1 MB 连续读 100 次的等待合计", "0", sum.ToString());

            // ② 随机
            s = new S2AFsStreamPace.State();
            sum = 0;
            for (int i = 0; i < 100; i++) sum += S2AFsStreamPace.Account(ref s, a, (long)(i * 7 % 100) << 20, 65536, 0, F);
            Row("64 KB 随机读 100 次的等待合计", "0", sum.ToString());

            // ③ 流式
            s = new S2AFsStreamPace.State();
            sum = 0;
            for (int i = 0; i < 33; i++) sum += S2AFsStreamPace.Account(ref s, a, i * 65536L, 65536, 0, F);
            long w130 = S2AFsStreamPace.Account(ref s, a, 33 * 65536L, 65536, 0, F);
            long w131 = S2AFsStreamPace.Account(ref s, a, 34 * 65536L, 65536, 0, F);
            Row("64 KB 连续读：前 33 次等待合计；第 34、35 次", "0;1310720,1966080", $"{sum};{w130},{w131}");

            // ④ 换存储
            Row("换一个存储对象接着读的等待", "0", S2AFsStreamPace.Account(ref s, b, 35 * 65536L, 65536, 0, F).ToString());

            // ⑤ 平均速度
            s = new S2AFsStreamPace.State();
            long now = 0;
            for (int i = 0; i < 400; i++) now += S2AFsStreamPace.Account(ref s, a, i * 65536L, 65536, now, F);
            long floor = (400L - 32) * 65536 * 10 - F / 1000;
            Row("64 KB 流式读 400 次按等待推进后的墙钟 ≥ 下限", "是", now >= floor ? "是" : $"否（{now} < {floor}）");

            // ⑥ 读档突发
            s = new S2AFsStreamPace.State();
            sum = 0;
            for (int i = 0; i < 32; i++) sum += S2AFsStreamPace.Account(ref s, a, i * 65536L, 65536, 0, F);
            Row("64 KB 连续读整个 2 MB 文件的等待合计", "0", sum.ToString());

            return bad == 0 ? 0 : 1;
        }
    }
}
