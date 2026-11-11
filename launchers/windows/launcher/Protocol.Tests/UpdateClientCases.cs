// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using System.Text.Json;
using S2Arm.Launcher.Protocol;

// 超时要连子进程一起结束：假 updater.py 先打一行 JSON、记下自己的进程号，然后长睡；
// 期望：1 秒超时返回那一行，返回时这个进程已经不在（不在后台继续下载）。
public static class UpdateClientCases
{
    public static async Task Run(Action<bool, string> check)
    {
        var python = FindPython();
        if (python is null) { Console.WriteLine("update timeout: 找不到 Python，这条没跑"); return; }
        var root = Directory.CreateTempSubdirectory("s2a-update-timeout").FullName;
        try
        {
            var engine = Path.Combine(root, "engine"); var runtime = Path.Combine(root, "runtime");
            Directory.CreateDirectory(Path.Combine(engine, "pack", "jobs"));
            Directory.CreateDirectory(Path.Combine(runtime, "python"));
            var exe = Path.Combine(runtime, "python", "python.exe");
            if (OperatingSystem.IsWindows()) File.Copy(python, exe); else File.CreateSymbolicLink(exe, python);
            var pidFile = Path.Combine(root, "pid");
            File.WriteAllText(Path.Combine(engine, "pack", "jobs", "updater.py"),
                "import json, os, sys, time\n" +
                $"open({JsonSerializer.Serialize(pidFile)}, 'w').write(str(os.getpid()))\n" +
                "print(json.dumps({'state': 'downloading', 'done': 1, 'total': 2}), flush=True)\n" +
                "time.sleep(60)\n");
            var clock = Stopwatch.StartNew();
            var last = await UpdateClient.RunAsync(new LauncherPaths(engine, runtime, root), ["prepare"], null, TimeSpan.FromSeconds(1));
            check(clock.Elapsed < TimeSpan.FromSeconds(20), "update timeout: returns at the limit, not after the script");
            check(last is { } line && line.GetProperty("state").GetString() == "downloading", "update timeout: last JSON line kept");
            var pid = int.Parse(File.ReadAllText(pidFile));
            var alive = true;
            try { using var p = Process.GetProcessById(pid); alive = !p.HasExited; }
            catch (ArgumentException) { alive = false; }
            check(!alive, "update timeout: script process ended with the timeout");
        }
        finally { Directory.Delete(root, true); }
    }

    private static string? FindPython() =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Select(d => Path.Combine(d, OperatingSystem.IsWindows() ? "python.exe" : "python3")).FirstOrDefault(File.Exists);
}
