using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Renderer.Server
{
    // S2Arm: the DSP reads and writes the renderer work buffer (mix buffers, voice / effect state are all carved from it) on the
    // realtime audio thread. Under memory pressure the system compresses or swaps this anonymous memory out; the DSP then faults
    // it back in from disk on the realtime thread and a single 5 ms period takes hundreds of milliseconds (Mac with 8 GB: no sound
    // in game, only the DSP part of the period is slow). Realtime threads must not touch pageable memory, so the buffer is page
    // aligned and wired (mlock), and unwired before it is freed. If wiring fails (system wired limit etc.) the buffer is used as is
    // and one line is logged.
    static unsafe class S2AWiredBuffer
    {
        private const nuint Page = 16384;

        [DllImport("libc", SetLastError = true)]
        private static extern int mlock(void* addr, nuint len);

        [DllImport("libc", SetLastError = true)]
        private static extern int munlock(void* addr, nuint len);

        private static bool CanWire => OperatingSystem.IsMacOS() || OperatingSystem.IsIOS() || OperatingSystem.IsTvOS() || OperatingSystem.IsLinux() || OperatingSystem.IsAndroid();

        public static nuint Round(int size) => ((nuint)Math.Max(size, 1) + Page - 1) & ~(Page - 1);

        public static byte* Alloc(int size, out bool wired)
        {
            nuint n = Round(size);
            byte* p = (byte*)NativeMemory.AlignedAlloc(n, Page);
            NativeMemory.Clear(p, n);
            wired = false;

            if (CanWire)
            {
                wired = mlock(p, n) == 0;
                Console.Error.WriteLine(wired
                    ? $"[声] 渲染器工作缓冲 {n / 1024} KB 已锁进物理内存（实时音频线程不会因内存吃紧缺页）"
                    : $"[声] 【黄】渲染器工作缓冲 {n / 1024} KB 锁不进物理内存（errno {Marshal.GetLastPInvokeError()}），照常用；内存吃紧时音频可能断续");
            }

            return p;
        }

        public static void Free(byte* p, int size, bool wired)
        {
            if (wired)
            {
                munlock(p, Round(size));
            }

            NativeMemory.AlignedFree(p);
        }
    }

    // S2Arm: the DSP reads the memory pools the game attaches to the renderer (sample data) on the realtime audio thread. The host
    // sets this hook to keep a pool resident while it is attached (on = true at map, false at unmap); null = nothing to do.
    public static unsafe class S2AAudioPoolResident
    {
        public static delegate*<ulong, ulong, bool, void> Hook;
    }
}
