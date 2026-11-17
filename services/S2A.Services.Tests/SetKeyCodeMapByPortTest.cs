// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Text;

namespace S2A.Services.Tests
{
    // set ISettingsServer 命令 12 GetKeyCodeMapByPort（17.0.0+）：11-14 诊断 D-YHRE，没实现回 2010-0221、游戏开局 Break。
    //   期望按协议手写：结果 0，填回的键位表与命令 9 GetKeyCodeMap2 同一份（主机只有一套布局，端口不改内容）
    public static unsafe partial class Program
    {
        [SoloTest("--set-keycodemap-byport", Booted = true)]
        static void SetKeyCodeMapByPort()
        {
            Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
            uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
            uint set = Call(sm, Msg.Cmif(1, Name8("set"))).Move[0];
            byte* two = FakeNative.Alloc(0x1000), byPort = FakeNative.Alloc(0x1000);
            new Span<byte>(byPort, 0x1000).Fill(0xCD);
            Msg m2 = Msg.Cmif(9); m2.B.Add(((ulong)two, 0x1000));
            Reply r2 = Call(set, m2);
            Msg m12 = Msg.Cmif(12, BitConverter.GetBytes(0u)); m12.B.Add(((ulong)byPort, 0x1000));
            Reply r12 = Call(set, m12);
            Check("set 命令 12 GetKeyCodeMapByPort 结果", 0u, r12.Result);
            Check("set 命令 12 与命令 9 键位表一致", "True", (r2.Result == 0 && new ReadOnlySpan<byte>(two, 0x1000).SequenceEqual(new ReadOnlySpan<byte>(byPort, 0x1000))).ToString());
            FakeNative.HandleClose(set); FakeNative.HandleClose(sm);
        }
    }
}
