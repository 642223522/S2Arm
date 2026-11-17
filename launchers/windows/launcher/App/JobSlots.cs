// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
namespace S2Arm.Launcher;

/// <summary>前端唯一的作业登记处（启动器剃刀 W20 / W3）：每个在跑的后端作业一条——任务号、种类、哪款游戏、取消源。
/// 忙碌标记、「这款现在能不能动」、控制口 /cancel 都只从这里取。
/// 原先四个取消源 + 六个忙碌布尔各管一摊，各处组合判断不一样：导入中还能点出包、/cancel 不看任务号取消错作业、装机根本取消不了。
/// 并发的正确性由后端游戏库锁保证（排队 + 说清在等谁，pack/jobs/core.py）；这里只决定界面上什么能点、取消发给谁。</summary>
public partial class EnvironmentWindow
{
    internal enum JobKind { Library, Import, Pack, Phone, Environment, Space }

    internal sealed class FrontJob(JobKind kind, string? gameId) : IDisposable
    {
        public JobKind Kind { get; } = kind;
        public string? GameId { get; } = gameId;
        /// <summary>当前这一步后端作业的任务号（一个前端动作可能先后跑几个后端作业，如 setup → catalog）；控制口 /cancel 按它核对</summary>
        public string TaskId { get; private set; } = "";
        public CancellationTokenSource Cancellation { get; } = new();
        public CancellationToken Token => Cancellation.Token;
        /// <summary>起下一个后端作业前取新任务号（写进请求的 jobId，后端任务记录里就是这个号）</summary>
        public string Next() => TaskId = "win-" + Guid.NewGuid().ToString("N");
        /// <summary>这条作业在跑时，这款游戏能不能动：装机只锁正在装的那款（装一款大游戏的十几分钟里别的照常用）；环境检查不碰游戏库；其余都占着游戏库</summary>
        public bool Blocks(string gameId) => Kind switch
        {
            JobKind.Phone => GameId == gameId,
            JobKind.Environment => false,
            _ => true
        };
        public void Dispose() => Cancellation.Dispose();
    }

    private readonly List<FrontJob> jobs = new();

    private FrontJob BeginJob(JobKind kind, string? gameId = null)
    {
        var job = new FrontJob(kind, gameId);
        jobs.Add(job);
        return job;
    }

    /// <summary>作业收尾第一件事就调（在 Render 之前）：重画抛异常也不会让登记留下、按钮永远灰着</summary>
    private void EndJob(FrontJob job)
    {
        if (!jobs.Remove(job)) return;
        job.Dispose();
        // 有排着的出包、这个作业又可能是挡着它的那个（如出包收尾的刷新游戏库）：排到这次收尾之后再看能不能接着出（ExportPages.PumpExportQueue）
        if (exportQueue.Count > 0) Avalonia.Threading.Dispatcher.UIThread.Post(PumpExportQueue);
        if (phoneQueue.Count > 0) Avalonia.Threading.Dispatcher.UIThread.Post(PumpPhoneQueue);   // 手机槽空了 / 出包那款出完：接上排着的手机作业
    }

    /// <summary>手机作业排队（11-16 维护者「出包的时候没办法同时安装其他游戏到 iPhone 上，这个控制纯属多余」；同 Mac phoneQueue）：
    /// 出包在跑照样能装 / 更新 iPhone / 导出已出好的；手机上已有装机作业在跑、或要装的那款正在出包时排上，作业收尾时按先后接上。
    /// GameId = 它要用的那款（更新 iPhone 为 null）</summary>
    private readonly List<(string? GameId, Func<Task> Run)> phoneQueue = new();
    /// <summary>这款正在出包（出包会换它的程序件）：对它的手机作业等出完</summary>
    private bool PackHolds(string? gameId) => gameId is not null && packRunning && packGame?.Id == gameId;
    private bool PhoneQueued(string? gameId) => phoneQueue.Any(q => q.GameId == gameId);
    /// <summary>手机作业要不要先排队：要排就排上并重画，返回 true</summary>
    private bool QueuePhone(string? gameId, Func<Task> run)
    {
        if (!installBusy && !PackHolds(gameId)) return false;
        phoneQueue.Add((gameId, run));
        Render();
        return true;
    }
    private void PumpPhoneQueue()
    {
        if (installBusy) return;
        var i = phoneQueue.FindIndex(q => !PackHolds(q.GameId));
        if (i < 0) return;
        var next = phoneQueue[i]; phoneQueue.RemoveAt(i);
        _ = next.Run();
    }

    private FrontJob? JobOf(JobKind kind) => jobs.LastOrDefault(j => j.Kind == kind);
    private void CancelJob(JobKind kind) => JobOf(kind)?.Cancellation.Cancel();

    private bool libraryBusy => JobOf(JobKind.Library) is not null;
    private bool importBusy => JobOf(JobKind.Import) is not null;
    private bool packRunning => JobOf(JobKind.Pack) is not null;
    private bool installBusy => JobOf(JobKind.Phone) is not null;
    private bool busy => JobOf(JobKind.Environment) is not null;
    private bool freeing => JobOf(JobKind.Space) is not null;
    private bool startupCatalogSent;
    /// <summary>这次打开启动器后的第一次 catalog 带 startup（剃刀 H14）：作业层只在这一次清残留、判任务目录清理；取一次就没了</summary>
    private bool TakeStartupCatalog()
    {
        var first = !startupCatalogSent;
        startupCatalogSent = true;
        return first;
    }

    /// <summary>有任何作业在跑（控制口拒新命令、更新启动器要等）</summary>
    private bool AnyJob => jobs.Count > 0;
}
