// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using LibHac;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.RomFs;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Path = System.IO.Path;

namespace S2A.Services.Tests
{
    // 资源替换类 mod（RomFsMods.cs）：<本款文档根>/mods/<任意名>/romfs/** 叠到本体 RomFS 上。
    //   两种 RomFS 形态各跑一遍：目录 + 预建索引（RomFsIndex.Open）、单文件镜像（RomFsIndex.OpenImage，romfs.img + romfs.imgmap）。
    //   期望值不跑被测实现：原包与 mod 的文件都是本测写下的固定字节（长度 × 一个字节值），读回按「长度 × 值」比对。
    static class RomFsModsTest
    {
        [SoloTest("--romfs-mods")]
        public static int Run()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_romfs_mods_{Environment.ProcessId}");
            bool strict = Red.Strict;
            Action<string> redLog = Red.Log, modLog = RomFsMods.Log;
            List<string> lines = new();
            int failures = 0;
            void Check(string name, string expected, string actual)
            {
                bool ok = expected == actual;
                if (!ok) failures++;
                Console.WriteLine($"{name}：期望 {expected} → 实 {actual} {(ok ? "✓" : "✗")}");
            }
            static byte[] All(IStorage s)
            {
                s.GetSize(out long n).ThrowIfFailure();
                byte[] b = new byte[n];
                s.Read(0, b).ThrowIfFailure();
                return b;
            }
            // 读 RomFS 里一个文件：「长度×0x值」（内容齐）或说明
            static string Read(IStorage image, string path)
            {
                var fs = new RomFsFileSystem(image);
                if (!fs.FileTable.TryOpenFile(path, out RomFileInfo info)) return "没有";
                byte[] b = new byte[info.Length];
                Result r = image.Read(fs.Header.DataOffset + info.Offset, b);
                if (r.IsFailure()) return r.ToString();
                if (b.Length == 0) return "0";
                return Array.TrueForAll(b, x => x == b[0]) ? $"{b.Length}×0x{b[0]:X2}" : $"{b.Length} 内容不齐";
            }
            // 经 LibHac 的文件系统接口枚举（游戏走 fs 读到的就是这一棵）：文件路径升序、逗号连
            static string Tree(IStorage image) =>
                string.Join(",", new RomFsFileSystem(image).EnumerateEntries().Where(e => e.Type == DirectoryEntryType.File).Select(e => e.FullPath).OrderBy(p => p, StringComparer.Ordinal));
            static void Put(string dir, string rel, int len, byte v) => RomFsModsFixture.Put(dir, rel, len, v);
            // 读一次，抛出的异常也当结果（游戏运行中 mod 被删：修前异常穿出服务边界）
            static string TryRead(IStorage image, string path)
            {
                try { return Read(image, path); }
                catch (Exception e) { return "抛 " + e.GetType().Name; }
            }

            // 原包：a.bin、Data/b.bin、Data/c.bin、Data/z.bin（零长度）
            Dictionary<string, (int Len, byte V)> baseFiles = new() { ["a.bin"] = (1000, 0x11), ["Data/b.bin"] = (1100, 0x22), ["Data/c.bin"] = (1200, 0x33), ["Data/z.bin"] = (0, 0) };

            // 建一份程序目录（只建一次），按形态打开本体 RomFS
            IStorage OpenBase(string program, bool image)
            {
                if (!File.Exists(Path.Combine(program, RomFsIndex.FileName))) RomFsModsFixture.MakeProgram(program, baseFiles, image);
                return RomFsModsFixture.Open(program, image);
            }

            try
            {
                Red.Strict = false;   // 负对照的红行（坏文件）不终止本测
                Red.Log = l => { lines.Add(l); Console.WriteLine("    | " + l); };
                RomFsMods.Log = l => { lines.Add(l); Console.WriteLine("    | " + l); };

                foreach (bool image in new[] { false, true })
                {
                    string form = image ? "镜像" : "目录索引";
                    string program = Path.Combine(root, form, "game"), mods = Path.Combine(root, form, "docs", RomFsMods.DirName);
                    byte[] want;
                    using (IStorage b = OpenBase(program, image)) want = All(b);
                    Check($"{form}：本体形态打开", "True", (want.Length > 0).ToString());

                    // ① 没有 mods/：原对象原样返回（不包一层、不重建），并建一个空的 mods/
                    using (IStorage b = OpenBase(program, image))
                    {
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, mods);
                        Check($"{form}：没有 mods/ → 原对象返回", "True", ReferenceEquals(s, b).ToString());
                        Check($"{form}：没有 mods/ → 与原路径逐字节一致", "True", want.AsSpan().SequenceEqual(All(s)).ToString());
                        Check($"{form}：起局建空的 mods/", "True", (Directory.Exists(mods) && !Directory.EnumerateFileSystemEntries(mods).Any()).ToString());
                        Check($"{form}：没有 mod 不报红", "0", lines.Count(l => l.Contains("【红】")).ToString());
                    }

                    // ② mods/ 里只有空文件夹、只有 exefs/ 的 mod、macOS 垃圾：仍是原对象；exefs/ 记一行黄
                    Directory.CreateDirectory(Path.Combine(mods, "empty"));
                    Put(mods, "codeonly/exefs/main", 16, 0xEE);
                    Put(mods, ".DS_Store", 8, 0x01);
                    Put(mods, "codeonly/romfs/._a.bin", 8, 0x01);
                    Put(mods, ".off-disabled/romfs/a.bin", 50, 0x0F);   // 启动器 / iPhone 关掉的 mod（pack/jobs/mods.py OFF、ios/vpad_mods.m）：留在 mods/ 里但不叠；③ 起它一直在，「加载 2 个 mod」也证明不算进去
                    using (IStorage b = OpenBase(program, image))
                    {
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, mods);
                        Check($"{form}：mod 里没有 romfs 文件（关掉的 .off- 那份也不算）→ 原对象返回", "True", ReferenceEquals(s, b).ToString());
                        Check($"{form}：mod 里没有 romfs 文件 → 与原路径逐字节一致", "True", want.AsSpan().SequenceEqual(All(s)).ToString());
                        Check($"{form}：exefs/ 被忽略并记黄", "1", lines.Count(l => l.Contains("【黄】") && l.Contains("codeonly") && l.Contains("exefs/")).ToString());
                    }
                    Directory.Delete(Path.Combine(mods, "codeonly"), true);

                    // ③ 两个 mod：同大小替换、不同大小替换、新增文件、新增目录、叠加顺序（文件夹名升序，后者覆盖前者；先建后者，不按建的先后）
                    Put(mods, "20_second/romfs/a.bin", 900, 0xA2);
                    Put(mods, "20_second/cheats/0123456789ABCDEF.txt", 10, 0x41);
                    Put(mods, "10_first/romfs/a.bin", 1000, 0xA1);
                    Put(mods, "10_first/romfs/Data/c.bin", 1200, 0xC1);
                    Put(mods, "10_first/romfs/Data/b.bin", 500, 0xB1);
                    Put(mods, "10_first/romfs/new.txt", 77, 0xD1);
                    Put(mods, "10_first/romfs/NewDir/Sub/x.bin", 33, 0xE1);
                    Put(mods, "10_first/exefs/main", 16, 0xEE);
                    using (IStorage b = OpenBase(program, image))
                    {
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, mods);
                        Check($"{form}：有 mod → 换成新镜像", "False", ReferenceEquals(s, b).ToString());
                        Check($"{form}：两个 mod 叠加顺序（20_second 覆盖 10_first）", "900×0xA2", Read(s, "/a.bin"));
                        Check($"{form}：同大小替换", "1200×0xC1", Read(s, "/Data/c.bin"));
                        Check($"{form}：不同大小替换", "500×0xB1", Read(s, "/Data/b.bin"));
                        Check($"{form}：新增文件", "77×0xD1", Read(s, "/new.txt"));
                        Check($"{form}：新增目录", "33×0xE1", Read(s, "/NewDir/Sub/x.bin"));
                        Check($"{form}：没替换的文件照旧", "0", Read(s, "/Data/z.bin"));
                        Check($"{form}：fs 枚举到的整棵树", "/Data/b.bin,/Data/c.bin,/Data/z.bin,/NewDir/Sub/x.bin,/a.bin,/new.txt", Tree(s));
                        Check($"{form}：起局一行（几个 mod / 替换 / 新增）", "1", lines.Count(l => l.Contains("加载 2 个 mod") && l.Contains("替换 3 个文件") && l.Contains("新增 2 个文件")).ToString());
                        Check($"{form}：起局一行打出生效顺序", "1", lines.Count(l => l.Contains("加载 2 个 mod") && l.Contains("顺序 10_first → 20_second")).ToString());
                        Check($"{form}：exefs/ 记黄", "1", lines.Count(l => l.Contains("【黄】") && l.Contains("10_first") && l.Contains("exefs/")).ToString());
                        Check($"{form}：cheats/ 记黄", "1", lines.Count(l => l.Contains("【黄】") && l.Contains("20_second") && l.Contains("cheats/")).ToString());
                        Check($"{form}：正常 mod 不报红", "0", lines.Count(l => l.Contains("【红】")).ToString());
                        Check($"{form}：新增路径和原包写法不相近 → 不记写法黄", "0", lines.Count(l => l.Contains("写法不同")).ToString());

                        // 整份镜像对照：本测手写一棵「叠好之后应有的」romfs 目录（不经被测实现），用目录现建（Application.RomFsFromDirectory，同序同布局）建参照，逐字节比
                        string expect = Path.Combine(root, form, "expect");
                        foreach ((string rel, (int len, byte v)) in baseFiles) Put(expect, rel, len, v);
                        Put(expect, "a.bin", 900, 0xA2);
                        Put(expect, "Data/c.bin", 1200, 0xC1);
                        Put(expect, "Data/b.bin", 500, 0xB1);
                        Put(expect, "new.txt", 77, 0xD1);
                        Put(expect, "NewDir/Sub/x.bin", 33, 0xE1);
                        using (IStorage reference = S2A.Services.Application.RomFsFromDirectory(expect))
                            Check($"{form}：整份镜像与手写参照逐字节相同", "True", All(reference).AsSpan().SequenceEqual(All(s)).ToString());
                        // 跨区间的一次大读（从头读到尾分 3 段，段界落在文件中间）与整读一致：区间表的二分查找与区间衔接
                        byte[] whole = All(s), pieces = new byte[whole.Length];
                        int cut1 = whole.Length / 3 + 7, cut2 = whole.Length * 2 / 3 + 3;
                        s.Read(0, pieces.AsSpan(0, cut1)).ThrowIfFailure();
                        s.Read(cut1, pieces.AsSpan(cut1, cut2 - cut1)).ThrowIfFailure();
                        s.Read(cut2, pieces.AsSpan(cut2)).ThrowIfFailure();
                        Check($"{form}：分段读与整读一致", "True", whole.AsSpan().SequenceEqual(pieces).ToString());
                        Check($"{form}：越界读回 OutOfRange", ResultFs.OutOfRange.Value.ToString(), s.Read(whole.Length - 1, new byte[2]).ToString());
                    }

                    // ④ 失败的文件逐个报红、其余照叠：读不了的文件、与原包目录同名的文件、原包文件下面的路径
                    Put(mods, "30_bad/romfs/locked.bin", 10, 0x51);
                    File.SetUnixFileMode(Path.Combine(mods, "30_bad/romfs/locked.bin"), UnixFileMode.None);
                    Put(mods, "30_bad/romfs/Data", 10, 0x52);
                    Put(mods, "30_bad/romfs/a.bin/inner.bin", 10, 0x53);
                    Put(mods, "30_bad/romfs/ok.bin", 10, 0x54);
                    Put(mods, "30_bad/romfs/bad\\name.bin", 10, 0x55);   // Unix 上合法的文件名，RomFS 里 \ 是分隔符（评审：原先整批 mod 退回原 RomFS）
                    Put(mods, "30_bad/romfs/lockdir/in.bin", 10, 0x56);
                    File.SetUnixFileMode(Path.Combine(mods, "30_bad/romfs/lockdir"), UnixFileMode.None);   // 列不出的子目录：只丢它，同 mod 的 ok.bin 照叠
                    using (IStorage b = OpenBase(program, image))
                    {
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, mods);
                        Check($"{form}：坏文件旁的好文件照叠", "10×0x54", Read(s, "/ok.bin"));
                        Check($"{form}：读不了的文件逐个报红", "1", lines.Count(l => l.Contains("【红】") && l.Contains("locked.bin")).ToString());
                        Check($"{form}：与原包目录同名的文件报红", "1", lines.Count(l => l.Contains("【红】") && l.Contains("30_bad/romfs/Data")).ToString());
                        Check($"{form}：原包文件下面的路径报红", "1", lines.Count(l => l.Contains("【红】") && l.Contains("a.bin/inner.bin")).ToString());
                        Check($"{form}：文件名带 \\ 的报红", "1", lines.Count(l => l.Contains("【红】") && l.Contains("bad\\name.bin")).ToString());
                        Check($"{form}：列不出的子目录报红", "1", lines.Count(l => l.Contains("【红】") && l.Contains("30_bad/romfs/lockdir/")).ToString());
                        Check($"{form}：超大偏移读回 OutOfRange（不溢出）", ResultFs.OutOfRange.Value.ToString(), s.Read(long.MaxValue, new byte[1]).ToString());
                        Check($"{form}：报红的不进镜像、原包目录还在", "/Data/b.bin,/Data/c.bin,/Data/z.bin,/NewDir/Sub/x.bin,/a.bin,/new.txt,/ok.bin", Tree(s));
                        Check($"{form}：起局一行照打（3 个 mod、新增 3、失败 5）", "1", lines.Count(l => l.Contains("加载 3 个 mod") && l.Contains("新增 3 个文件") && l.Contains("5 个失败")).ToString());
                    }
                    File.SetUnixFileMode(Path.Combine(mods, "30_bad/romfs/locked.bin"), UnixFileMode.UserRead | UnixFileMode.UserWrite);
                    File.SetUnixFileMode(Path.Combine(mods, "30_bad/romfs/lockdir"), UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);

                    // ⑤ 多程序合集：未标目标的 mod 只叠主程序；标了目标的 mod 只叠完整程序号匹配的程序。
                    const ulong mainId = 0x0100ABCD00010000, subId = mainId + 1;
                    string targeted = Path.Combine(root, form, "docs_target", RomFsMods.DirName);
                    Put(targeted, "Default/romfs/a.bin", 13, 0xA0);
                    Put(targeted, $"Target/romfs.{subId:X16}/a.bin", 17, 0xA1);
                    Put(targeted, $"Wrong/romfs.{subId + 0x10:X16}/a.bin", 19, 0xA2);
                    using (IStorage b = OpenBase(program, image))
                    {
                        using IStorage s = RomFsMods.Apply(b, targeted, 0, mainId);
                        Check($"{form}：主程序仅叠未标目标的 mod", "13×0xA0", Read(s, "/a.bin"));
                    }
                    using (IStorage b = OpenBase(program, image))
                    {
                        using IStorage s = RomFsMods.Apply(b, targeted, 1, subId);
                        Check($"{form}：目标子程序只叠完整 ID 匹配的 mod", "17×0xA1", Read(s, "/a.bin"));
                    }
                    using (IStorage b = OpenBase(program, image))
                    {
                        IStorage s = RomFsMods.Apply(b, targeted, 2, mainId + 2);
                        Check($"{form}：无关子程序返回原对象", "True", ReferenceEquals(s, b).ToString());
                    }
                    Directory.Move(Path.Combine(targeted, "Target"), Path.Combine(targeted, ".off-Target"));
                    using (IStorage b = OpenBase(program, image))
                    {
                        IStorage s = RomFsMods.Apply(b, targeted, 1, subId);
                        Check($"{form}：关掉 mod，目标子程序返回原对象", "True", ReferenceEquals(s, b).ToString());
                    }

                    string corrupted = ResultFs.HostFileDataCorrupted.Value.ToString();

                    // ⑥ 游戏运行中 mod 被删（玩家切后台在「文件」App 里动了）：没打开过的 mod 文件再读回失败码、报红，不抛异常穿出服务边界
                    string modsRt = Path.Combine(root, form, "docs_rt", RomFsMods.DirName);
                    Put(modsRt, "rt/romfs/a.bin", 30, 0x91);
                    Put(modsRt, "rt/romfs/gone.bin", 20, 0x92);
                    using (IStorage b = OpenBase(program, image))
                    {
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, modsRt);
                        File.Delete(Path.Combine(modsRt, "rt/romfs/gone.bin"));
                        long red0 = Red.Total;
                        Check($"{form}：运行中删掉 mod 文件 → 读回失败码、不抛", corrupted, TryRead(s, "/gone.bin"));
                        Check($"{form}：运行中删掉 mod 文件 → 报红 1 次", "1", (Red.Total - red0).ToString());
                        Directory.Delete(Path.Combine(modsRt, "rt"), true);
                        red0 = Red.Total;
                        Check($"{form}：运行中删掉整个 mod 文件夹 → 读回失败码、不抛", corrupted, TryRead(s, "/a.bin"));
                        Check($"{form}：运行中删掉整个 mod 文件夹 → 报红 1 次", "1", (Red.Total - red0).ToString());
                        Check($"{form}：mod 被删后原包文件照读", "1100×0x22", TryRead(s, "/Data/b.bin"));
                        Check($"{form}：红行说明是游戏运行中被删 / 改", "True", lines.Any(l => l.Contains("【红】") && l.Contains("游戏运行中")).ToString());
                    }

                    // ⑦ 零长度文件互换：原包零长度的换成有内容的、有内容的换成零长度
                    string modsZ = Path.Combine(root, form, "docs_zero", RomFsMods.DirName);
                    Put(modsZ, "z/romfs/Data/z.bin", 40, 0xF1);
                    Put(modsZ, "z/romfs/Data/b.bin", 0, 0);
                    using (IStorage b = OpenBase(program, image))
                    {
                        IStorage s = RomFsMods.Apply(b, modsZ);
                        Check($"{form}：零长度 → 有内容", "40×0xF1", Read(s, "/Data/z.bin"));
                        Check($"{form}：有内容 → 零长度", "0", Read(s, "/Data/b.bin"));
                        string expect = Path.Combine(root, form, "expect_zero");
                        foreach ((string rel, (int len, byte v)) in baseFiles) Put(expect, rel, len, v);
                        Put(expect, "Data/z.bin", 40, 0xF1);
                        Put(expect, "Data/b.bin", 0, 0);
                        using (IStorage reference = S2A.Services.Application.RomFsFromDirectory(expect))
                            Check($"{form}：零长度互换后整份镜像与手写参照逐字节相同", "True", All(reference).AsSpan().SequenceEqual(All(s)).ToString());
                    }

                    // ⑧ 符号链接不跟随、记黄：指向同目录文件的、指回自己的目录（循环）、指向 mod 外面的
                    string modsL = Path.Combine(root, form, "docs_link", RomFsMods.DirName), lr = Path.Combine(modsL, "l", "romfs");
                    Put(modsL, "l/romfs/real.bin", 10, 0x71);
                    Put(Path.Combine(root, form), "outside.bin", 10, 0x72);
                    File.CreateSymbolicLink(Path.Combine(lr, "link.bin"), "real.bin");
                    Directory.CreateSymbolicLink(Path.Combine(lr, "loop"), ".");
                    File.CreateSymbolicLink(Path.Combine(lr, "out.bin"), Path.Combine(root, form, "outside.bin"));
                    File.CreateSymbolicLink(Path.Combine(lr, "dangling.bin"), "nowhere.bin");   // 目标不在的链接：也只记黄，不因取不到属性把整个目录判成列不出
                    using (IStorage b = OpenBase(program, image))
                    {
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, modsL);
                        Check($"{form}：符号链接不进镜像", "/Data/b.bin,/Data/c.bin,/Data/z.bin,/a.bin,/real.bin", Tree(s));
                        Check($"{form}：符号链接各记一行黄", "4", lines.Count(l => l.Contains("【黄】") && l.Contains("符号链接")).ToString());
                        Check($"{form}：符号链接不报红", "0", lines.Count(l => l.Contains("【红】")).ToString());
                    }

                    // ⑨ mods/ 下直接放的文件（没解压的 zip）记黄；生效顺序按序号序（10_x 排在 2_y 前，后者覆盖前者）
                    string modsO = Path.Combine(root, form, "docs_order", RomFsMods.DirName);
                    Put(modsO, "pack.zip", 10, 0x50);
                    Put(modsO, "10_x/romfs/q.bin", 3, 0x81);
                    Put(modsO, "2_y/romfs/q.bin", 3, 0x82);
                    using (IStorage b = OpenBase(program, image))
                    {
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, modsO);
                        Check($"{form}：序号序 2_y 在 10_x 之后、覆盖它", "3×0x82", Read(s, "/q.bin"));
                        Check($"{form}：起局一行打出顺序 10_x → 2_y", "1", lines.Count(l => l.Contains("顺序 10_x → 2_y")).ToString());
                        Check($"{form}：mods/ 下直接放的文件记黄", "1", lines.Count(l => l.Contains("【黄】") && l.Contains("pack.zip")).ToString());
                    }

                    // ⑩ 界面覆盖层 + mod 同路径：mod 赢，只有覆盖层的仍读覆盖层；新增路径与原包只差大小写 / Unicode 写法记黄；换 NRO 记黄
                    string ov = Path.Combine(root, form, "ov");
                    RomFsModsFixture.MakeProgram(ov, new Dictionary<string, (int, byte)> { ["Layout/u.zs"] = (300, 0x61), ["Layout/v.zs"] = (200, 0x63), ["x.bin"] = (10, 0x66), ["Layout/café.bin"] = (5, 0x67), ["nro/core.nro"] = (16, 0x68) },
                        image, new Dictionary<string, (int, byte)> { ["Layout/u.zs"] = (400, 0x62), ["Layout/v.zs"] = (250, 0x64) });
                    string modsV = Path.Combine(root, form, "docs_ov", RomFsMods.DirName);
                    Put(modsV, "ovm/romfs/Layout/v.zs", 99, 0x65);
                    Put(modsV, "case/romfs/layout/u.zs", 7, 0x69);
                    Put(modsV, "nfd/romfs/Layout/café.bin", 6, 0x6A);
                    Put(modsV, "nro/romfs/nro/core.nro", 16, 0x6B);
                    using (IStorage b = RomFsModsFixture.Open(ov, image))
                    {
                        Check($"{form}：覆盖层夹具：覆盖层文件读覆盖层", "250×0x64", Read(b, "/Layout/v.zs"));
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, modsV);
                        Check($"{form}：覆盖层 + mod 同路径 → mod 赢", "99×0x65", Read(s, "/Layout/v.zs"));
                        Check($"{form}：只有覆盖层的仍读覆盖层", "400×0x62", Read(s, "/Layout/u.zs"));
                        Check($"{form}：覆盖层旁的原文件照读", "10×0x66", Read(s, "/x.bin"));
                        Check($"{form}：大小写不同按新增叠", "7×0x69", Read(s, "/layout/u.zs"));
                        Check($"{form}：大小写不同记黄（点名原包写法）", "1", lines.Count(l => l.Contains("【黄】") && l.Contains("case/romfs/layout/u.zs") && l.Contains("写法不同的 Layout/u.zs")).ToString());
                        Check($"{form}：Unicode 写法不同（NFD 对 NFC）记黄", "1", lines.Count(l => l.Contains("【黄】") && l.Contains("nfd/romfs/") && l.Contains("写法不同的 Layout/café.bin")).ToString());
                        Check($"{form}：换 NRO 记黄", "1", lines.Count(l => l.Contains("【黄】") && l.Contains("nro/romfs/nro/core.nro") && l.Contains("NRO")).ToString());
                        Check($"{form}：换 NRO 照叠（只记黄，不改语义）", "16×0x6B", Read(s, "/nro/core.nro"));
                    }

                    // ⑪ 刁钻的名字（建表顺序是「边走原包文件表边按路径序号序喂」）：比 / 小的字符、互为前缀的文件与目录、非 ASCII（代理对与 U+FF21 的 UTF-16 序和 UTF-8 序相反）、
                    //   原包目录里再新增几层目录——整份镜像仍与手写期望目录现建的参照逐字节相同（顺序错了布局就不同），每个文件内容各自对得上
                    Dictionary<string, (int Len, byte V)> oddBase = new()
                    {
                        ["a"] = (11, 0x01), ["a!/x"] = (12, 0x02), ["a b/x"] = (13, 0x03), ["a-b"] = (14, 0x04), ["a.b/x"] = (15, 0x05), ["a.b/x.y/z"] = (16, 0x06), ["ab"] = (17, 0x07),
                        ["B/x"] = (18, 0x08), ["c/x"] = (0, 0), ["0"] = (19, 0x09), ["~/x"] = (20, 0x0A), ["中文/が.bin"] = (21, 0x0B), ["\uFF21/x"] = (22, 0x0C), ["\uD83D\uDE00/x"] = (23, 0x0D),
                        ["d/e/f/g"] = (24, 0x0E), ["d/e!"] = (25, 0x0F), ["d/e0"] = (26, 0x10),
                    };
                    Dictionary<string, (int Len, byte V)> oddMod = new()
                    {
                        ["a"] = (5, 0x81), ["a.b/x.y/z"] = (0, 0), ["c/x"] = (6, 0x82), ["\uD83D\uDE00/x"] = (7, 0x83),                       // 替换（含零长度互换）
                        ["a!"] = (1, 0xEE), ["a.b/x/deep"] = (1, 0xEF),                                                                 // 建不出的：原包这里是目录、原包 a.b/x 是文件
                        ["a+"] = (8, 0x84), ["a.b/w"] = (9, 0x85), ["a.b/x.y/0/1/2/n"] = (10, 0x86), ["d/e/f/h/i"] = (11, 0x87), ["d/e /x"] = (12, 0x88), ["d/e-"] = (13, 0x89),
                        ["\uFF21/\uD83D\uDE00"] = (14, 0x8A), ["\uFFFD"] = (15, 0x8B), ["new/一/二/三"] = (16, 0x8C), ["!"] = (17, 0x8D), ["中文/か.bin"] = (18, 0x8E),
                    };
                    string odd = Path.Combine(root, form, "odd"), modsD = Path.Combine(root, form, "docs_odd", RomFsMods.DirName), expectD = Path.Combine(root, form, "expect_odd");
                    RomFsModsFixture.MakeProgram(odd, oddBase, image);
                    foreach ((string rel, (int len, byte v)) in oddMod) Put(modsD, "odd/romfs/" + rel, len, v);
                    foreach ((string rel, (int len, byte v)) in oddBase) Put(expectD, rel, len, v);
                    foreach ((string rel, (int len, byte v)) in oddMod) if (rel != "a!" && rel != "a.b/x/deep") Put(expectD, rel, len, v);
                    using (IStorage b = RomFsModsFixture.Open(odd, image))
                    {
                        lines.Clear();
                        IStorage s = RomFsMods.Apply(b, modsD);
                        using (IStorage reference = S2A.Services.Application.RomFsFromDirectory(expectD))
                            Check($"{form}：刁钻名字：整份镜像与手写参照逐字节相同", "True", All(reference).AsSpan().SequenceEqual(All(s)).ToString());
                        int wrong = 0;
                        foreach ((string rel, (int len, byte v)) in oddBase) if (!oddMod.ContainsKey(rel) && Read(s, "/" + rel) != (len == 0 ? "0" : $"{len}×0x{v:X2}")) wrong++;
                        foreach ((string rel, (int len, byte v)) in oddMod) if (rel != "a!" && rel != "a.b/x/deep" && Read(s, "/" + rel) != (len == 0 ? "0" : $"{len}×0x{v:X2}")) wrong++;
                        Check($"{form}：刁钻名字：逐个文件内容不符的个数", "0", wrong.ToString());
                        Check($"{form}：刁钻名字：建不出的两个各报红", "2", lines.Count(l => l.Contains("【红】S2A mod") && (l.Contains("odd/romfs/a! ") || l.Contains("odd/romfs/a.b/x/deep "))).ToString());
                        Check($"{form}：刁钻名字：起局一行（替换 4、新增 11、失败 2）", "1", lines.Count(l => l.Contains("替换 4 个文件") && l.Contains("新增 11 个文件") && l.Contains("2 个失败")).ToString());
                    }
                }

                // ⑫「写法相近」提示的开销：原包一个平铺大目录（3000 个文件，清单给长度、不建真文件），mod 往里新增 300 个——
                //   每个新增文件都对不上同名，原先逐个把整个目录折叠比一遍（300 × 3000 次）；应当每个目录只折叠一遍
                {
                    string flat = Path.Combine(root, "flat"), flatRom = Path.Combine(flat, "romfs"), flatList = Path.Combine(flat, "list.tsv"), modsF = Path.Combine(root, "docs_flat", RomFsMods.DirName);
                    Directory.CreateDirectory(flatRom);
                    StringBuilder sb = new();
                    for (int i = 0; i < 3000; i++) sb.Append("16\ttex/t_").Append(i.ToString("D5")).Append(".bntx\n");
                    File.WriteAllText(flatList, sb.ToString(), new UTF8Encoding(false));
                    RomFsIndex.Write(flatRom, Path.Combine(flat, RomFsIndex.FileName), flatList);
                    for (int i = 0; i < 300; i++) Put(modsF, $"add/romfs/tex/n_{i:D5}.bntx", 4, 0x31);
                    Put(modsF, "case/romfs/Tex2/T_00007.bntx", 4, 0x32);
                    Put(modsF, "zcase/romfs/tex/T_00007.BNTX", 4, 0x33);
                    using IStorage b = RomFsIndex.Open(flatRom, Path.Combine(flat, RomFsIndex.FileName));
                    lines.Clear();
                    long fold0 = RomFsMods.S2ATestFoldCalls;
                    IStorage s = RomFsMods.Apply(b, modsF);
                    long folds = RomFsMods.S2ATestFoldCalls - fold0;
                    Check("平铺大目录新增 300 个：都叠上", "1", lines.Count(l => l.Contains("新增 302 个文件")).ToString());
                    Check("平铺大目录：写法相近的提示照打（只差大小写的那一个）", "1", lines.Count(l => l.Contains("【黄】") && l.Contains("zcase/romfs/tex/T_00007.BNTX") && l.Contains("写法不同的 tex/t_00007.bntx")).ToString());
                    Check("平铺大目录：写法不相近的不打", "1", lines.Count(l => l.Contains("写法不同")).ToString());
                    Check("平铺大目录：折叠次数与文件数同量级（≤ 2 ×（3000 + 302），不是 300 × 3000）", "True", (folds <= 2 * (3000 + 302)).ToString() + (folds <= 2 * (3000 + 302) ? "" : $"（{folds} 次）"));
                }

                // ⑥ 本款文档根：S2A_DOCS 有就用它（多款容器 Documents/games/<游戏号>、Mac 作业层 游戏库/temp/<游戏号>）
                string was = Environment.GetEnvironmentVariable("S2A_DOCS");
                try
                {
                    Environment.SetEnvironmentVariable("S2A_DOCS", Path.Combine(root, "docsroot"));
                    Check("S2A_DOCS → <文档根>/mods", Path.Combine(root, "docsroot", "mods"), RomFsMods.ModsDir() ?? "null");
                    // Mac 作业层直接给这款游戏文件夹的 mods/（S2A_MODS_DIR，pack/jobs/build.py）：优先于 S2A_DOCS
                    Environment.SetEnvironmentVariable("S2A_MODS_DIR", Path.Combine(root, "gamefolder", "mods"));
                    Check("S2A_MODS_DIR 优先于 S2A_DOCS", Path.Combine(root, "gamefolder", "mods"), RomFsMods.ModsDir() ?? "null");
                    Environment.SetEnvironmentVariable("S2A_MODS_DIR", null);
                    Environment.SetEnvironmentVariable("S2A_DOCS", null);
                    Check("Mac 没有 S2A_DOCS → 不启用（不碰用户文稿夹）", "null", RomFsMods.ModsDir() ?? "null");
                }
                finally { Environment.SetEnvironmentVariable("S2A_DOCS", was); Environment.SetEnvironmentVariable("S2A_MODS_DIR", null); }
            }
            finally
            {
                Red.Strict = strict;
                Red.Log = redLog;
                RomFsMods.Log = modLog;
                if (Directory.Exists(root)) Directory.Delete(root, true);
            }
            return failures == 0 ? 0 : 1;
        }
    }

    // 夹具：按形态建一份程序目录（期望值不跑被测实现：文件是「长度 × 一个字节值」，索引清单按覆盖层后的长度手写）
    static class RomFsModsFixture
    {
        internal static void Put(string dir, string rel, int len, byte v)
        {
            string p = Path.Combine(dir, rel);
            Directory.CreateDirectory(Path.GetDirectoryName(p));
            byte[] data = new byte[len];
            Array.Fill(data, v);
            File.WriteAllBytes(p, data);
        }

        // 目录形态：romfs/ + romfs.s2aidx（+ ui_overlay/romfs/）；镜像形态：romfs.img + romfs.imgmap + romfs.s2aidx（+ romfs_overlay/，覆盖层文件不进镜像、对照表记 -1），没有 romfs/。
        //   索引同出包：按清单（覆盖层的文件记覆盖层长度）建（pack/orch/stages.py _romfsidx）
        internal static void MakeProgram(string program, IReadOnlyDictionary<string, (int Len, byte V)> files, bool image, IReadOnlyDictionary<string, (int Len, byte V)> overlay = null)
        {
            string rom = Path.Combine(program, "romfs"), index = Path.Combine(program, RomFsIndex.FileName), list = Path.Combine(program, "romfs_list.tsv");
            foreach ((string rel, (int len, byte v)) in files) Put(rom, rel, len, v);
            StringBuilder sb = new();
            foreach ((string rel, (int len, _)) in files) sb.Append(overlay != null && overlay.TryGetValue(rel, out var o) ? o.Len : len).Append('\t').Append(rel).Append('\n');
            File.WriteAllText(list, sb.ToString(), new UTF8Encoding(false));
            RomFsIndex.Write(rom, index, list);
            File.Delete(list);
            string overDir = Path.Combine(program, image ? RomFsIndex.ImageOverlayDir : Path.Combine("ui_overlay", "romfs"));
            if (overlay != null) foreach ((string rel, (int len, byte v)) in overlay) Put(overDir, rel, len, v);
            if (!image) return;

            // 按索引格式手工拼镜像（同 RomFsImageTest），镜像布局下机上没有 romfs/
            byte[] idx = File.ReadAllBytes(index);
            int nf = BitConverter.ToInt32(idx, 16), p = 20, pathBase = 20 + nf * 24 + 4;
            long[] offsets = new long[nf];
            using (FileStream img = File.Create(Path.Combine(program, RomFsIndex.ImageName)))
            {
                for (int i = 0; i < nf; i++, p += 24)
                {
                    string rel = Encoding.UTF8.GetString(idx, pathBase + BitConverter.ToInt32(idx, p + 16), BitConverter.ToInt32(idx, p + 20));
                    if (overlay != null && overlay.ContainsKey(rel)) { offsets[i] = -1; continue; }
                    offsets[i] = img.Position;
                    img.Write(File.ReadAllBytes(Path.Combine(rom, rel)));
                }
            }
            using (BinaryWriter map = new(File.Create(Path.Combine(program, RomFsIndex.ImageMapName))))
            {
                map.Write("S2ARIM01"u8);
                map.Write(new FileInfo(Path.Combine(program, RomFsIndex.ImageName)).Length);
                map.Write(nf);
                foreach (long o in offsets) map.Write(o);
            }
            Directory.Delete(rom, true);
        }

        // 同 Application.Register 的两条：镜像 → RomFsIndex.OpenImage；目录 → RomFsIndex.Open（带 ui_overlay/romfs）
        internal static IStorage Open(string program, bool image) => image
            ? RomFsIndex.OpenImage(program)
            : RomFsIndex.Open(Path.Combine(program, "romfs"), Path.Combine(program, RomFsIndex.FileName), Path.Combine(program, "ui_overlay", "romfs"));
    }
}
