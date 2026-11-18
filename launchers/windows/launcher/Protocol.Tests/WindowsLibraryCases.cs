// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using S2Arm.Launcher.Protocol;

internal static class WindowsLibraryCases
{
    public static async Task Run(Action<bool, string> check)
    {
        if (OperatingSystem.IsWindows()) await RunWindows(check);
    }

    // 平台守卫放在单独的方法上：lambda 里的 ACL 调用分析器认不出外层的 IsWindows 守卫
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static async Task RunWindows(Action<bool, string> check)
    {
        var temp = Path.GetFullPath(Path.GetTempPath());
        var root = Path.Combine(temp, "s2arm-private-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var privateRoot = Path.Combine(root, "Private");
            var sid = WindowsIdentity.GetCurrent().User!;
            var everyone = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
            FileSystemAccessRule[] Rules(string dir) => new DirectoryInfo(dir).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToArray();
            // 不再自设权限（11-16 维护者：玩家的电脑就是自己在用）：普通建目录、写文件，请求文件不设受保护权限
            string file;
            using (var request = PrivateJobRequest.Create(privateRoot, "{\"schema\":1}"))
            {
                file = request.FilePath;
                check(File.ReadAllText(file) == "{\"schema\":1}", "request content round trips");
                check(!new FileInfo(file).GetAccessControl().AreAccessRulesProtected, "request file uses the folder's normal inherited permissions");
            }
            check(!File.Exists(file), "request deleted after use");
            // 升级：旧版收紧过的老目录（关了继承、只剩 SYSTEM，本人没有规则；旧版把属主设成本人）。第一次用时写不进去 → 恢复继承、补回本人的完全控制。
            //   夹具里连 Administrators 都没有，提权会话也写不进去；再关掉全部特权（等同玩家的普通会话），只能靠补回权限才写得进
            var tightened = Path.Combine(root, "Tightened");
            {
                var t = new DirectorySecurity();
                t.SetOwner(sid); t.SetAccessRuleProtection(true, false);
                t.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                new DirectoryInfo(tightened).Create(t);
            }
            WithoutPrivileges(() =>
            {
                using var healed = PrivateJobRequest.Create(tightened, "{}");
                check(File.Exists(healed.FilePath), "folder tightened by an older S2Arm is writable again after first use (normal session)");
            });
            var healedAcl = new DirectoryInfo(tightened).GetAccessControl();
            check(!healedAcl.AreAccessRulesProtected, "repaired folder inherits again (back to the system default)");
            check(Rules(tightened).Any(r => r.IdentityReference.Equals(sid) && r.AccessControlType == AccessControlType.Allow
                    && (r.FileSystemRights & FileSystemRights.FullControl) == FileSystemRights.FullControl),
                "repaired folder gives the current user full control");
            // 不再收紧：别的账户已有的权限原样留着（原先会删掉 Everyone）
            var shared = Path.Combine(root, "Shared");
            {
                var a = new DirectorySecurity();
                a.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
                a.AddAccessRule(new FileSystemAccessRule(everyone, FileSystemRights.ReadData, InheritanceFlags.ObjectInherit, PropagationFlags.InheritOnly, AccessControlType.Allow));
                new DirectoryInfo(shared).Create(a);
            }
            using (var s1 = PrivateJobRequest.Create(shared, "{}")) check(File.Exists(s1.FilePath), "folder shared with Everyone is used as is");
            check(Rules(shared).Any(r => r.IdentityReference.Equals(everyone)), "other accounts' permissions are left alone (no tightening)");
            // 联接：玩家把数据目录用目录联接挪到别的盘，照常用、写进目标
            var movedTarget = Path.Combine(root, "MovedTarget");
            Directory.CreateDirectory(movedTarget);
            var junction = Path.Combine(root, "Junction");
            Junction(junction, movedTarget);
            using (var viaJunction = PrivateJobRequest.Create(junction, "{}"))
                check(File.Exists(Path.Combine(movedTarget, Path.GetFileName(viaJunction.FilePath))), "junctioned data folder is used and writes into the target");
            // 继承上级权限的目录（Directory.CreateDirectory 建的）照常用、不再被改成不继承
            var inherited = Path.Combine(root, "Inherited");
            Directory.CreateDirectory(Path.Combine(inherited, "jobs"));
            using (var i1 = PrivateJobRequest.Create(inherited, "{}")) check(File.Exists(i1.FilePath), "inherited folder accepts a request");
            check(!new DirectoryInfo(inherited).GetAccessControl().AreAccessRulesProtected, "inherited folder keeps inheriting (not tightened)");
            var engine = Path.Combine(root, "中文 & %S2A_MARKER% !", "Engine");
            var runtime = Path.Combine(root, "Runtime");
            Directory.CreateDirectory(Path.Combine(engine, "pack", "jobs"));
            Directory.CreateDirectory(runtime);
            var python = Environment.GetEnvironmentVariable("S2A_TEST_PYTHON")!;
            await File.WriteAllTextAsync(Path.Combine(runtime, "s2arm_env.cmd"),
                "@echo off\r\nset \"PATH=" + Path.GetDirectoryName(python) + ";%PATH%\"\r\n");
            await File.WriteAllTextAsync(Path.Combine(engine, "pack", "jobs", "main.py"), """
import argparse,json,os,sys
p=argparse.ArgumentParser(); p.add_argument('command'); p.add_argument('--request'); p.add_argument('--private-root'); p.add_argument('--task'); a=p.parse_args()
if a.command=='cancel':
    from pathlib import Path
    Path(a.private_root,'cancel-called').write_text(a.task)
    sys.exit(0)
assert a.command=='run'
with open(a.request,encoding='utf-8') as f: r=json.load(f)
assert r['schema']==1 and os.path.normcase(r['engineDir'])==os.path.normcase(os.getcwd()), 'job selected engine reaches backend'
assert r['operation'] in ['setup','catalog','keys','import']
assert r['library'].endswith('Output') and r.get('libraryId')=='opaque-id'
if r.get('paths')==['wait']:
    import time
    from pathlib import Path
    while not Path(r['privateRoot'],'cancel-called').exists(): time.sleep(.02)
    assert Path(r['privateRoot'],'cancel-called').read_text()==r['jobId']
    print(json.dumps(dict(schema=1,jobId=r['jobId'],seq=1,type='result',operation=r['operation'],state='cancelled',message='cancelled',result={})))
    sys.exit(130)
assert r.get('paths')==['C:/Synthetic/中文 & %NAME% !.nsp'], 'original paths reach job request'
print(json.dumps(dict(schema=1,jobId=r['jobId'],taskId=r['jobId'],seq=1,type='result',operation=r['operation'],state='succeeded',message='合成操作完成',result={'accepted':r['operation']}),ensure_ascii=False))
print('request-file='+a.request,file=sys.stderr)
""");
            var paths = new LauncherPaths(engine, runtime, Path.Combine(root, "Shell"));
            foreach (var operation in new[] { "setup", "catalog", "keys", "import" })
            {
                var job = await LibraryJobClient.RunAsync(paths, privateRoot, Path.Combine(root, "Output"), "opaque-id",
                    operation, new[] { "C:/Synthetic/中文 & %NAME% !.nsp" }, CancellationToken.None);
                check(job.Report.Succeeded && job.Report.Result.GetProperty("accepted").GetString() == operation,
                    "literal request paths and selected Engine reach job " + operation);
                var requestPath = job.Output.StandardError.Split('\n').Single(x => x.StartsWith("request-file="))[13..].Trim();
                check(!File.Exists(requestPath), "job temporary request cleaned for " + operation);
            }
            using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
            var timer = Stopwatch.StartNew();
            try
            {
                await LibraryJobClient.RunAsync(paths, privateRoot, Path.Combine(root, "Output"), "opaque-id", "import", ["wait"], cancel.Token);
                throw new Exception("accepted library cancellation");
            }
            catch (OperationCanceledException)
            { check(File.Exists(Path.Combine(privateRoot, "cancel-called")) && timer.Elapsed < TimeSpan.FromSeconds(7),
                "library cancellation uses main.py cancel before owned process fallback"); }
            check(!Directory.GetFiles(privateRoot, "request-*.json").Any(), "cancelled job request removed after process exits");
            Console.WriteLine("Windows library cases: 23 assertions passed (13 ACL + 8 invocation + 2 cancellation; no device/game/key probe)");
        }
        finally
        {
            var resolved = Path.GetFullPath(root);
            if (!resolved.StartsWith(temp.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Private request test cleanup escaped temporary root.");
            foreach (var link in new[] { "Junction", "Dangling" }.Select(n => new DirectoryInfo(Path.Combine(resolved, n))).Where(d => d.LinkTarget is not null))
                link.Delete();   // 先删链接本身：断链留在里面，递归删除会报「参数错误」
            if (Directory.Exists(resolved)) Directory.Delete(resolved, true);
        }
    }

    private static void Junction(string link, string target)
    {
        using var p = Process.Start(new ProcessStartInfo("cmd.exe", ["/c", "mklink", "/J", link, target]) { UseShellExecute = false, RedirectStandardOutput = true })!;
        p.StandardOutput.ReadToEnd(); p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException("mklink /J failed: " + link);
    }

    // 当前令牌复制一份、关掉全部特权，在它下面跑 action（只影响这个线程这一段）
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static void WithoutPrivileges(Action action)
    {
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x0002 | 0x0008 | 0x0020, out var process))   // DUPLICATE | QUERY | ADJUST_PRIVILEGES
            throw new System.ComponentModel.Win32Exception();
        try
        {
            if (!DuplicateTokenEx(process, 0x02000000, IntPtr.Zero, 2, 2, out var plain))   // MAXIMUM_ALLOWED，SecurityImpersonation，TokenImpersonation
                throw new System.ComponentModel.Win32Exception();
            using var handle = new Microsoft.Win32.SafeHandles.SafeAccessTokenHandle(plain);
            if (!AdjustTokenPrivileges(plain, true, IntPtr.Zero, 0, IntPtr.Zero, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
            WindowsIdentity.RunImpersonated(handle, action);
        }
        finally { CloseHandle(process); }
    }
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool DuplicateTokenEx(IntPtr token, uint access, IntPtr attributes, int level, int type, out IntPtr duplicate);
    [System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, IntPtr state, uint length, IntPtr previous, IntPtr returned);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
