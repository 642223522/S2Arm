import Foundation
import S2ArmAppleAdapter

/// Presentation data shared with the other launchers. Job state and progress remain worker data.
enum SharedExperience {
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("S2Arm shared experience: " + message + "\n").utf8))
        exit(1)
    }
    struct ResourceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ResourceError(message: message) }
    }
    struct Text: Decodable {
        let chinese: String
        let english: String
        enum CodingKeys: String, CodingKey { case chinese = "zh-Hans", english = "en" }
        var localized: String { Localization.language == "zh-Hans" ? chinese : english }
    }
    struct Item: Decodable { let id: String; let title: Text }
    struct PackMode: Decodable { let labels: [String: Text] }
    struct Terminal: Decodable { let title: Text }
    struct Events: Decodable {
        let terminalResults: [String: Terminal]
        enum CodingKeys: String, CodingKey { case terminalResults = "terminal_results" }
        enum ResultKeys: String, CodingKey { case succeeded = "job.succeeded", cancelled = "job.cancelled" }
        init(from decoder: Decoder) throws {
            let events = try decoder.container(keyedBy: CodingKeys.self)
            let results = try events.nestedContainer(keyedBy: ResultKeys.self, forKey: .terminalResults)
            terminalResults = [ResultKeys.succeeded.rawValue: try results.decode(Terminal.self, forKey: .succeeded),
                               ResultKeys.cancelled.rawValue: try results.decode(Terminal.self, forKey: .cancelled)]
        }
    }
    struct Specification: Decodable {
        let schema: Int
        let contract: String
        let revision: Int
        let states: [Item]
        let packGraphicsMode: PackMode
        let stageLabels: [String: Text]
        let eventMap: Events
        enum CodingKeys: String, CodingKey {
            case schema, contract, revision, states
            case packGraphicsMode = "pack_graphics_mode"
            case stageLabels = "stage_labels", eventMap = "event_map"
        }
    }

    /// 规格随适配层资源包出（BackendText：新旧前端共用一份；.app 里缺了明说，不回落源码路径）。
    static func resourceURL() throws -> URL { try BackendText.experienceURL() }

    /// Throwing loader lets callers report resource errors without terminating XCTest.
    static func load(from url: URL) throws -> Specification {
        let spec = try JSONDecoder().decode(Specification.self, from: Data(contentsOf: url))
        try require(spec.schema == 1 && spec.contract == "s2a.experience.v1" && spec.revision >= 4,
                    "S2Arm shared experience contract is invalid")
        try require(Set(spec.states.map(\.id)).count == spec.states.count, "Duplicate shared experience state")
        for id in ["idle", "keys_missing", "importing", "preparing", "ready", "running", "failed", "recovering"] {
            try require(spec.states.contains { $0.id == id }, "Missing shared experience state: \(id)")
        }
        for id in ["direct", "unknown"] {
            try require(spec.packGraphicsMode.labels[id] != nil, "Missing pack graphics label: \(id)")
        }
        for id in ["job.succeeded", "job.cancelled"] {
            try require(spec.eventMap.terminalResults[id] != nil, "Missing terminal result: \(id)")
        }
        for id in ["input.validate", "input.unpack", "rewrite", "sysdata", "uilayout", "romfsidx",
                   "direct", "bundle.ipa", "job"] {
            try require(spec.stageLabels[id] != nil, "Missing shared stage label: \(id)")
        }
        let texts = spec.states.map(\.title)
            + Array(spec.packGraphicsMode.labels.values) + Array(spec.stageLabels.values)
            + spec.eventMap.terminalResults.values.map(\.title)
        try require(texts.allSatisfy { !$0.chinese.isEmpty && !$0.english.isEmpty }, "Shared presentation text is empty")
        return spec
    }

    static let specification: Specification = {
        do { return try load(from: resourceURL()) }
        catch { fail("Specification is invalid: \(error)") }
    }()

    static func stateTitle(_ id: String) -> String {
        guard let state = specification.states.first(where: { $0.id == id }) else {
            fail("Unknown state: \(id)")
        }
        return state.title.localized
    }
    static func packLabel(_ id: String) -> String {
        guard let text = specification.packGraphicsMode.labels[id] else { fail("Unknown pack graphics label: \(id)") }
        return text.localized
    }
    static func terminalTitle(_ id: String) -> String {
        guard let result = specification.eventMap.terminalResults[id] else { fail("Unknown terminal result: \(id)") }
        return result.title.localized
    }
    static func stageLabel(_ value: String) -> String {
        if let text = specification.stageLabels[value] { return text.localized }
        // Legacy GUI milestones carry a canonical display label instead of a protocol stageId.
        if let text = specification.stageLabels.values.first(where: { $0.chinese == value }) { return text.localized }
        return L(value) // Mac-only milestones and worker-provided details keep their existing presentation.
    }
}
