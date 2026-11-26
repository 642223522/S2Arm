// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System.Runtime.InteropServices;

namespace S2A.Audio.OHAudio
{
    // ../audio/ohaudio_sink.h. The single-library build binds these at link time (DirectPInvoke);
    // a separate C# library finds the already loaded host library by name.
    public static unsafe class OHAudioSink
    {
        private const string Lib = "s2a_native";

        public const int FormatI16 = 1;   // pcm_ring.h S2A_PCM_I16
        public const int FormatF32 = 2;   // S2A_PCM_F32

        [StructLayout(LayoutKind.Sequential)]
        public struct Stats
        {
            public ulong FramesOut, FramesPadded;
            public uint Xruns;
            public int BurstFrames, BufferFrames, SampleRate, Sharing;
            public uint Reopens;
        }

        [DllImport(Lib)] public static extern int s2a_ohaudio_open(int format, int sampleRate, int channels, int ringMs, nint* sink);
        [DllImport(Lib)] public static extern int s2a_ohaudio_start(nint sink);
        [DllImport(Lib)] public static extern int s2a_ohaudio_pause(nint sink);
        [DllImport(Lib)] public static extern void s2a_ohaudio_service(nint sink);
        [DllImport(Lib)] public static extern int s2a_ohaudio_last_error(nint sink);
        [DllImport(Lib)] public static extern void s2a_ohaudio_notify_at(nint sink, ulong frames);
        [DllImport(Lib)] public static extern int s2a_ohaudio_wait(nint sink, int timeoutMs);
        [DllImport(Lib)] public static extern void s2a_ohaudio_wake(nint sink);
        [DllImport(Lib)] public static extern uint s2a_ohaudio_space(nint sink);
        [DllImport(Lib)] public static extern uint s2a_ohaudio_write(nint sink, byte* pcm, uint bytes);
        [DllImport(Lib)] public static extern void s2a_ohaudio_set_volume(nint sink, float volume);
        [DllImport(Lib)] public static extern void s2a_ohaudio_stats(nint sink, Stats* stats);
        [DllImport(Lib)] public static extern void s2a_ohaudio_close(nint sink);
    }
}
