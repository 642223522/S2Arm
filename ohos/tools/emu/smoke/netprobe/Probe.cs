// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class Probe {
    static string NullRef() { try { object o = null; return o.ToString(); } catch (NullReferenceException) { return "caught NRE (hw fault path, worker thread)"; } }
    static string AsyncProbe() => Task.Run(async () => { await Task.Delay(10); return "await ok"; }).Result;
    static byte[] _buf = new byte[4096];
    [UnmanagedCallersOnly(EntryPoint = "s2a_dotnet_probe")]
    public static unsafe IntPtr Run() {
        var sb = new StringBuilder();
        void T(string n, Func<string> f) { try { sb.Append("OK   ").Append(n).Append(": ").Append(f()).Append('\n'); } catch (Exception e) { sb.Append("FAIL ").Append(n).Append(": ").Append(e.GetType().Name).Append(' ').Append(e.Message).Append('\n'); } }
        T("runtime", () => RuntimeInformation.FrameworkDescription + " " + RuntimeInformation.RuntimeIdentifier + " cpus=" + Environment.ProcessorCount);
        T("gc", () => { long t = 0; for (int i = 0; i < 2000; i++) { var a = new byte[64 * 1024]; t += a.Length; } GC.Collect(); return $"alloc {t >> 20} MiB, gen2={GC.CollectionCount(2)} heap={GC.GetTotalMemory(true) >> 10} KiB"; });
        T("gcinfo", () => { var i = GC.GetGCMemoryInfo(); return $"total_avail={i.TotalAvailableMemoryBytes >> 20} MiB server={System.Runtime.GCSettings.IsServerGC}"; });
        T("exception", () => { try { throw new InvalidOperationException("x"); } catch (InvalidOperationException) { return "caught"; } });
        // On a worker thread, as game code runs: a fault on the ArkTS (UI) thread is treated by the
        // ArkTS runtime as a JS-thread crash even when this runtime recovers from it.
        T("nullref", () => Task.Run(NullRef).Result);
        T("threads", () => { int s = 0; Parallel.For(0, 64, i => Interlocked.Add(ref s, i)); return "sum=" + s; });
        T("task", AsyncProbe);
        T("time", () => DateTime.UtcNow.ToString("o") + " tz=" + TimeZoneInfo.Local.Id);
        var bytes = Encoding.UTF8.GetBytes(sb.ToString());
        int n = Math.Min(bytes.Length, _buf.Length - 1);
        fixed (byte* p = _buf) { Marshal.Copy(bytes, 0, (IntPtr)p, n); p[n] = 0; return (IntPtr)p; }
    }
}
