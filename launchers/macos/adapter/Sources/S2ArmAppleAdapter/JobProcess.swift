import Foundation

/// 起作业进程的那一层（单测换成假的）。约定：同一个进程的回调都在一条串行队列上依次到达，`onExit` 一定在最后一个 `onLine` / `onStderr` 之后
/// （同旧 Store.worker：两条读管道都读到 EOF 才处理退出，快结束的作业最后一条结果事件不能和退出通知抢）。
public protocol JobProcessRunner {
    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle
}

/// 起来的作业进程：只认「请它停」（SIGTERM，作业层收到后记取消、退出码 130）。
public protocol JobProcessHandle: AnyObject {
    func terminate()
}

/// 按行切标准输出：作业层一行一个 NDJSON 事件；结尾没有换行的半行在 EOF 时交出。
struct LineSplitter {
    private var pending = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    mutating func finish() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

/// 真的：Foundation.Process + 两条管道。
public final class SystemJobProcessRunner: JobProcessRunner {
    /// 作业是玩家点了按钮在等的事（出包、装机推送）：跑着的时候不让系统把启动器降成后台（App Nap）。原先什么都没做：启动器隐藏 / 窗口被挡住
    ///   一段时间后被降成后台，之后再起的作业连同它的子进程（s2a-devpush）一起被节流，读盘和 USB 都慢，推送从 60–120 MiB/s 掉到 5–13 MiB/s
    ///   （11-17 实测：同一 s2a-devpush 推同一冷文件，正常 81.8 MiB/s、taskpolicy -b 13.2 MiB/s；隐藏启动器先出包二十多分钟再推的那单约 7 MB/s，
    ///   起来几秒就推的那单 57–70 MB/s）。每个作业进程起之前开一段 userInitiated 活动，进程结束就收
    private let beginActivity: () -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void
    public convenience init() {
        self.init(beginActivity: { ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "S2Arm 作业（出包 / 装机推送）") },
                  endActivity: { ProcessInfo.processInfo.endActivity($0) })
    }
    /// 单测换成假的活动，核「开了就收」
    public init(beginActivity: @escaping () -> NSObjectProtocol, endActivity: @escaping (NSObjectProtocol) -> Void) {
        self.beginActivity = beginActivity; self.endActivity = endActivity
    }

    final class Handle: JobProcessHandle {
        let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }

    public func start(executable: URL, arguments: [String], environment: [String: String],
                      onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
                      onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let queue = DispatchQueue(label: "s2arm.job.events")
        let readers = DispatchGroup()
        readers.enter(); readers.enter()
        let activity = beginActivity(), end = endActivity
        process.terminationHandler = { p in
            end(activity)
            readers.notify(queue: queue) { onExit(p.terminationStatus) }
        }
        do { try process.run() } catch { end(activity); throw error }
        DispatchQueue.global(qos: .utility).async {
            defer { try? out.fileHandleForReading.close(); readers.leave() }
            var splitter = LineSplitter()
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                for line in splitter.append(chunk) { queue.async { onLine(line) } }
            }
            if let rest = splitter.finish() { queue.async { onLine(rest) } }
        }
        DispatchQueue.global(qos: .utility).async {
            defer { try? err.fileHandleForReading.close(); readers.leave() }
            while true {
                let chunk = err.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                queue.async { onStderr(chunk) }
            }
        }
        return Handle(process)
    }
}
