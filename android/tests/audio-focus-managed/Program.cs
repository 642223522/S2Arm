using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using Ryujinx.Audio.Common;
using S2A.Audio.AAudio;

static class Program
{
    [DllImport("s2arm_android")] private static extern void s2a_aaudio_set_output_allowed(int allowed);
    [DllImport("s2arm_android")] private static extern int test_emit_frame();
    static int Main(string[] args)
    {
        string path = args[0];
        IntPtr Resolve(string name, Assembly _, DllImportSearchPath? __) =>
            name == "s2arm_android" ? NativeLibrary.Load(path) : IntPtr.Zero;
        NativeLibrary.SetDllImportResolver(typeof(AAudioSink).Assembly, Resolve);
        NativeLibrary.SetDllImportResolver(typeof(Program).Assembly, Resolve);
        using var driver = new AAudioHardwareDeviceDriver();
        using var session = new AAudioHardwareDeviceSession(driver, null, SampleFormat.PcmInt16, 48000, 2);
        session.Start();
        var buffer = new AudioBuffer { DataPointer = 123, DataSize = 4, Data = new byte[] { 0x12, 0x34, 0x56, 0x78 } };
        session.QueueBuffer(buffer);
        if (session.WasBufferFullyConsumed(buffer)) throw new Exception("buffer returned before consumption");
        s2a_aaudio_set_output_allowed(0);
        if (test_emit_frame() != 1) throw new Exception("focus-lost callback was not silent");
        if (!SpinWait.SpinUntil(() => session.WasBufferFullyConsumed(buffer), 3000))
            throw new Exception("focus-lost buffer was not returned by the managed session");
        if (session.GetPlayedSampleCount() != 1) throw new Exception("played frame count incorrect");
        Console.WriteLine("AAudio focus loss: silent output, production managed session returned the buffer");
        return 0;
    }
}
