// #377：画面模式只读出包 IPA 的 Info.plist，与 iOS「关于本包」共用数据来源。
import Foundation

enum PackGraphicsMode: Equatable {
    case direct
    case unknown

    var title: String {
        switch self {
        case .direct: return SharedExperience.packLabel("direct")
        case .unknown: return SharedExperience.packLabel("unknown")
        }
    }
}

struct PackGraphicsEvidence: Equatable {
    var mode: PackGraphicsMode = .unknown
    var directLibraryVersion: String?
    var packTime: String?
    var buildID: String?
}

enum PackModeJudge {
    static func mode(_ evidence: PackGraphicsEvidence) -> PackGraphicsMode { evidence.mode }
}

enum PackGraphicsEvidenceReader {
    static func read(plist data: Data) -> PackGraphicsEvidence {
        guard let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
        else { return PackGraphicsEvidence() }
        let mode: PackGraphicsMode
        switch info["S2AGraphicsMode"] as? String {
        case "direct": mode = .direct
        default: mode = .unknown   // 包只出直连（11-07 拆掉通用模式）：旧的通用包也按未知
        }
        return PackGraphicsEvidence(mode: mode, directLibraryVersion: info["S2ADirectLibVersion"] as? String,
                                    packTime: info["S2APackTime"] as? String, buildID: info["S2ABuildID"] as? String)
    }

    static func read(ipa: URL?) -> PackGraphicsEvidence {
        guard let ipa, FileManager.default.fileExists(atPath: ipa.path) else { return PackGraphicsEvidence() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", ipa.path, "Payload/*.app/Info.plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return PackGraphicsEvidence() }
        // 先排空 stdout，避免二进制 plist 较大时管道满而与 waitUntilExit 互等。
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return PackGraphicsEvidence() }
        return read(plist: data)
    }
}

/// 阶段条的一段。
struct PackStagePhase: Identifiable, Equatable {
    enum State: Equatable {
        case pending, running, done
        /// 这一包不出这一段（附原因，可为空）
        case unused(String?)
    }
    let id: String
    /// 本地化源串（L() 的输入）
    let label: String
    var state: State
    /// 正在做的真实子阶段名（里程碑自己的名称），不是另编的文案
    var detail: String?
    /// 段内填充比例
    var fill: Double
}

/// 「解包 → 改写与准备 → 直连库 → 编 App 与签名」四段，与 pack/refresh.sh、oneclick.sh 的现行顺序一致（11-07 起只出直连，没有通用兜底那条并行泳道）。
struct PackStageGroup: Identifiable, Equatable {
    let id: String
    /// 并行组里每一段各自带名称，单段组的名称放在 phase.label
    var phases: [PackStagePhase]
}

enum PackStagePlan {
    static func groups(for task: TaskRecord) -> [PackStageGroup] {
        let plan = task.milestones ?? []
        let completed = task.state == "completed"
        let currentIndex = task.milestone.flatMap { id in plan.firstIndex { $0.id == id } }
        func index(_ id: String) -> Int? { plan.firstIndex { $0.id == id } }

        func single(_ id: String) -> PackStagePhase.State {
            guard let i = index(id) else { return .unused(nil) }
            if completed { return .done }
            guard let currentIndex else { return .pending }
            if i < currentIndex { return .done }
            if i == currentIndex { return .running }
            return .pending
        }

        func fill(_ state: PackStagePhase.State) -> Double {
            switch state {
            case .done: return 1
            case .running: return max(0.05, min(1, task.progressFraction ?? 0))   // 没有真实完成数时只留一点颜色表示在跑，不编比例
            case .pending, .unused: return 0
            }
        }

        /// 正在跑时正文写当前里程碑自己的名称
        func runningDetail(_ state: PackStagePhase.State) -> String? {
            guard state == .running, let currentIndex else { return nil }
            return plan[currentIndex].label
        }

        // 解包
        let unpackState = single("unpack")
        let unpack = PackStagePhase(id: "unpack", label: "解包", state: unpackState,
                                    detail: runningDetail(unpackState),
                                    fill: fill(unpackState))

        // 改写与准备（refresh.sh 前段：改写 / 系统数据 / 宽屏布局 / 追加内容 / 直连配置推导 / RomFS 索引 / 抽取）；老任务记录叫 rewrite
        let prepID = index("refresh") != nil ? "refresh" : "rewrite"
        let prepState = single(prepID)
        let prep = PackStagePhase(id: "prep", label: "改写与准备", state: prepState, detail: nil, fill: fill(prepState))

        // 只展示已声明的里程碑。直连配置推导在改写与准备段里做完，直连库段只管出库。
        let profileState = single("direct_profile")
        let profile = PackStagePhase(id: "profile", label: "推导配置", state: profileState,
                                     detail: runningDetail(profileState), fill: fill(profileState))
        let directState = single("direct")
        let direct = PackStagePhase(id: "direct", label: "直连库",
                                    state: directState, detail: runningDetail(directState), fill: fill(directState))

        // 编 App 与签名（oneclick ④ 出包：编 App、签名、资源包）
        let signState = single("ipa")
        let sign = PackStagePhase(id: "sign", label: "编 App 与签名", state: signState,
                                  detail: runningDetail(signState),
                                  fill: fill(signState))

        var groups = [PackStageGroup(id: "unpack", phases: [unpack])]
        if index(prepID) != nil { groups.append(PackStageGroup(id: "prep", phases: [prep])) }
        if index("direct_profile") != nil { groups.append(PackStageGroup(id: "profile", phases: [profile])) }
        groups.append(PackStageGroup(id: "direct", phases: [direct]))
        groups.append(PackStageGroup(id: "sign", phases: [sign]))
        return groups
    }
}
