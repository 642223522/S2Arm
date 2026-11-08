import Foundation

/// 作业没成（失败 / 取消 / 中断）：带结局，界面按 state 画、按 code 查恢复说明。
public struct JobFailure: Error, LocalizedError {
    public let outcome: JobOutcome
    public init(_ outcome: JobOutcome) { self.outcome = outcome }
    public var state: JobOutcome.State { outcome.state }
    public var code: String? { outcome.diagnostics.first?["code"] as? String }
    public var errorDescription: String? { outcome.message.isEmpty ? JobOutcome.interruptedMessage : outcome.message }
}

extension JobClient {
    /// 交一个作业并等它结束。事件按作业输出顺序进 events（作业层的结果行不转，结局由适配层统一补一条 result，每个作业恰好一条、在最后）。
    /// 外层 Task 取消 = 请作业停（SIGTERM，同 JobHandle.cancel）；completed 回结局，其余抛 JobFailure；起不来抛 JobClientError。
    public func perform(_ operation: String, extra: [String: Any] = [:], events: EventSink = .discard) async throws -> JobOutcome {
        let box = HandleBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JobOutcome, Error>) in
                do {
                    let handle = try start(operation: operation, extra: extra,
                        onEvent: { event in if !event.isFinal { events.emit(EngineEvent(job: event)) } },
                        onFinish: { outcome in
                            events.emit(EngineEvent(outcome: outcome))
                            if outcome.state == .completed { continuation.resume(returning: outcome) }
                            else { continuation.resume(throwing: JobFailure(outcome)) }
                        })
                    box.set(handle)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// 取消可能早于作业起来：先记下，起来时立刻请它停。
final class HandleBox {
    private let lock = NSLock()
    private var handle: JobHandle?
    private var cancelled = false

    func set(_ h: JobHandle) {
        lock.lock(); handle = h; let stop = cancelled; lock.unlock()
        if stop { h.cancel() }
    }

    func cancel() {
        lock.lock(); cancelled = true; let h = handle; lock.unlock()
        h?.cancel()
    }
}
