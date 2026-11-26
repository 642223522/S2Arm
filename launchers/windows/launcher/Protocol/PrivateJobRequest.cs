// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace S2Arm.Launcher.Protocol;

// 作业请求文件：放在启动器自己的数据目录（%LOCALAPPDATA%\S2Arm\…，系统缺省就只归当前用户）里，普通建目录、写文件，不再自设权限。
//   11-16 维护者：「玩家的电脑就是自己在用，干嘛搞这么多权限给自己设置一堆阻碍？」原先建目录时改属主、关继承、删其他账户的规则、给请求文件设受保护权限，
//   目录先由别的进程建时把本人的写权限也删了，普通运行（UAC 下 Administrators 只能用来拒绝）点「添加游戏」直接拒绝访问。
//   旧版收紧过的老目录：第一次用时写不进去，就给本人补回完全控制并恢复继承（旧版把属主设成了本人，补得上）；补不上照实抛，界面换成平实说明
public sealed class PrivateJobRequest : IDisposable
{
    public string FilePath { get; }
    private PrivateJobRequest(string path) => FilePath = path;

    /// <summary>补回权限时记一笔（启动器起来时接到自己的日志；缺省不记）</summary>
    public static Action<string> Note { get; set; } = _ => { };

    private static readonly HashSet<string> Checked = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>建好数据目录；这个进程第一次用到它时核一次能不能写，旧版收紧过、写不进去就给本人补回权限</summary>
    public static void EnsurePrivateRoot(string privateRoot)
    {
        var path = Path.GetFullPath(privateRoot);
        Directory.CreateDirectory(path);
        lock (Checked)
        {
            if (!Checked.Add(path)) return;
        }
        if (OperatingSystem.IsWindows() && !CanWrite(path)) RestoreOwnAccess(path);
    }

    public static PrivateJobRequest Create(string privateRoot, string json)
    {
        EnsurePrivateRoot(privateRoot);
        var path = Path.Combine(Path.GetFullPath(privateRoot), "request-" + Guid.NewGuid().ToString("N") + ".json");
        var created = false;
        try
        {
            using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            created = true;
            file.Write(Encoding.UTF8.GetBytes(json));
            file.Flush(flushToDisk: true);
            return new(path);
        }
        catch { if (created) File.Delete(path); throw; }
    }

    private static bool CanWrite(string directory)
    {
        var probe = Path.Combine(directory, ".s2arm-write-" + Guid.NewGuid().ToString("N"));
        try
        {
            using (new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose)) { }
            return true;
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException) { return false; }
    }

    /// <summary>旧版收紧过的目录：恢复继承（回到系统缺省、跟上级一样），再加一条本人的可继承完全控制。属主是本人时隐含改权限的权利，补得上；
    /// 补不上（属主是别的账户、本人也没有改权限的权利）不再报自设的提示，照常往下走、真写不进去时由调用方报「这个位置写不进去」</summary>
    [SupportedOSPlatform("windows")]
    private static void RestoreOwnAccess(string path)
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var directory = new DirectoryInfo(path);
            var acl = directory.GetAccessControl();
            acl.SetAccessRuleProtection(isProtected: false, preserveInheritance: true);
            acl.AddAccessRule(new FileSystemAccessRule(identity.User!, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            directory.SetAccessControl(acl);
            Note($"data folder was not writable (tightened by an older S2Arm); restored this account's access: {path}");
        }
        catch (Exception e) when (e is UnauthorizedAccessException or InvalidOperationException or PrivilegeNotHeldException or IOException)
        {
            Note($"data folder is not writable and access could not be restored: {path} {e.Message}");
        }
    }

    public void Dispose() => File.Delete(FilePath);
}
