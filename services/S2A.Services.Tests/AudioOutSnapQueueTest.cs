using Ryujinx.Audio;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Input;
using Ryujinx.Audio.Integration;
using Ryujinx.Audio.Output;
using System;
using System.Collections.Generic;
using System.Threading;

namespace S2A.Services.Tests
{
    // 即时存档：audout 缓冲队列存取（AudioOutputSystem.S2ASnapshot / S2ARestore）。
    //   A 局：追加 6 个缓冲，硬件放完前 3 个、游戏取走 1 个 → 快照里已交还未取走 [2, 3]、在途 [4, 5, 6]、已播 960 样本。
    //   B 局（新会话、Start 后恢复）：游戏按顺序取到 2、3；硬件按顺序收到 4、5、6；已播采样数接着 960 往上走；放完 4 后能取到 4。
    //   负对照：不恢复的新会话一个都取不到（原先就是这样：游戏等不到它以为排着的缓冲交还）
    public static partial class Program
    {
        private sealed class FakeHw : IHardwareDeviceSession
        {
            public readonly List<ulong> Queued = new();
            public readonly HashSet<ulong> Consumed = new();
            public ulong Played;
            public bool RegisterBuffer(AudioBuffer buffer) => true;
            public void UnregisterBuffer(AudioBuffer buffer) { }
            public void QueueBuffer(AudioBuffer buffer) => Queued.Add(buffer.BufferTag);
            public bool WasBufferFullyConsumed(AudioBuffer buffer) => Consumed.Contains(buffer.BufferTag);
            public void SetVolume(float volume) { }
            public float GetVolume() => 1;
            public ulong GetPlayedSampleCount() => Played;
            public void Start() { }
            public void Stop() { }
            public void PrepareToClose() { }
            public void Dispose() { }
        }

        private sealed class FakeEvent : IWritableEvent
        {
            public int Signals;
            public void Signal() => Signals++;
            public void Clear() { }
        }

        private static AudioOutputSystem NewOut(FakeHw hw, FakeEvent ev)
        {
            var o = new AudioOutputSystem(null, new Lock(), hw, ev);
            var cfg = new AudioInputConfiguration { SampleRate = 48000, ChannelCount = 2 };
            if (o.Initialize("", SampleFormat.PcmInt16, ref cfg, 0) != ResultCode.Success) throw new InvalidOperationException("audout 初始化失败");
            o.Start();
            return o;
        }

        private static List<ulong> Released(AudioOutputSystem o)
        {
            Span<ulong> tags = stackalloc ulong[8];
            o.GetReleasedBuffer(tags, out uint n);
            var r = new List<ulong>();
            for (int i = 0; i < n; i++) r.Add(tags[i]);
            return r;
        }

        [SoloTest("--audout-snap-queue")]
        internal static int AudOutSnapQueue()
        {
            int bad = 0;
            void Check(string what, bool ok, string got) { Console.WriteLine($"{(ok ? "通过" : "不通")} {what}{(ok ? "" : $"：真结果 {got}")}"); if (!ok) bad++; }

            // A 局：追加 6 个、硬件放完前 3 个、游戏只取走 1 个
            var hwA = new FakeHw(); var evA = new FakeEvent(); var a = NewOut(hwA, evA);
            for (ulong t = 1; t <= 6; t++) { var ub = new AudioUserBuffer { Data = 0x1000 * t, DataSize = 0x100 * t }; a.AppendBuffer(t, ref ub); }
            hwA.Consumed.UnionWith(new ulong[] { 1, 2, 3 }); hwA.Played = 960; a.Update();
            Span<ulong> one = stackalloc ulong[1]; a.GetReleasedBuffer(one, out uint got1);
            Check("A 局游戏取走 1 个（tag 1）", got1 == 1 && one[0] == 1, $"{got1} 个 {one[0]}");
            var snap = a.S2ASnapshot();
            Check("快照：已交还未取走 = [2, 3]", snap.Released.Length == 2 && snap.Released[0].Item1 == 2 && snap.Released[1].Item1 == 3, string.Join(",", Array.ConvertAll(snap.Released, x => x.Item1)));
            Check("快照：在途 = [4, 5, 6]（地址 / 大小随行）", snap.Pending.Length == 3 && snap.Pending[0].Item1 == 4 && snap.Pending[2].Item1 == 6 && snap.Pending[0].Item2 == 0x4000 && snap.Pending[0].Item3 == 0x400,
                string.Join(",", Array.ConvertAll(snap.Pending, x => $"{x.Item1}@{x.Item2:X}+{x.Item3:X}")));
            Check("快照：已播 960 样本", snap.Played == 960, snap.Played.ToString());

            // 负对照：不恢复的新会话
            var hwN = new FakeHw(); var n = NewOut(hwN, new FakeEvent());
            Check("负对照：不恢复时游戏一个已交还都取不到（原先的卡死）", Released(n).Count == 0, "取到了");

            // B 局
            var hwB = new FakeHw(); var evB = new FakeEvent(); var b = NewOut(hwB, evB);
            int re = b.S2ARestore(snap.Released, snap.Pending, snap.Played);
            Check("B 局重新追加在途 3 个", re == 3, re.ToString());
            Check("B 局硬件按顺序收到 4、5、6", hwB.Queued.Count == 3 && hwB.Queued[0] == 4 && hwB.Queued[1] == 5 && hwB.Queued[2] == 6, string.Join(",", hwB.Queued));
            Check("B 局恢复时发了交还事件", evB.Signals >= 1, evB.Signals.ToString());
            var rb = Released(b);
            Check("B 局游戏按顺序取到 2、3", rb.Count == 2 && rb[0] == 2 && rb[1] == 3, string.Join(",", rb));
            hwB.Played = 100;
            Check("B 局已播采样数接着 960 走（硬件放了 100 → 1060）", b.GetPlayedSampleCount() == 1060, b.GetPlayedSampleCount().ToString());
            hwB.Consumed.Add(4); b.Update();
            var rb2 = Released(b);
            Check("B 局放完 4 后取到 4", rb2.Count == 1 && rb2[0] == 4, string.Join(",", rb2));
            Check("B 局对已有队列的会话不再恢复（回 -1）", b.S2ARestore(snap.Released, snap.Pending, snap.Played) == -1, "没拒");

            // AudioIn（麦克风）同一套：A 局追加 3 个、录满 1 个且游戏没取 → 快照 已交还 [11]、在途 [12, 13]；B 局恢复后取到 11、硬件收到 12、13
            var hwI = new FakeHw(); var ia = new AudioInputSystem(null, new Lock(), hwI, new FakeEvent());
            var icfg = new AudioInputConfiguration { SampleRate = 48000, ChannelCount = 2 };
            if (ia.Initialize("", SampleFormat.PcmInt16, ref icfg, 0) != ResultCode.Success) throw new InvalidOperationException("audin 初始化失败");
            ia.Start();
            for (ulong t = 11; t <= 13; t++) { var ub = new AudioUserBuffer { Data = 0x1000 * t, DataSize = 0x100 }; ia.AppendBuffer(t, ref ub); }
            hwI.Consumed.Add(11); ia.Update();
            var isnap = ia.S2ASnapshot();
            Check("audin 快照：已交还 [11]、在途 [12, 13]", isnap.Released.Length == 1 && isnap.Released[0].Item1 == 11 && isnap.Pending.Length == 2 && isnap.Pending[0].Item1 == 12,
                $"{string.Join(",", Array.ConvertAll(isnap.Released, x => x.Item1))} / {string.Join(",", Array.ConvertAll(isnap.Pending, x => x.Item1))}");
            var hwIB = new FakeHw(); var ib = new AudioInputSystem(null, new Lock(), hwIB, new FakeEvent());
            ib.Initialize("", SampleFormat.PcmInt16, ref icfg, 0); ib.Start();
            int ire = ib.S2ARestore(isnap.Released, isnap.Pending, isnap.Played);
            Span<ulong> itags = stackalloc ulong[4]; ib.GetReleasedBuffers(itags, out uint ign);
            Check("audin B 局：取到 11、硬件按顺序收到 12、13", ire == 2 && ign == 1 && itags[0] == 11 && hwIB.Queued.Count == 2 && hwIB.Queued[0] == 12 && hwIB.Queued[1] == 13,
                $"追加 {ire}、取到 {ign} 个 {itags[0]}、硬件 {string.Join(",", hwIB.Queued)}");

            Console.WriteLine(bad == 0 ? "audout / audin 快照队列单测全过" : $"audout / audin 快照队列单测 {bad} 项不通");
            return bad == 0 ? 0 : 1;
        }
    }
}
