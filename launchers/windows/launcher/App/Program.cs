// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Themes.Fluent;
using Avalonia.Styling;
using Avalonia.Threading;

namespace S2Arm.Launcher;

internal static class Program
{
    [STAThread]
    public static void Main(string[] args)
    {
        // 全局兜底：任何没接住的异常都不许悄悄把启动器带走（玩家反馈：填了游戏库目录点「连接或创建游戏库」直接闪退、没有任何提示）。
        //   界面线程上的（Dispatcher）记日志、在窗口顶部报出来、继续运行；后台任务没人等的异常记日志并标为已观察；
        //   别的线程上的致命异常 .NET 不允许拦下，至少留下日志，下次能查。
        AppDomain.CurrentDomain.UnhandledException += (_, e) => LauncherCrash.Log(e.ExceptionObject as Exception, "fatal");
        TaskScheduler.UnobservedTaskException += (_, e) => { LauncherCrash.Log(e.Exception, "unobserved task"); e.SetObserved(); };
        // 退出各步记进 update.log（更新让位给安装程序时，旧进程停在哪一步要看得见）
        AppDomain.CurrentDomain.ProcessExit += (_, _) => EnvironmentWindow.ExitLog("进程退出（ProcessExit）");
        var rc = AppBuilder.Configure<LauncherApp>().UsePlatformDetect().LogToTrace().StartWithClassicDesktopLifetime(args);
        EnvironmentWindow.ExitStep = "界面循环已返回：等进程退出";
        EnvironmentWindow.ExitLog($"界面循环返回（退出码 {rc}）");
    }
}

/// <summary>启动器自己的崩溃日志：私有目录 logs/launcher-crash.log（追加，超过 1 MB 从头写）。写不了就算了，绝不再抛。</summary>
internal static class LauncherCrash
{
    public static string LogPath => Path.Combine(EnvironmentWindow.PrivateRootForLogs(), "logs", "launcher-crash.log");

    public static string Log(Exception? error, string where)
    {
        var path = LogPath;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var append = !File.Exists(path) || new FileInfo(path).Length < 1 << 20;
            using var writer = new StreamWriter(path, append);
            writer.WriteLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {where}: {error}");
        }
        catch (Exception) { }
        return path;
    }
}

public sealed class LauncherApp : Application
{
    public override void Initialize()
    {
        RequestedThemeVariant = ThemeVariant.Dark;
        Styles.Add(new FluentTheme());
    }
    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var window = new EnvironmentWindow();
            desktop.MainWindow = window;
            desktop.Exit += (_, _) => { EnvironmentWindow.ExitStep = "应用退出：界面循环收尾"; EnvironmentWindow.ExitLog($"应用退出（还开着 {desktop.Windows.Count} 个窗口）"); };
            Dispatcher.UIThread.UnhandledException += (_, e) =>
            {
                var path = LauncherCrash.Log(e.Exception, "ui");
                e.Handled = true;
                window.ReportUnexpected(e.Exception, path);
            };
        }
        base.OnFrameworkInitializationCompleted();
    }
}
