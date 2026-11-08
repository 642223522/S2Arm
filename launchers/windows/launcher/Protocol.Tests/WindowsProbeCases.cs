// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Diagnostics;
using S2Arm.Launcher.Protocol;

internal static class WindowsProbeCases
{
    public static async Task Run(Action<bool, string> check)
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.WriteLine("Windows process cases: NOT RUN (requires Windows)");
            return;
        }
        var python = Environment.GetEnvironmentVariable("S2A_TEST_PYTHON");
        if (string.IsNullOrWhiteSpace(python) || !File.Exists(python))
            throw new InvalidOperationException("Set S2A_TEST_PYTHON to an existing Python executable for process cases.");
        var tempBase = Path.GetFullPath(Path.GetTempPath());
        var root = Path.Combine(tempBase, "s2arm-launcher-" + Guid.NewGuid().ToString("N"));
        var folder = Path.Combine(root, "中文 & spaces %S2A_TEST_MARKER% !");
        var engine = Path.Combine(folder, "Engine");
        var runtime = Path.Combine(folder, "Runtime");
        var script = Path.Combine(engine, "pack", "jobs", "winenv.py");
        var previousPython = Environment.GetEnvironmentVariable("S2A_TEST_PY_DIR");
        var previousMarker = Environment.GetEnvironmentVariable("S2A_TEST_MARKER");
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(script)!);
            Directory.CreateDirectory(runtime);
            Environment.SetEnvironmentVariable("S2A_TEST_PY_DIR", Path.GetDirectoryName(python));
            Environment.SetEnvironmentVariable("S2A_TEST_MARKER", "MUST_NOT_EXPAND");
            await File.WriteAllTextAsync(Path.Combine(runtime, "s2arm_env.cmd"),
                "@echo off\r\nset \"PATH=%S2A_TEST_PY_DIR%;%PATH%\"\r\n");
            var paths = new LauncherPaths(engine, runtime, Path.Combine(folder, "Shell"));
            var start = EnvironmentProbe.StartInfo(paths, Path.Combine(folder, "request.json"));
            check(start.Environment["S2A_PREBUILT_TOOLS"] == Path.Combine(engine, "Binaries", "Prepare"),
                "selected Engine snapshot owns prepared tools, independent of Runtime");
            check(start.Environment.TryGetValue("S2A_ENGINE", out var selectedEngine) && selectedEngine == engine &&
                start.Environment.TryGetValue("S2A_FONTS", out var fonts) && fonts == Path.Combine(AppContext.BaseDirectory, "Fonts"),
                "bundled Python engine import and resource fonts are configured");
            check(start.RedirectStandardInput, "job stdin is a launcher-closed pipe, not the GUI's invalid handle (WinError 6 in job subprocesses)");
            await File.WriteAllTextAsync(script, """
import argparse, json, os, sys
parser = argparse.ArgumentParser()
parser.add_argument('--json', action='store_true')
parser.add_argument('--request', required=True)
args = parser.parse_args()
with open(args.request, encoding='utf-8') as source:
    request = json.load(source)
assert set(request) == {'schema', 'target', 'shell'} and request['schema'] == 1 and request['target'] == 'ios'
assert os.path.normcase(request['shell']) == os.path.normcase(os.path.join(os.path.dirname(os.getcwd()), 'Shell')), 'configured shell reaches backend'
assert os.path.realpath(os.getcwd()) == os.path.realpath(os.path.join(os.path.dirname(__file__), '..', '..'))
assert os.path.normcase(os.environ['S2A_ENGINE']) == os.path.normcase(os.getcwd())
assert os.path.normcase(os.environ['S2A_PREBUILT_TOOLS']) == os.path.normcase(os.path.join(os.getcwd(), 'Binaries', 'Prepare'))
print(json.dumps({'schema':1,'ready':True,'checks':[{'id':'host','name':'中文','status':'ok','ok':True,'message':'correct cwd','code':None,'action':None}]}, ensure_ascii=False))
print('separate stderr', file=sys.stderr)
print('request-file=' + args.request, file=sys.stderr)
""");
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var output = await EnvironmentProbe.RunAsync(paths, deadline.Token);
            if (output.ExitCode != 0)
                throw new Exception($"Probe rc={output.ExitCode}: {output.StandardOutput}\n{output.StandardError}");
            check(output.ExitCode == 0 && output.StandardError.Contains("separate stderr"), "stdout/stderr and exit captured");
            check(EnvironmentReport.Parse(output.StandardOutput, 0).Checks[0].Name == "中文",
                "UTF8 and literal special-character paths survive runtime wrapper");
            var requestFile = output.StandardError.Split('\n').Single(line => line.StartsWith("request-file="))[13..].TrimEnd('\r');
            check(!File.Exists(requestFile), "temporary shell request removed after probe");

            await File.WriteAllTextAsync(script, "import time\ntime.sleep(30)\n");
            var timer = Stopwatch.StartNew();
            using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(300));
            try { await EnvironmentProbe.RunAsync(paths, cancellation.Token); throw new Exception("accepted cancellation"); }
            catch (OperationCanceledException) { check(timer.Elapsed < TimeSpan.FromSeconds(8), "cancel own probe promptly"); }

            await File.WriteAllTextAsync(script, "import sys,time\nsys.stdout.write('x'*3000000)\nsys.stdout.flush()\ntime.sleep(30)\n");
            timer.Restart();
            using var floodDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            try { await EnvironmentProbe.RunAsync(paths, floodDeadline.Token); throw new Exception("accepted output flood"); }
            catch (IOException error)
            {
                check(error.Message.Contains("display limit") && timer.Elapsed < TimeSpan.FromSeconds(10),
                    "output limit terminates own process instead of waiting on blocked writer");
            }
            Console.WriteLine("Windows process cases: 7 assertions passed (synthetic backend, no device probe)");
        }
        finally
        {
            Environment.SetEnvironmentVariable("S2A_TEST_PY_DIR", previousPython);
            Environment.SetEnvironmentVariable("S2A_TEST_MARKER", previousMarker);
            var resolved = Path.GetFullPath(root);
            if (!resolved.StartsWith(tempBase.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar,
                                     StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Test cleanup escaped temporary root.");
            if (Directory.Exists(resolved)) Directory.Delete(resolved, recursive: true);
        }
    }
}
