using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Renderer.Server
{
    // S2Arm（#1240）：全进程累计的缺页 / 读盘换入次数（Apple 平台；别处 0）。声音渲染循环在每次 DSP 前后各读一次，慢拍那行就能看出这一拍
    //   是不是在等页：8 GB Mac 上客体内存走文件后备，脏文件页过内核阈值后每次写缺页都要等写回（#306）。
    //   放在音频程序集里，不放 Ryujinx.Common（那里的源码算进着色器翻译器的源码指纹，改它要重编预编译翻译器）
    internal static class S2ATaskFaults
    {
        // task_events_info（mach/task_info.h，TASK_EVENTS_INFO = 2）
        [StructLayout(LayoutKind.Sequential)]
        private struct TaskEventsInfo
        {
            public int Faults, Pageins, CowFaults, MessagesSent, MessagesReceived, SyscallsMach, SyscallsUnix, Csw;
        }

        [DllImport("libc")]
        private static extern uint task_self_trap();

        [DllImport("libc")]
        private static extern int task_info(uint task, int flavor, ref TaskEventsInfo info, ref uint count);

        private static readonly bool s_apple = OperatingSystem.IsMacOS() || OperatingSystem.IsIOS() || OperatingSystem.IsTvOS();   // 平台例外：tvOS 与 iOS 走同一分支

        public static void Read(out long faults, out long pageins)
        {
            faults = pageins = 0;

            if (!s_apple)
            {
                return;
            }

            TaskEventsInfo info = default;
            uint count = 8;

            if (task_info(task_self_trap(), 2, ref info, ref count) == 0)
            {
                faults = (uint)info.Faults;
                pageins = (uint)info.Pageins;
            }
        }
    }
}
