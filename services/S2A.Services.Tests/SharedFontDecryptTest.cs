// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Buffers.Binary;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;

namespace S2A.Services.Tests
{
    // 共享字体解密（Ryujinx.HLE SharedFontManager.DecryptFont）对文件流只取一次长度（11-17 D-FCMF：Switch 2 游戏取内置字体 2010 等了 190 秒、黑屏，
    //   玩家现场栈停在 fstat——上游循环条件每 4 字节取一次 Stream.Length，文件流上每次一次 fstat，17.5 MB 字体约 440 万次）。
    //   期望值不跑被测实现：造一份 BFTTF（头 = 魔数 ^ 键、长度字、正文按公开格式每 4 字节异或 0x06186249），正文明文按下标手造；
    //   计数流数 Length 被读几次。期望：解出的正文与明文逐字节同；Length 读 1 次（上游写法是 正文字数 + 1 次）
    public static partial class Program
    {
        private sealed class LengthCountingStream(byte[] data) : MemoryStream(data, writable: false)
        {
            public int LengthReads;

            public override long Length
            {
                get
                {
                    LengthReads++;
                    return base.Length;
                }
            }
        }

        [SoloTest("--shared-font-decrypt")]
        private static int SharedFontDecrypt()
        {
            const uint Key = 0x06186249, Magic = 0x18029a7f;
            const int Words = 250_000;   // 1 MB 正文：上游写法要读 25 万次 Length
            byte[] plain = new byte[Words * 4];
            for (int i = 0; i < plain.Length; i++)
            {
                plain[i] = (byte)(i * 31 + 7);
            }

            byte[] file = new byte[8 + plain.Length];
            BinaryPrimitives.WriteUInt32LittleEndian(file, Magic ^ Key);
            BinaryPrimitives.WriteUInt32LittleEndian(file.AsSpan(4), BinaryPrimitives.ReverseEndianness((uint)plain.Length) ^ Key);
            for (int w = 0; w < Words; w++)
            {
                BinaryPrimitives.WriteUInt32LittleEndian(file.AsSpan(8 + w * 4), BinaryPrimitives.ReadUInt32LittleEndian(plain.AsSpan(w * 4)) ^ Key);
            }

            Type mgr = typeof(Ryujinx.HLE.Switch).Assembly.GetType("Ryujinx.HLE.HOS.Services.Sdb.Pl.SharedFontManager", throwOnError: true)!;
            MethodInfo decrypt = mgr.GetMethod("DecryptFont", BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.Instance)!;
            // 实例方法（上游写法）不读成员：造一个未初始化实例来调，负对照才能量到长度读取次数
            object? self = decrypt.IsStatic ? null : RuntimeHelpers.GetUninitializedObject(mgr);

            using LengthCountingStream stream = new(file);
            byte[] got = (byte[])decrypt.Invoke(self, [stream])!;

            int bad = 0;
            if (got.Length != plain.Length)
            {
                bad++;
            }
            else
            {
                for (int i = 0; i < plain.Length; i++)
                {
                    bad += got[i] != plain[i] ? 1 : 0;
                }
            }

            bool ok = bad == 0 && stream.LengthReads == 1;
            Console.WriteLine($"{(ok ? "✓" : "✗")} 共享字体解密：正文 {plain.Length} 字节逐字节同（期望 0 处不同 → 真结果 {bad} 处）；文件长度读 {stream.LengthReads} 次（期望 1 次，上游写法 {Words + 1} 次）");
            return ok ? 0 : 1;
        }
    }
}
