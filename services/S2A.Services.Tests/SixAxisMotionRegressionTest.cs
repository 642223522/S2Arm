using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.Input;
using System.Collections.Generic;
using System.Numerics;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [SoloTest("--six-axis-motion", Booted = true)]
        private static void SixAxisMotionRegression()
        {
            NpadDevices npads = Host.Device.Hid.Npads;
            npads.Configure(new ControllerConfig { Player = PlayerIndex.Player1, Type = ControllerType.ProController });
            npads.Update(new List<GamepadInput> { new() { PlayerId = PlayerIndex.Player1 } });
            npads.UpdateSixAxis(new List<SixAxisInput>
            {
                new()
                {
                    PlayerId = PlayerIndex.Player1,
                    Accelerometer = new Vector3(0f, 0f, -1f),
                    Gyroscope = Vector3.Zero,
                    Orientation = new float[9],
                },
            });

            ulong deltaTime = Host.Device.Hid.SharedMemory.Npads[0].InternalState.FullKeySixAxisSensor.GetCurrentEntryRef().DeltaTime;
            Check("六轴回归：游戏读取的每条状态必须带 200 Hz 样本间隔", "5000000", deltaTime.ToString());

            MotionInput motion = new();
            Vector3 gravity = new(0f, 0f, -1f);
            Vector3 yawRate = new(0f, 0f, 90f);

            motion.Update(gravity, yawRate, 0UL, 100, 0f);

            for (int i = 1; i <= 100; i++)
            {
                motion.Update(gravity, yawRate, (ulong)i * 10_000UL, 100, 0f);
            }

            Matrix4x4 orientation = motion.GetOrientation();
            bool yawIs90Degrees = System.MathF.Abs(orientation.M11) <= 0.1f &&
                                  System.MathF.Abs(orientation.M12) >= 0.9f;

            if (!yawIs90Degrees)
            {
                System.Console.Error.WriteLine(
                    $"六轴姿态积分实际值：|M11| = {System.MathF.Abs(orientation.M11):F3}、|M12| = {System.MathF.Abs(orientation.M12):F3}");
            }

            Check(
                "六轴回归：恒定 90 度/秒持续 1 秒后姿态必须转过 90 度",
                "通过",
                yawIs90Degrees ? "通过" : "失败");

            npads.Configure();
        }
    }
}
