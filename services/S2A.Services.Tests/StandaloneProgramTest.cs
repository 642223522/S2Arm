using System;
using System.Buffers.Binary;
using System.IO;
using Ryujinx.Audio.Backends.Dummy;
using Ryujinx.HLE.HOS.SystemState;
using Ryujinx.Horizon.Sdk.Arp;

namespace S2A.Services.Tests
{
    // 单独导出的程序 n（#1567：一款 Switch 2 版游戏 0400453019AA8001，NUP 里只有这一支程序、放在数据根）：目录槽 0、程序身份序号 1。
    //   期望按规则手写（不跑被测实现推）：
    //   ① Switch 2 布局、程序号末位 1、数据根单独一支：Application.ProgramIndex 1、进程身份 ProgramIndex 1、ARP 进程属性 ProgramIndex 1、
    //      fs 205 别名序号 0（S2AHooks.DataStorageAliasIndex）、不报红
    //   ③ StandaloneProgram 真值表：根下还有 programs/ → 否；目录槽不是 0 → 否；末位 0 → 否；不是 Switch 2（如自制程序 …100D，末位不是序号）→ 否
    public static unsafe partial class Program
    {
        [SoloTest("--standalone-program")]
        private static int StandaloneProgramTest()
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_standalone_program_{Environment.ProcessId}");
            bool ok = true;
            void Row(string what, string want, string got)
            {
                bool pass = want == got; ok &= pass;
                Console.WriteLine($"{what}：期望 {want} → 真结果 {got} {(pass ? "✓" : "✗")}");
            }
            try
            {
                byte[] s1 = File.ReadAllBytes(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm")));
                FakeNative.Install();
                string state = Path.Combine(root, "state");
                string game = Path.Combine(root, "game");
                Directory.CreateDirectory(Path.Combine(game, "exefs")); Directory.CreateDirectory(Path.Combine(game, "ctl")); Directory.CreateDirectory(Path.Combine(game, "romfs"));
                File.WriteAllBytes(Path.Combine(game, "ctl", "control.nacp"), new byte[0x4000]);
                AttachTestTimeZone(game);
                var config = new HostConfiguration(game, state, SystemLanguage.AmericanEnglish, RegionCode.USA, "UTC", false, new HostUi());
                Host.Boot(new StubRenderer(), new DummyHardwareDeviceDriver(), state, config);
                Host.Device.System.ServiceTable.WaitServicesReady();
                IWriter writer = Host.Device.System.ServiceTable.ArpWriter;
                IReader reader = Host.Device.System.ServiceTable.ArpReader;

                // ① Switch 2 布局（同 --npdm-switch2 的展开法），ACI0 程序号改成 …8001
                byte[] p1 = (byte[])s1.Clone();
                int aci = (int)BinaryPrimitives.ReadUInt32LittleEndian(p1.AsSpan(0x70));
                BinaryPrimitives.WriteUInt64LittleEndian(p1.AsSpan(aci + 0x10), 0x0400453019AA8001UL);
                File.WriteAllBytes(Path.Combine(game, "exefs", "main.npdm"), ToSwitch2(p1));
                long red0 = Red.Total;
                Application.Register(Host.Device, game);
                reader.GetApplicationInstanceId(out ulong id, FakeNative.GamePid);
                reader.GetApplicationProcessProperty(out ApplicationProcessProperty prop, id);
                Host.Device.Processes.TryGetProcess(FakeNative.GamePid, out var proc);
                Row("① Switch 2 单独导出的程序 1：程序号 / 身份序号 / 进程身份 / ARP / 别名 / 报红",
                    "0400453019AA8001 / 1 / 1 / 1 / 0 / +0",
                    $"{Application.ProgramId:X16} / {Application.ProgramIndex} / {proc?.Identity.ProgramIndex} / {prop.ProgramIndex} / {Ryujinx.HLE.S2AHooks.DataStorageAliasIndex} / +{Red.Total - red0}");

                // ③ 真值表
                bool alone = Application.StandaloneProgram(game, 0, 1, true);
                Directory.CreateDirectory(Path.Combine(game, "programs"));
                Row("③ 单独 / 有 programs/ / 目录槽 1 / 末位 0 / 非 Switch 2", "True / False / False / False / False",
                    $"{alone} / {Application.StandaloneProgram(game, 0, 1, true)} / {Application.StandaloneProgram(game, 1, 1, true)} / " +
                    $"{Application.StandaloneProgram(game, 0, 0, true)} / {Application.StandaloneProgram(game, 0, 1, false)}");
            }
            catch (Exception e) { ok = false; Console.WriteLine($"抛出 {e.GetType().Name}: {e.Message}"); }
            finally { Application.Reset(); Application.GameDir = null; try { Directory.Delete(root, true); } catch { } }
            Console.WriteLine($"单独导出的程序 n：{(ok ? "全过 ✓" : "有不符 ✗")}");
            Environment.Exit(ok ? 0 : 1);   // 起过 Horizon 服务线程（前台线程），同 --multi-program 显式退出
            return ok ? 0 : 1;
        }

        // Switch 1 布局 npdm → Switch 2 布局（展开法同 NpdmSwitch2Test）
        private static byte[] ToSwitch2(byte[] s1)
        {
            int aci = (int)BinaryPrimitives.ReadUInt32LittleEndian(s1.AsSpan(0x70)), acid = (int)BinaryPrimitives.ReadUInt32LittleEndian(s1.AsSpan(0x78));
            int acidSize = (int)BinaryPrimitives.ReadUInt32LittleEndian(s1.AsSpan(0x7C));
            byte[] s2 = new byte[s1.Length + 0x100];
            s1.AsSpan(0, acid).CopyTo(s2);
            s1.AsSpan(acid, acidSize).CopyTo(s2.AsSpan(acid + 0x100));
            s1.AsSpan(acid + acidSize).CopyTo(s2.AsSpan(acid + acidSize + 0x100));
            Span<byte> a = s2.AsSpan(acid, acidSize + 0x100);
            BinaryPrimitives.WriteUInt32LittleEndian(a.Slice(0x304), (uint)(acidSize + 0x100 - 0x180));
            foreach (int f in new[] { 0x320, 0x328, 0x330 })
            {
                uint v = BinaryPrimitives.ReadUInt32LittleEndian(a.Slice(f));
                if (v >= 0x100) BinaryPrimitives.WriteUInt32LittleEndian(a.Slice(f), v + 0x100);
            }
            BinaryPrimitives.WriteUInt32LittleEndian(s2.AsSpan(0x7C), (uint)(acidSize + 0x100));
            if (aci > acid) BinaryPrimitives.WriteUInt32LittleEndian(s2.AsSpan(0x70), (uint)(aci + 0x100));
            return s2;
        }
    }
}
