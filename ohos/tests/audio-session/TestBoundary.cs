// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Test-only device boundary. No P/Invoke, native build or OHAudio success claim.
using System;
using System.Collections.Concurrent;
using System.Threading;

namespace Ryujinx.Memory
{
    // The production base class only needs Read; these tests use actual copied PCM buffers.
    public interface IVirtualMemoryManager { void Read(ulong address, Span<byte> destination); }
}

namespace S2A.Audio.OHAudio
{
    public sealed class OHAudioHardwareDeviceDriver
    {
        private readonly ManualResetEvent _updated = new(false);
        public float Volume => 1;
        public int UnregisterCalls;
        public readonly ConcurrentQueue<Exception> Failures = new();
        public ManualResetEvent GetUpdateRequiredEvent() => _updated;
        internal void Unregister(OHAudioHardwareDeviceSession session) => Interlocked.Increment(ref UnregisterCalls);
        internal void Fail(Exception error) => Failures.Enqueue(error);
    }

    public static unsafe class OHAudioSink
    {
        public const int FormatI16 = 1, FormatF32 = 2;
        public struct Stats
        {
            public ulong FramesOut, FramesPadded;
            public uint Xruns;
            public int BurstFrames, BufferFrames, SampleRate, Sharing;
            public uint Reopens;
        }
        public sealed class Device
        {
            public readonly AutoResetEvent Wake = new(false);
            public readonly object Gate = new();
            public int BytesPerFrame, PauseError, PauseCalls, CloseCalls, Waiters;
            public bool Closed;
            public long FramesOut;
        }
        private static long _next;
        private static readonly ConcurrentDictionary<nint, Device> Devices = new();
        public static Device Get(nint sink) => Devices[sink];
        public static int s2a_ohaudio_open(int format, int sampleRate, int channels, int ringMs, nint* sink)
        {
            *sink = (nint)Interlocked.Increment(ref _next);
            Devices[*sink] = new Device { BytesPerFrame = (format == FormatI16 ? 2 : 4) * channels };
            return 0;
        }
        public static int s2a_ohaudio_start(nint sink) => 0;
        public static int s2a_ohaudio_pause(nint sink)
        {
            Device d = Get(sink);
            Interlocked.Increment(ref d.PauseCalls);
            return Volatile.Read(ref d.PauseError);
        }
        public static void s2a_ohaudio_service(nint sink) { }
        public static int s2a_ohaudio_last_error(nint sink) => 0;
        public static void s2a_ohaudio_notify_at(nint sink, ulong frames)
        {
            Device d = Get(sink);
            if (frames != ulong.MaxValue && (ulong)Interlocked.Read(ref d.FramesOut) >= frames) d.Wake.Set();
        }
        public static int s2a_ohaudio_wait(nint sink, int timeoutMs)
        {
            Device d = Get(sink);
            Interlocked.Increment(ref d.Waiters);
            try { return d.Wake.WaitOne(timeoutMs) ? 1 : 0; }
            finally { Interlocked.Decrement(ref d.Waiters); }
        }
        public static void s2a_ohaudio_wake(nint sink) => Get(sink).Wake.Set();
        public static uint s2a_ohaudio_space(nint sink) => 192000;
        public static uint s2a_ohaudio_write(nint sink, byte* pcm, uint bytes)
        {
            Device d = Get(sink);
            if (d.Closed) throw new InvalidOperationException("Write after close");
            // Immediate device consumption makes the bookkeeping schedule controllable.
            Interlocked.Add(ref d.FramesOut, bytes / d.BytesPerFrame);
            d.Wake.Set();
            return bytes;
        }
        public static void s2a_ohaudio_set_volume(nint sink, float volume) { }
        public static void s2a_ohaudio_stats(nint sink, Stats* stats)
        {
            *stats = new Stats { FramesOut = (ulong)Interlocked.Read(ref Get(sink).FramesOut), SampleRate = 48000 };
        }
        public static void s2a_ohaudio_close(nint sink)
        {
            Device d = Get(sink);
            if (Volatile.Read(ref d.Waiters) != 0) throw new InvalidOperationException("Close before feeder wait exited");
            if (Interlocked.Increment(ref d.CloseCalls) != 1) throw new InvalidOperationException("Double close");
            d.Closed = true;
            d.Wake.Dispose();
        }
    }
}
