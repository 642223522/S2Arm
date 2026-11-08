import Foundation

// 出包 / 准备的里程碑（作业层 pack/jobs/milestones.py：开始时一条 plan 事件列全部里程碑与本机历史预计，之后每条事件带当前 milestone id）。
// 新旧两个 Mac 前端共用这一份推算（旧启动器 MilestoneProgressView、新前端出包进度页），不留两份。

/// 计划里的一步（plan 事件 milestones 的一项）。
public struct Milestone: Codable, Identifiable, Equatable {
    // expected：本机同种任务历史的预计秒数；本机没有记录时后端给 null（不拿别的游戏的旧实测顶，10-25 维护者）
    public var id: String
    public var label: String
    public var purpose: String
    public var expected: Double?
    public var source: String?
    public var samples: Int?
    public var basis: String?
    /// 这一步这次会复用缓存（作业层能判的在计划里先标，开工后才知道的当场改标、重发计划）。老作业没有这个字段。
    public var reuse: Bool?

    public init(id: String, label: String, purpose: String, expected: Double? = nil, source: String? = nil, samples: Int? = nil,
                basis: String? = nil, reuse: Bool? = nil) {
        self.id = id; self.label = label; self.purpose = purpose; self.expected = expected
        self.source = source; self.samples = samples; self.basis = basis; self.reuse = reuse
    }

    /// 只认本机历史给的预计（复用步是本机复用时的记录）；复用步本机还没有复用记录时作业层按 0 秒计（source = reuse）。
    /// 老任务记录里的缺省值（source = default）不再当预计用
    public var measured: Double? {
        if source == "reuse" { return expected ?? 0 }
        return source == "history" && (samples ?? 0) > 0 ? expected : nil
    }

    /// plan 事件的 milestones 字段（JSON 数组）；读不出为 nil。
    public static func plan(_ value: Any?) -> [Milestone]? {
        guard let value, JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode([Milestone].self, from: data)
    }
}

/// 里程碑进度的时间推算（纯计算，单测覆盖）。只用两种真读数（10-25 维护者：不是即时计算或写死的数字都不显示）：
/// - 本步速度：当前步有真实完成数（≥5%）时，本步还需 = 本步已用 ×（1 − 完成比例）÷ 完成比例。
/// - 本机历史：当前步及之后每一步都有本机同种任务的记录（Milestone.measured）时，才给整单「预计还需」：
///   当前步剩余（有速度按速度，否则按「记录 − 已用」，至少留记录的 10%）+ 后面各步记录 × 校准系数。
///   校准系数 = 已完成各步实际 ÷ 记录（夹在 0.5–3 之间）。缺任何一步的记录就不给（nil），不拿缺省值或别的游戏顶。
public struct MilestoneEstimate {
    public let plan: [Milestone]; public let current: String?; public let started: [String: Double]; public let fraction: Double?; public let now: Double
    public init(plan: [Milestone], current: String?, started: [String: Double], fraction: Double?, now: Double) {
        self.plan = plan; self.current = current; self.started = started; self.fraction = fraction; self.now = now
    }
    public var index: Int? { plan.firstIndex { $0.id == current } }
    public var stepElapsed: Double { guard let c = current, let s = started[c] else { return 0 }; return max(0, now - s) }
    public var totalElapsed: Double { guard let first = started.values.min() else { return 0 }; return max(0, now - first) }
    public var calibration: Double {
        guard let i = index, i > 0 else { return 1 }
        var actual = 0.0, expected = 0.0
        for k in 0..<i { let m = plan[k]; guard let s = started[m.id], let e = m.measured else { continue }
            let end = started[plan[k + 1].id] ?? now; actual += max(0, end - s); expected += e }
        return expected > 1 ? min(3, max(0.5, actual / expected)) : 1
    }
    /// 按本步实际速度外推的本步剩余；没有真实完成数（或不到 5%）时 nil
    public var stepRemainingByRate: Double? {
        guard index != nil, let f = fraction, f >= 0.05, f < 1 else { return nil }
        return stepElapsed * (1 - f) / f
    }
    /// 整单预计还需：当前步及之后都有本机记录才给
    public var remaining: Double? {
        guard let i = index else { return nil }
        let rest = plan[i...].compactMap(\.measured)
        guard rest.count == plan.count - i, let e = plan[i].measured else { return nil }
        let current = stepRemainingByRate ?? max(e * calibration - stepElapsed, e * calibration * 0.1)
        return current + rest.dropFirst().reduce(0, +) * calibration
    }
    /// 估计用到的本机记录条数（按历史估的各步记录数取最少的那个；复用缓存按 0 秒计的步不算），用来写「按本机最近 N 次」；全是 0 秒复用步为 0
    public var historySamples: Int {
        guard let i = index else { return 0 }
        return plan[i...].filter { $0.source == "history" }.map { $0.samples ?? 0 }.min() ?? 0
    }
    /// 第 k 段的填充比例：之前的段 1、当前段按真实完成数（没有就按已用 ÷ 本机记录，最多 0.95；也没有记录就 0）、之后 0
    public func fill(_ k: Int) -> Double {
        guard let i = index else { return 0 }
        if k < i { return 1 }; if k > i { return 0 }
        if let f = fraction { return min(1, max(0, f)) }
        guard let e = plan[i].measured else { return 0 }
        return min(0.95, stepElapsed / max(1, e * calibration))
    }
}

/// 一个作业的里程碑轨迹：从事件里收 plan 与当前里程碑，记每步在本机开始的时刻（墙钟秒）。新前端进度页用（旧启动器 Store 自己收同样的两样）。
public struct MilestoneTrack: Equatable {
    public private(set) var plan: [Milestone] = []
    public private(set) var current: String?
    /// 每步开始的时刻（1970 起的秒）。跳过的步（如解包已复用）没有。
    public private(set) var started: [String: Double] = [:]
    /// 作业结束的时刻（最后一步的结束）；还在跑为 nil。
    public private(set) var ended: Double?

    public init() {}

    public mutating func ingest(_ event: EngineEvent, now: Double) {
        if event.ev == "plan", let plan = Milestone.plan(event.fields["milestones"]) {
            // 同一组步重发（作业层改标了复用）：只换预计，已走的时间照留；换了一组步才从头记
            if plan.map(\.id) != self.plan.map(\.id) { started = [:]; current = nil; ended = nil }
            self.plan = plan
        }
        if let m = event.fields["milestone"] as? String, !m.isEmpty, m != current {
            current = m
            if started[m] == nil { started[m] = now }
        }
    }

    public mutating func finish(at now: Double) { if ended == nil { ended = now } }

    /// 当前步在计划里的位置（没有计划或还没进第一步为 nil）。
    public var index: Int? { plan.firstIndex { $0.id == current } }

    /// 已做完的一步实际用了多久：从它开始到后面最早开始的那一步（都没开始就到作业结束）；没做过（跳过）为 nil。
    public func duration(_ id: String) -> Double? {
        guard let k = plan.firstIndex(where: { $0.id == id }), let s = started[id] else { return nil }
        let end = plan[(k + 1)...].compactMap { started[$0.id] }.min() ?? ended
        return end.map { max(0, $0 - s) }
    }

    public func estimate(fraction: Double?, now: Double) -> MilestoneEstimate {
        MilestoneEstimate(plan: plan, current: current, started: started, fraction: fraction, now: now)
    }
}
