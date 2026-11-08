import Foundation

/// Play：交 launch 作业（作业层校验运行文件、恢复存档、拼宿主环境、起 s2arm-host 并等它退出）。
/// 界面不碰可执行路径和环境变量；同一时刻只许一局（同旧启动器「执行位」互斥）。
public final class PlayService {
    private let client: JobClient
    public private(set) var current: JobHandle?

    public init(client: JobClient) {
        self.client = client
    }

    public var isRunning: Bool { current != nil }

    /// 起一局。uiLanguage：宿主内提示的语言（作业层只认 zh-Hans / en）。arguments：起局请求的附加字段（缺省没有：游戏语言跟系统、主机模式由作业层定）。已有一局在跑时拒绝。
    @discardableResult
    public func play(gameId: String, uiLanguage: String? = nil, arguments: [String: Any]? = nil,
                     onEvent: @escaping (JobEvent) -> Void = { _ in },
                     onFinish: @escaping (JobOutcome) -> Void = { _ in }) throws -> JobHandle {
        guard current == nil else { throw JobClientError("已有一局在运行，请先停止。") }
        var extra = arguments ?? [:]
        extra["gameId"] = gameId
        if let uiLanguage, ["zh-Hans", "en"].contains(uiLanguage) { extra["uiLanguage"] = uiLanguage }
        let handle = try client.start(operation: "launch", extra: extra, onEvent: onEvent, onFinish: { [weak self] outcome in
            if self?.current?.id == outcome.taskId { self?.current = nil }
            onFinish(outcome)
        })
        current = handle
        return handle
    }

    /// 停这一局：请作业停（作业层停宿主、记取消）；结局照常从 onFinish 回来。
    public func stop() {
        current?.cancel()
    }
}
