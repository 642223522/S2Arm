// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Linq;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        [SoloTest("--acc-network-service-mode", Booted = true)]
        private static void AccountNetworkServiceMode()
        {
            var system = Host.Device.System;
            int usersBefore = system.AccountManager.GetAllUsers().Count();

            // UiMode 2 is EnsureNetworkServiceAccountAvailable, not UserSelector.
            // UiReturnArg is a result followed by a Uid (0x18 bytes). The SDK
            // returns that result directly; 0x27c is account cancellation.
            foreach (uint mode in new uint[] { 2, 0, 2 })
            {
                var normal = new AppletSession();
                var game = normal.GetConsumer();
                game.Push(new byte[0x20]);
                byte[] settings = new byte[0xA0];
                BitConverter.GetBytes(mode).CopyTo(settings, 0);
                game.Push(settings);
                var applet = new PlayerSelectApplet(system);
                int notifications = 0;
                applet.AppletStateChanged += (_, _) => notifications++;
                uint started = (uint)applet.Start(normal, new AppletSession());
                bool got = game.TryPop(out byte[] reply);
                Check($"psel mode {mode} 完成与通知", "0/True/1", $"{started}/{got}/{notifications}");
                if (!got || reply.Length < 8) continue;
                ulong result = BitConverter.ToUInt64(reply, 0);
                bool zeroUid = reply.Length == 0x18 && reply.Skip(8).All(b => b == 0);
                Check($"psel mode {mode} 结果与完整回包", mode == 2 ? "24/27c/True" : "24/0/False",
                    $"{reply.Length}/{result:x}/{zeroUid}");
                Check($"psel mode {mode} 只回一次", "False", game.TryPop(out _).ToString());
            }

            Check("账号小程序没有创建用户", usersBefore.ToString(), system.AccountManager.GetAllUsers().Count().ToString());
            while (system.AppletState.Messages.TryDequeue(out _)) { }
        }
    }
}
