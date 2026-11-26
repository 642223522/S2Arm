using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    public static partial class Program
    {
        // 即时存档请求日志：AudioOut / AudioIn 的缓冲队列命令不进日志（队列另存 audout.bin / audin.bin），日志只跟活状态走、不随录音 / 放音时长涨。期望按剧本手算：
        //   管理器开会话 1 条 + 会话 Start / 取事件 / 设增益（音量）3 条 = 4 条；之后每 20 ms 一轮的追加 / 取已交还 / 查含有 / 计数 / 取状态 / 取增益全不记。
        //   「1 分钟」= 3000 轮、「10 分钟」= 30000 轮，两者都是 4 条。负对照：队列规则关掉，进日志的随轮数涨（10 分钟 > 20 万条）
        [SoloTest("--snap-audio-queue-log")]
        private static int SnapAudioQueueLog()
        {
            var rows = new List<(string N, string E, string A)>();
            int Run(string obj, string mgr, int rounds, (long Open, long[] State, long[] Queue) cmds)
            {
                int logged = 0;
                void Req(string n, long c) { if (!SnapLog.Drop(n, c)) logged++; }
                Req(mgr, cmds.Open);
                foreach (long c in cmds.State) Req(obj, c);
                for (int i = 0; i < rounds; i++) foreach (long c in cmds.Queue) Req(obj, c);
                return logged;
            }
            const string Ns = "Ryujinx.Horizon.Sdk.Audio.Detail.";
            var audin = (Open: 1L, State: new long[] { 1, 4, 12 }, Queue: new long[] { 3, 5, 6, 11, 0, 13, 8, 9 });   // 开 / Start、取事件、设增益 / 追加、取已交还、查含有、计数、取状态、取增益、追加 Auto、取已交还 Auto
            var audout = (Open: 1L, State: new long[] { 1, 4, 12 }, Queue: new long[] { 3, 5, 6, 9, 10, 7, 8 });   // 开 / Start、取事件、设音量 / 追加、取已交还、查含有、计数、已播采样数、追加 Auto、取已交还 Auto
            int in1 = Run(Ns + "AudioIn", Ns + "AudioInManager", 3000, audin), in10 = Run(Ns + "AudioIn", Ns + "AudioInManager", 30000, audin);
            int out1 = Run(Ns + "AudioOut", Ns + "AudioOutManager", 3000, audout), out10 = Run(Ns + "AudioOut", Ns + "AudioOutManager", 30000, audout);
            rows.Add(("① AudioIn 录 1 分钟 / 10 分钟进日志条数", "4 / 4", $"{in1} / {in10}"));
            rows.Add(("② AudioOut 放 1 分钟 / 10 分钟进日志条数", "4 / 4", $"{out1} / {out10}"));
            SnapLog.AudioQueueRulesOn = false;
            try { int neg = Run(Ns + "AudioIn", Ns + "AudioInManager", 30000, audin); rows.Add(("③ 负对照：队列规则关掉，AudioIn 10 分钟 > 20 万条", "是", neg > 200000 ? "是" : $"否（{neg}）")); }
            finally { SnapLog.AudioQueueRulesOn = true; }
            int failures = 0;
            foreach ((string n, string ex, string a) in rows) { bool ok = ex == a; if (!ok) failures++; Console.WriteLine($"{(ok ? "✓" : "✗")} {n}：{ex} → {a}"); }
            return failures == 0 ? 0 : 1;
        }
    }
}
