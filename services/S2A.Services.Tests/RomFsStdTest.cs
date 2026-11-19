// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using LibHac.Fs;
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Path = System.IO.Path;

namespace S2A.Services.Tests
{
    // 标准 RomFS 镜像形态（产物根 / Mac 运行版本里 romfs/ 不在、只有 romfs.std；DLC 同理 aoc/<idx>.std）：RomFsIndex.StdOf / OpenStd / ReadLog。
    //   期望值不跑被测实现：文件内容是本测写下的固定字节，读记录的 sha256 由本测对这些固定字节直接算。
    //   ① StdOf：目录在 → null（照旧读目录）；目录不在、.std 在 → .std 路径；都不在 → null
    //   ② OpenStd 没有覆盖层：逐文件读回与夹具相同；③ 有界面覆盖层（ui_overlay/romfs）：被覆盖的读覆盖层那份，其余读镜像
    //   ④ 诊断读记录：目录现建与镜像两种形态读同一个文件，记录行（去掉时间与来源列）逐字相同，路径 / 文件内偏移 / 长度 / sha256 都是期望值
    public static partial class Program
    {
        [SoloTest("--romfs-std")]
        public static int RomFsStdTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_romfs_std_{Environment.ProcessId}");
            string rom = Path.Combine(root, "romfs"), std = Path.Combine(root, "img", "romfs.std"), over = Path.Combine(root, "ui_overlay", "romfs");
            int failures = 0;
            void Check(string name, string expected, string actual)
            {
                bool ok = expected == actual;
                if (!ok) failures++;
                Console.WriteLine($"{name}：期望 {expected} → 实 {actual} {(ok ? "✓" : "✗")}");
            }
            static string Hex(byte[] b) => Convert.ToHexStringLower(SHA256.HashData(b));
            try
            {
                byte[] text = Encoding.ASCII.GetBytes("hello romfs"), big = new byte[3000], over1 = Encoding.ASCII.GetBytes("OVERRIDDEN LAYOUT!");
                Array.Fill(big, (byte)0x5A);
                Directory.CreateDirectory(Path.Combine(rom, "a"));
                Directory.CreateDirectory(Path.Combine(over, "a"));
                Directory.CreateDirectory(Path.GetDirectoryName(std));
                File.WriteAllBytes(Path.Combine(rom, "a", "s.txt"), text);
                File.WriteAllBytes(Path.Combine(rom, "b.bin"), big);
                File.WriteAllBytes(Path.Combine(over, "a", "s.txt"), over1);
                File.WriteAllBytes(std, Array.Empty<byte>());
                RomFsIndex.WriteStandard(rom, null, std, 0);

                // ①
                string imgRom = Path.Combine(root, "img", "romfs");
                Check("StdOf：目录在", "null", RomFsIndex.StdOf(rom) ?? "null");
                Check("StdOf：目录不在、.std 在", std, RomFsIndex.StdOf(imgRom) ?? "null");
                Check("StdOf：目录带尾分隔符", std, RomFsIndex.StdOf(imgRom + Path.DirectorySeparatorChar) ?? "null");
                Check("StdOf：都不在", "null", RomFsIndex.StdOf(Path.Combine(root, "none")) ?? "null");

                // ②
                using (IStorage s = RomFsIndex.OpenStd(std))
                {
                    Check("无覆盖层：a/s.txt", Hex(text), Hex(ReadRom(s, "/a/s.txt")));
                    Check("无覆盖层：b.bin", Hex(big), Hex(ReadRom(s, "/b.bin")));
                    s.GetSize(out long size);
                    Check("无覆盖层：整个文件直接交（长度 = 镜像文件长）", new FileInfo(std).Length.ToString(), size.ToString());
                }
                // ③
                using (IStorage s = RomFsIndex.OpenStd(std, over))
                {
                    Check("覆盖层：被覆盖的读覆盖层", Hex(over1), Hex(ReadRom(s, "/a/s.txt")));
                    Check("覆盖层：其余读镜像", Hex(big), Hex(ReadRom(s, "/b.bin")));
                }
                // ④
                string Logged(IStorage image, string name)
                {
                    string log = Path.Combine(root, name + ".log");
                    using (IStorage s = RomFsIndex.ReadLog(image, name, log)) ReadRom(s, "/b.bin");
                    StringBuilder sb = new();
                    foreach (string line in File.ReadAllLines(log))
                    {
                        string[] c = line.Split('\t');
                        if (c[2] != "<元数据>") sb.Append(string.Join('\t', c[2..])).Append('|');
                    }
                    return sb.ToString();
                }
                string want = $"b.bin\t0\t3000\t{Hex(big)}|";
                Check("读记录：目录现建形态", want, Logged(S2A.Services.Application.RomFsFromDirectory(rom), "dir"));
                Check("读记录：镜像形态", want, Logged(RomFsIndex.OpenStd(std), "std"));
                IStorage plain = RomFsIndex.OpenStd(std);
                Check("读记录：没给记录文件 = 原对象", "True", ReferenceEquals(plain, RomFsIndex.ReadLog(plain, "x", null)).ToString());
                plain.Dispose();
            }
            finally { Directory.Delete(root, true); }
            return failures == 0 ? 0 : 1;
        }
    }
}
