using Ryujinx.HLE.HOS.Services.Hid;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // #1671：一款体育游戏要 1 人、样式只收 掌机 / 双 Joy-Con（「ControllerApplet ArgPriv … StyleSets:Handheld, JoyconPair」「Arg 1 1 1 0」），
    //   宿主的虚拟手柄配的是 Player1 的 Pro。Remap 按游戏声明把它换成双 Joy-Con 写进共享内存（游戏看到 JoyDual），
    //   小程序重验原先照配置表判「Pro 不收」→ 已连 0 人，应答连判 3 次卡住、报红，游戏拿到 0 人、选中手柄号 Other（0x10）。
    //   期望按 hid 语义手写：Player1 是游戏收的双 Joy-Con，人数 1–1 → 重验通过 1 人、主手柄 Player1；小程序回 1 人、NpadId 0（No1）。
    //   修前：重验 False 0 Unknown；小程序 0 人、0x10
    public static partial class Program
    {
        [SoloTest("--applet-pro-remap", Booted = true)]
        private static void ControllerAppletProRemap()
        {
            NpadDevices npads = Host.Device.Hid.Npads;
            ControllerType before = npads.SupportedStyleSets;
            npads.ClearSupportedPlayers();
            foreach (PlayerIndex p in new[] { PlayerIndex.Player1, PlayerIndex.Player2, PlayerIndex.Player3, PlayerIndex.Player4, PlayerIndex.Handheld })
                npads.SetSupportedPlayer(p);
            const ControllerType wants = ControllerType.Handheld | ControllerType.JoyconPair;
            npads.SupportedStyleSets = wants;
            InputPump.SetPrimary(Host.Device, PlayerIndex.Player1, ControllerType.ProController);
            npads.Update(new List<GamepadInput> { new() { PlayerId = PlayerIndex.Player1 } });   // Remap：Pro → 双 Joy-Con
            uint style = (uint)Host.Device.Hid.SharedMemory.Npads[(int)PlayerIndex.Player1].InternalState.StyleSet;

            bool valid = npads.Validate(1, 1, wants, out int count, out PlayerIndex primary);
            var (applet, id) = ShowControllerSupport((uint)wants);

            InputPump.SetPrimary(Host.Device, PlayerIndex.Handheld, ControllerType.Handheld);   // 还原
            npads.SupportedStyleSets = before;
            while (Host.Device.System.AppletState.Messages.TryDequeue(out _)) { }
            Check("手柄设置小程序：配的 Pro 被换成双 Joy-Con（游戏只收 掌机 / 双 Joy-Con、1 人）→ 重验认它（Player1 样式 / 重验 / 小程序人数 NpadId）",
                  "4 / True 1 Player1 / 1 0x0", $"{style} / {valid} {count} {primary} / {applet} 0x{id:X}");
        }
    }
}
