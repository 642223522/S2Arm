// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using LibHac.Fs;
using LibHac.Tools.FsSystem.RomFs;
using System;
using System.Collections.Generic;
using System.IO;
using Path = System.IO.Path;

namespace S2A.Services.Tests
{
    // 资源替换类 mod 的起局接线（Application.cs 三处 RomFsMods.ApplyAtLaunch，丢一处只测 RomFsMods.Apply 查不出来）：
    //   设 S2A_DOCS → 真 Application.Register → fs 拿到的那份（VirtualFileSystem.GetRomFs）读到 mod 内容。三种形态各一个独立进程
    //   （一个进程只能真登记一次：显卡侧 RegisterProcess 同 pid 第二次抛异常，见 docs/坑记录.md「服务测试必须自行登记应用元数据」）。
    //   夹具同 PrepoSendTest：Homebrew.npdm + 空 NACP；RomFS 用 RomFsModsTest 的夹具（文件是「长度 × 字节值」）
    public static unsafe partial class Program
    {
        [SoloTest("--romfs-mods-register-dir", Booted = true)]
        private static void RomFsModsRegisterDir() => RomFsModsRegister(0);

        [SoloTest("--romfs-mods-register-image", Booted = true)]
        private static void RomFsModsRegisterImage() => RomFsModsRegister(1);

        [SoloTest("--romfs-mods-register-img", Booted = true)]
        private static void RomFsModsRegisterImg() => RomFsModsRegister(2);

        // form：0 目录 + 索引，1 单文件镜像（romfs.img），2 单一 IMG（game.img，夹具同 RomFsImgTest）
        private static void RomFsModsRegister(int kind)
        {
            string form = kind switch { 0 => "目录索引", 1 => "镜像", _ => "单一 IMG" };
            string root = Path.Combine(Path.GetTempPath(), $"s2a_romfs_mods_register_{Environment.ProcessId}");
            string game = Path.Combine(root, "game"), docs = Path.Combine(root, "docs");
            string was = Environment.GetEnvironmentVariable("S2A_DOCS");

            try
            {
                Directory.CreateDirectory(Path.Combine(game, "exefs"));
                Directory.CreateDirectory(Path.Combine(game, "ctl"));
                File.Copy(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm")), Path.Combine(game, "exefs", "main.npdm"));
                File.WriteAllBytes(Path.Combine(game, "ctl", "control.nacp"), new byte[0x4000]);
                var baseFiles = new Dictionary<string, (int, byte)> { ["a.bin"] = (100, 0x11), ["Data/b.bin"] = (200, 0x22) };
                if (kind < 2) RomFsModsFixture.MakeProgram(game, baseFiles, kind == 1);
                else
                {
                    string rom = Path.Combine(root, "img_src");
                    foreach ((string rel, (int len, byte v)) in baseFiles) RomFsModsFixture.Put(rom, rel, len, v);
                    WriteImgFixture(rom, Path.Combine(game, RomFsIndex.ImgName), 1, new List<string>(baseFiles.Keys));   // 机上没有 romfs/，只有 game.img
                }
                RomFsModsFixture.Put(Path.Combine(docs, RomFsMods.DirName), "m/romfs/a.bin", 50, 0xA1);
                RomFsModsFixture.Put(Path.Combine(docs, RomFsMods.DirName), "m/romfs/New/n.bin", 7, 0xB1);
                Environment.SetEnvironmentVariable("S2A_DOCS", docs);

                Host.Device.System.ServiceTable.WaitServicesReady();
                Application.Register(Host.Device, game);

                using IStorage s = Host.Device.Configuration.VirtualFileSystem.GetRomFs(Native.ProcessId());
                string Read(string path)
                {
                    var fs = new RomFsFileSystem(s);
                    if (!fs.FileTable.TryOpenFile(path, out RomFileInfo info)) return "没有";
                    byte[] b = new byte[info.Length];
                    var r = s.Read(fs.Header.DataOffset + info.Offset, b);
                    if (r.IsFailure()) return r.ToString();
                    return b.Length > 0 && Array.TrueForAll(b, x => x == b[0]) ? $"{b.Length}×0x{b[0]:X2}" : $"{b.Length} 内容不齐";
                }
                Check($"起局接线（{form}）：Register 后 fs 读到 mod 替换的文件", "50×0xA1", Read("/a.bin"));
                Check($"起局接线（{form}）：Register 后 fs 读到 mod 新增的文件", "7×0xB1", Read("/New/n.bin"));
                Check($"起局接线（{form}）：没替换的原包文件照读", "200×0x22", Read("/Data/b.bin"));
            }
            finally
            {
                Environment.SetEnvironmentVariable("S2A_DOCS", was);
                try { Directory.Delete(root, true); } catch { }
            }
        }
    }
}
