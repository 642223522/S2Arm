using System;
using System.IO;
using Ryujinx.Horizon.Sdk.Arp;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        // ProgramId in the existing Homebrew.npdm ACI0, not a value returned by Application.Register.
        private const ulong HomebrewFixtureProgramId = 0x010000000000100D;

        private static void WriteApplicationFixture(string root)
        {
            Directory.CreateDirectory(Path.Combine(root, "exefs"));
            Directory.CreateDirectory(Path.Combine(root, "ctl"));
            Directory.CreateDirectory(Path.Combine(root, "romfs"));
            string fixture = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
                "../../../../../compat/tree/src/Ryujinx.HLE/Homebrew.npdm"));
            File.Copy(fixture, Path.Combine(root, "exefs", "main.npdm"));
            byte[] nacp = new byte[0x4000]; nacp[0] = 0x53;
            File.WriteAllBytes(Path.Combine(root, "ctl", "control.nacp"), nacp);
        }

        private static void ArpApplicationTest(bool exerciseLdn = false, bool capacity = false)
        {
            string root = Path.Combine(Path.GetTempPath(), $"s2a_arp_test_{Environment.ProcessId}");
            try
            {
                WriteApplicationFixture(root);
                Host.Device.System.ServiceTable.WaitServicesReady();
                IWriter writer = Host.Device.System.ServiceTable.ArpWriter;
                IReader reader = Host.Device.System.ServiceTable.ArpReader;
                var reserve = writer.AcquireRegistrar(out IRegistrar reserved);
                var issue = reserved.Issue(out ulong reservedId);
                if (capacity)
                {
                    var reserveSecond = writer.AcquireRegistrar(out IRegistrar second);
                    bool failed = false;
                    try { Application.Register(Host.Device, root); }
                    catch (Ryujinx.Horizon.Common.InvalidResultException) { failed = true; }
                    Check("ARP 无空实例：真实登记明确报告结果错误", "True / True", $"{reserve.IsSuccess && issue.IsSuccess && reserveSecond.IsSuccess && second != null} / {failed}");
                    return;
                }
                Application.Register(Host.Device, root);
                var lookup = reader.GetApplicationInstanceId(out ulong id, FakeNative.GamePid);
                var controlResult = reader.GetApplicationControlProperty(out var control, id);
                var processResult = reader.GetApplicationProcessProperty(out _, id);
                byte first = *(byte*)&control;
                Check("ARP 真实应用登记：已有实例时 PID 与控制属性绑定新实例", "True / 0 / True / 1 / True / True / 83",
                    $"{reserve.IsSuccess && issue.IsSuccess} / {reservedId} / {lookup.IsSuccess} / {id} / {controlResult.IsSuccess} / {processResult.IsSuccess} / {first}");
                if (exerciseLdn)
                {
                    if (!Host.Device.Processes.TryGetProcess(FakeNative.GamePid, out var before))
                        throw new InvalidOperationException("Application.Register did not register the LDN caller");
                    Check("LDN 已有元数据前提：真实应用登记的 PID / ProgramId", "0x51 / 0x10000000000100D",
                        $"0x{before.ProcessId:X} / 0x{before.ProgramId:X}");
                    System.Text.Encoding.ASCII.GetBytes("sm:\0").CopyTo(new Span<byte>(_game, 4));
                    uint sm = (uint)Svc(0x1F, 0, 0, (ulong)_game).Item2[1];
                    LdnAutoLan(sm);
                    FakeNative.HandleClose(sm);
                    bool present = Host.Device.Processes.TryGetProcess(FakeNative.GamePid, out var after);
                    Check("LDN 缺项负测后：保留原 ProcessResult 身份及 ProgramId", $"True / 0x{HomebrewFixtureProgramId:X}",
                        present ? $"{ReferenceEquals(before, after)} / 0x{after.ProgramId:X}" : "进程元数据丢失");
                }
            }
            finally { try { Directory.Delete(root, true); } catch { } }
        }
    }
}
