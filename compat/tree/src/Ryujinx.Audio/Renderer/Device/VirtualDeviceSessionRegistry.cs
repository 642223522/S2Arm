using Ryujinx.Audio.Integration;
using System.Collections.Generic;

namespace Ryujinx.Audio.Renderer.Device
{
    /// <summary>
    /// Represent an instance containing a registry of <see cref="VirtualDeviceSession"/>.
    /// </summary>
    public class VirtualDeviceSessionRegistry
    {
        /// <summary>
        /// The session registry, used to store the sessions of a given AppletResourceId.
        /// </summary>
        private readonly Dictionary<ulong, VirtualDeviceSession[]> _sessionsRegistry = new();

        /// <summary>
        /// The default <see cref="VirtualDevice"/>.
        /// </summary>
        /// <remarks>This is used when the USB device is the default one on older revision.</remarks>
        public static VirtualDevice DefaultDevice => VirtualDevice.Devices[0];

        /// <summary>
        /// The current active <see cref="VirtualDevice"/>.
        /// </summary>
        // TODO: make this configurable
        public VirtualDevice ActiveDevice { get; }

        public VirtualDeviceSessionRegistry(IHardwareDeviceDriver driver)
        {
            uint channelCount;

            if (driver.GetRealDeviceDriver().SupportsChannelCount(6))
            {
                channelCount = 6;
            }
            else
            {
                channelCount = 2;
            }

            // S2Arm（#189 后续，5.1 虚拟环绕第二片）：名字按玩家显式选择的设备类型跟（后端 S2AActiveDeviceName：builtin →
            //   AudioBuiltInSpeakerOutput、headphones → AudioStereoJackOutput），后端没给（null）保持缺省 AudioTvOutput——
            //   未显式选择 = 按设备真实声道判，名字与缺省一致。声道数照旧只看 SupportsChannelCount(6)（显式类型 + 虚拟环绕开
            //   时后端本就上报 6，见 AppleAudioDeviceType）；USB / 蓝牙设备选 Headphones 时也报 StereoJack——设备类型语义的简化，
            //   不逐设备另报真实接口名
            string? deviceName = driver.GetRealDeviceDriver().S2AActiveDeviceName();

            ActiveDevice = new VirtualDevice(deviceName ?? "AudioTvOutput", channelCount, false);
        }

        /// <summary>
        /// Get the associated <see cref="T:VirtualDeviceSession[]"/> from an AppletResourceId.
        /// </summary>
        /// <param name="resourceAppletId">The AppletResourceId used.</param>
        /// <returns>The associated <see cref="T:VirtualDeviceSession[]"/> from an AppletResourceId.</returns>
        public VirtualDeviceSession[] GetSessionByAppletResourceId(ulong resourceAppletId)
        {
            if (_sessionsRegistry.TryGetValue(resourceAppletId, out VirtualDeviceSession[] result))
            {
                return result;
            }

            result = CreateSessionsFromBehaviourContext();

            _sessionsRegistry.Add(resourceAppletId, result);

            return result;
        }

        /// <summary>
        /// Create a new array of sessions for each <see cref="VirtualDevice"/>.
        /// </summary>
        /// <returns>A new array of sessions for each <see cref="VirtualDevice"/>.</returns>
        private static VirtualDeviceSession[] CreateSessionsFromBehaviourContext()
        {
            VirtualDeviceSession[] virtualDeviceSession = new VirtualDeviceSession[VirtualDevice.Devices.Length];

            for (int i = 0; i < virtualDeviceSession.Length; i++)
            {
                virtualDeviceSession[i] = new VirtualDeviceSession(VirtualDevice.Devices[i]);
            }

            return virtualDeviceSession;
        }
    }
}
