using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Audio.Renderer.Dsp
{
    /// <summary>
    /// S2Arm (11-14 卡顿诊断探针): 把声音渲染线程每个 5 ms 周期的唤醒迟到纳秒累计交给宿主（hle_nvn.c 的 s2a_aud_late_note），
    /// DM_NVN_TSV 每帧取走清零成 @aud_wait_ms 列。慢帧归因「在等事件」时用它看音频占比。
    /// </summary>
    /// <remarks>
    /// s2a_aud_late_note 在公用核心 runtime/src/ap_host.c（苹果与安卓都链；安卓诊断组合有替身），各端静态链（DirectPInvoke）。
    /// 没有 s2a_native 的宿主（单测 / 别的宿主）调用失败就不再调。
    /// </remarks>
    internal static class S2AAudLate
    {
        [DllImport("s2a_native")] private static extern void s2a_aud_late_note(long ns);

        private static bool _gone;

        internal static void Note(long lateNs)
        {
            if (_gone)
            {
                return;
            }

            try
            {
                s2a_aud_late_note(lateNs);
            }
            catch (Exception e) when (e is DllNotFoundException || e is EntryPointNotFoundException || e is BadImageFormatException)
            {
                _gone = true;
            }
        }
    }
}
