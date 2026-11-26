// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.Audio;
using Ryujinx.Audio.Common;
using Ryujinx.Audio.Integration;
using Ryujinx.Memory;
using System;
using System.Collections.Concurrent;
using System.Threading;
using static Ryujinx.Audio.Integration.IHardwareDeviceDriver;

namespace S2A.Audio.OHAudio
{
    // Same shape as Ryujinx.Audio.Backends.Apple's driver. OHAudio takes 16-bit and float PCM in
    // mono or stereo and resamples; Ryujinx's compat layer converts other formats and downmixes 5.1.
    public sealed class OHAudioHardwareDeviceDriver : IHardwareDeviceDriver
    {
        private readonly ManualResetEvent _updateRequiredEvent = new(false);
        private readonly ManualResetEvent _pauseEvent = new(true);
        private readonly ConcurrentDictionary<OHAudioHardwareDeviceSession, byte> _sessions = new();

        private readonly Action<Exception> _fatal;
        public OHAudioHardwareDeviceDriver(Action<Exception> fatal) => _fatal = fatal ?? throw new ArgumentNullException(nameof(fatal));
        internal void Fail(Exception error) => _fatal(error);
        public float Volume { get; set; } = 1f;

        // This composition links the OHOS OHAudio API; opening an unsupported format fails explicitly.
        public static bool IsSupported => true;

        public IHardwareDeviceSession OpenDeviceSession(Direction direction, IVirtualMemoryManager memoryManager,
            SampleFormat sampleFormat, uint sampleRate, uint channelCount)
        {
            if (direction != Direction.Output)
            {
                throw new NotImplementedException("Input direction is not implemented on the OHAudio backend");
            }

            var session = new OHAudioHardwareDeviceSession(this, memoryManager, sampleFormat,
                sampleRate == 0 ? Constants.TargetSampleRate : sampleRate, channelCount == 0 ? 2 : channelCount);
            _sessions.TryAdd(session, 0);
            return session;
        }

        internal void Unregister(OHAudioHardwareDeviceSession session) => _sessions.TryRemove(session, out _);

        public ManualResetEvent GetUpdateRequiredEvent() => _updateRequiredEvent;
        public ManualResetEvent GetPauseEvent() => _pauseEvent;

        public bool SupportsDirection(Direction direction) => direction == Direction.Output;
        public bool SupportsSampleRate(uint sampleRate) => true;
        public bool SupportsSampleFormat(SampleFormat sampleFormat) => sampleFormat is SampleFormat.PcmInt16 or SampleFormat.PcmFloat;
        public bool SupportsChannelCount(uint channelCount) => channelCount is 1 or 2;

        public void Dispose()
        {
            foreach (OHAudioHardwareDeviceSession session in _sessions.Keys)
            {
                session.Dispose();
            }

            _pauseEvent.Dispose();
        }
    }
}
