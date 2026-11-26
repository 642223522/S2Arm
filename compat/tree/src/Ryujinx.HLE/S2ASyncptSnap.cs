// S2A: 本文件为 S2A 新增（非 Ryujinx 原版）。
using Ryujinx.Graphics.Gpu.Synchronization;
using System.IO;

namespace Ryujinx.HLE
{
    /// <summary>
    /// 即时存档：同步点状态存取。host1x 通道的 Submit（视频解码 / 图像处理）不进请求日志（重放要读游戏早已释放的命令缓冲），
    /// 而同步点计数正是 Submit 推上去的：不存的话恢复后计数从头来，游戏命令流里按快照时的计数写的等待（如视频解码等同步点到 1900）
    /// 每次都要等满 1 秒超时，画面一直黑。存每个同步点的 nvhost-ctrl 最小 / 最大值、是否分配 / 客户端管理与 GPU 侧当前值；
    /// 恢复在请求重放之后：只往上抬（重放已推到的不回退），分配标记按快照补上
    /// </summary>
    public static class S2ASyncptSnap
    {
        private const uint Magic = 0x31545053u;   // "SPT1"

        public static void Save(Switch device, BinaryWriter w)
        {
            var sp = device.System.HostSyncpoint; var gpu = device.Gpu.Synchronization;
            w.Write(Magic); w.Write(SynchronizationManager.MaxHardwareSyncpoints);
            for (uint i = 0; i < SynchronizationManager.MaxHardwareSyncpoints; i++)
            {
                w.Write(sp.ReadSyncpointMinValue(i)); w.Write(sp.ReadSyncpointMaxValue(i)); w.Write(gpu.GetSyncpointValue(i));
                w.Write(sp.S2AAssigned(i)); w.Write(sp.S2AClientManaged(i));
            }
        }

        /// <returns>抬过的同步点个数；格式不对回 -1</returns>
        public static int Restore(Switch device, BinaryReader r)
        {
            if (r.ReadUInt32() != Magic) return -1;
            int n = r.ReadInt32(); if (n != SynchronizationManager.MaxHardwareSyncpoints) return -1;
            var sp = device.System.HostSyncpoint; var gpu = device.Gpu.Synchronization; int raised = 0;
            for (uint i = 0; i < n; i++)
            {
                uint min = r.ReadUInt32(), max = r.ReadUInt32(), val = r.ReadUInt32(); bool assigned = r.ReadBoolean(), client = r.ReadBoolean();
                if (gpu.GetSyncpointValue(i) < val) { gpu.S2ARaiseTo(i, val); raised++; }
                sp.S2ARestore(i, min, max, assigned, client);
            }
            return raised;
        }
    }
}
