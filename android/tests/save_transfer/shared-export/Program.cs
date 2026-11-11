// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Actual export code; synthetic Host/SaveTransfer engine, no Host.Boot or files.
using System;
using System.Runtime.InteropServices;
using System.Text;
using S2A.Services;

namespace S2A.Services
{
    public static class Host { public static object Device; }
    public static class SaveTransfer
    {
        public static readonly object HostGate = new();
        public static bool HostStarted, English;
        public static int Calls;
        public static void UseLanguage(string value) => English = value.Contains("en");
        public static string T(string chinese, string english) => English ? english : chinese;
        public static string Error(string code, string message) => code;
        public static string Execute(string value)
        {
            Calls++;
            if (!System.Threading.Monitor.IsEntered(HostGate))
                throw new Exception("gate not held");
            return value;
        }
    }
}
namespace Ryujinx.HLE.FileSystem
{
    public class S2ASaveDataFileSystemCreator { public static int NonAtomic; }
}
internal static unsafe class Program
{
    private static int checks;
    private static void Equal(string actual, string expected)
    {
        if (actual != expected) throw new Exception($"expected {expected}, got {actual}");
        checks++;
    }
    private static string Run(byte[] bytes)
    {
        delegate* unmanaged<byte*, nint> run = &SaveTransferExports.Run;
        delegate* unmanaged<nint, void> free = &SaveTransferExports.Free;
        fixed (byte* pointer = bytes)
        {
            nint response = run(pointer);
            try { return Marshal.PtrToStringUTF8(response); }
            finally { free(response); }
        }
    }
    private static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value + "\0");
    private static void Main()
    {
        Equal(Run(Utf8("synthetic")), "synthetic");
        Equal(Run(null), "save_invalid");
        SaveTransfer.HostStarted = true;
        Equal(Run(Utf8("synthetic")), "save_running");
        SaveTransfer.HostStarted = false;
        Host.Device = new object();
        Equal(Run(Utf8("synthetic")), "save_running");
        Host.Device = null;
        var large = new byte[(8 << 20) + 2];
        Array.Fill(large, (byte)'a');
        large[^1] = 0;
        Equal(Run(large), "save_invalid");
        if (!Run(new byte[] { 255, 0 }).Contains("save_internal"))
            throw new Exception("invalid UTF-8 not rejected");
        checks++;
        Equal(SaveTransfer.Calls.ToString(), "1");
        Console.WriteLine($"PASS {checks} shared export ABI boundary checks; synthetic Host/SaveTransfer only, no actual Host.Boot or files");
    }
}
