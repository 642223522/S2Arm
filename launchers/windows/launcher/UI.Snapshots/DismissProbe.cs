// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 控制口 /dismiss（s2armctl dismiss「关掉提示框」）关得掉弹窗：全新窗口，经真实入口 HandleControl 发 POST /dismiss。期望手写：
//   ① 新功能大窗开着 → 关掉（updatePopup 为空、不再是大窗）；② 更新弹窗开着 → 关掉；③ 只有导入报错 → 报错清空（原有行为）。
// 负对照：/dismiss 只清报错、不碰弹窗（修前），① ② 不通。调用方核退出码 0 和末行「✓」。
using System.Reflection;
using System.Text;
using System.Text.Json;
using Avalonia.Headless;
using Avalonia.Threading;
using S2Arm.Launcher;
using S2Arm.Launcher.Protocol;

static class DismissProbe
{
    public static int Run(string outDir)
    {
        Directory.CreateDirectory(outDir);
        int fails = 0;
        // 大窗要有页才画得出来（没页 Render 会自己关掉，测不出 /dismiss）：用仓库里随包的新功能海报做一页
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "docs", "site", "feature.json"))) dir = dir.Parent;
        var image = dir is null ? throw new InvalidOperationException("找不到仓库里的 docs/site/feature.json")
            : Directory.GetFiles(Path.Combine(dir.FullName, "docs", "site", "feature"), "*.jpg").OrderBy(x => x, StringComparer.Ordinal).First();
        var feature = JsonSerializer.SerializeToElement(new Dictionary<string, object>
        {
            ["kind"] = "feature", ["id"] = "v0.0.0-probe", ["badge"] = new Dictionary<string, string> { ["zh-Hans"] = "探针", ["en"] = "probe" },
            ["pages"] = new[] { new Dictionary<string, object> { ["image"] = new Dictionary<string, string> { ["zh-Hans"] = image, ["en"] = image } } },
        });
        var update = JsonDocument.Parse("""{"kind":"update","version":"99.0.0"}""").RootElement.Clone();
        var cases = new (string Name, JsonElement? Popup, string ImportError)[]
        {
            ("新功能大窗开着", feature, ""),
            ("更新弹窗开着", update, ""),
            ("只有导入报错", null, "probe import error"),
        };
        foreach (var (name, popup, importError) in cases)
        {
            Exception? error = null;
            DispatcherUnhandledExceptionEventHandler trap = (_, e) => { error ??= e.Exception; e.Handled = true; };
            Dispatcher.UIThread.UnhandledException += trap;
            var w = new EnvironmentWindow { Width = 1280, Height = 900 };
            try
            {
                w.Show(); Dispatcher.UIThread.RunJobs();
                SetW(w, "updatePopup", popup); SetW(w, "importError", importError);
                CallW(w, "Render"); Dispatcher.UIThread.RunJobs();
                if (popup is not null && GetW(w, "updatePopup") is null) throw new InvalidOperationException("前提不成立：发 /dismiss 之前弹窗就没开着");
                var request = ControlRequest.Parse(Encoding.UTF8.GetBytes("POST /dismiss HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"))
                    ?? throw new InvalidOperationException("请求解析不出");
                var task = (Task<ControlReply>)CallW(w, "HandleControl", request)!;
                while (!task.IsCompleted) Dispatcher.UIThread.RunJobs();
                Dispatcher.UIThread.RunJobs();
                if (task.Result.Code != 200) throw new InvalidOperationException($"/dismiss 回 {task.Result.Code}");
                if (GetW(w, "updatePopup") is JsonElement left) throw new InvalidOperationException($"弹窗还开着（kind={left.GetProperty("kind").GetString()}）");
                if ((string)GetW(w, "importError")! != "") throw new InvalidOperationException("导入报错没清掉");
            }
            catch (Exception e) { error ??= e is TargetInvocationException { InnerException: { } inner } ? inner : e; }
            finally { Dispatcher.UIThread.UnhandledException -= trap; try { w.Close(); Dispatcher.UIThread.RunJobs(); } catch (Exception) { } }
            if (error is null) Console.WriteLine($"通 {name}：/dismiss 后关掉了");
            else { fails++; Console.WriteLine($"不通 {name}：{error.GetType().Name}: {error.Message}"); }
        }
        Console.WriteLine($"{(fails == 0 ? "✓" : "✗")} 控制口 dismiss 关弹窗：{cases.Length} 例，不通 {fails}");
        return fails == 0 ? 0 : 1;
    }

    static void SetW(object obj, string field, object? value) =>
        (obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMemberException(field)).SetValue(obj, value);

    static object? GetW(object obj, string field) =>
        (obj.GetType().GetField(field, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMemberException(field)).GetValue(obj);

    static object? CallW(object obj, string method, params object[] args) =>
        (obj.GetType().GetMethod(method, BindingFlags.NonPublic | BindingFlags.Instance) ?? throw new MissingMethodException(method)).Invoke(obj, args);
}
