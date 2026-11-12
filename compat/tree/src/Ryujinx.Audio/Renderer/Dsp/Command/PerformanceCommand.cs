using Ryujinx.Audio.Renderer.Server.Performance;

namespace Ryujinx.Audio.Renderer.Dsp.Command
{
    public class PerformanceCommand : ICommand
    {
        public enum Type
        {
            Invalid,
            Start,
            End,
        }

        public bool Enabled { get; set; }

        public int NodeId { get; private set; }

        public CommandType CommandType => CommandType.Performance;

        public uint EstimatedProcessingTime { get; set; }

        public PerformanceEntryAddresses PerformanceEntryAddresses { get; private set; }

        public Type PerformanceType { get; set; }

        public PerformanceCommand()
        {
            
        }

        public PerformanceCommand Initialize(ref PerformanceEntryAddresses performanceEntryAddresses, Type performanceType, int nodeId)
        {
            // 同一对 Start / End 命令共用一个 PerformanceEntryAddresses（CommandGenerator 取一次条目、生成两条命令），只由 End 那条在被复用时归还。
            //   原先两条各还一次：池子每轮取 1 还 2、只涨不缩，同一对象在池里多份；不限大小的 ConcurrentBag 一路扩容，
            //   玩几分钟到十几分钟后在 LocalPush 托管 OOM（#668，Mac 退出码 134）
            if (PerformanceEntryAddresses is not null && PerformanceType == Type.End)
            {
                PerformanceEntryAddresses.PerformanceEntryAddressesPool.Release(PerformanceEntryAddresses);
            }
            
            Enabled = true;
            PerformanceEntryAddresses = performanceEntryAddresses;
            PerformanceType = performanceType;
            NodeId = nodeId;

            return this;
        }

        public void Process(CommandList context)
        {
            if (PerformanceType == Type.Start)
            {
                PerformanceEntryAddresses.SetStartTime(context.GetTimeElapsedSinceDspStartedProcessing());
            }
            else if (PerformanceType == Type.End)
            {
                PerformanceEntryAddresses.SetProcessingTime(context.GetTimeElapsedSinceDspStartedProcessing());
                PerformanceEntryAddresses.IncrementEntryCount();
            }
        }
    }
}
