import XCTest
@testable import S2ArmLauncher

/// Integration checks use the real shared document and the real SwiftPM resource.
final class SharedExperienceTests: XCTestCase {
    private var sourceURL: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("launchers/shared/experience.v1.json")
    }

    func testBundledDocumentIsAnOrdinaryCopyOfTheSharedOriginal() throws {
        let resource = try SharedExperience.resourceURL()
        XCTAssertEqual(try resource.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, false)
        XCTAssertEqual(try Data(contentsOf: resource), try Data(contentsOf: sourceURL))
    }

    func testMissingAndTruncatedRealResourceThrowWithoutTerminatingTests() throws {
        let resource = try SharedExperience.resourceURL()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent(resource.lastPathComponent)
        try FileManager.default.copyItem(at: resource, to: copy)
        let valid = try SharedExperience.load(from: copy)
        try FileManager.default.removeItem(at: copy)
        XCTAssertThrowsError(try SharedExperience.load(from: copy))
        // Corrupt the actual document by truncating its bytes, without inventing a replacement schema.
        try Data(contentsOf: resource).prefix(128).write(to: copy)
        XCTAssertThrowsError(try SharedExperience.load(from: copy))
        try Data(contentsOf: resource).write(to: copy)
        XCTAssertEqual(try SharedExperience.load(from: copy).revision, valid.revision)
    }

    func testSharedDocumentReachesPresentationInBothLanguages() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceURL)) as? [String: Any])
        let stages = try XCTUnwrap(json["stage_labels"] as? [String: [String: String]])
        let states = try XCTUnwrap(json["states"] as? [[String: Any]])
        let eventMap = try XCTUnwrap(json["event_map"] as? [String: Any])
        let results = try XCTUnwrap(eventMap["terminal_results"] as? [String: Any])
        let pack = try XCTUnwrap(json["pack_graphics_mode"] as? [String: Any])
        let labels = try XCTUnwrap(pack["labels"] as? [String: [String: String]])
        let oldPreference = Localization.preference
        defer { Localization.preference = oldPreference }
        for language in [AppLanguage.english, .simplifiedChinese] {
            Localization.preference = language
            let key = language.rawValue
            for state in states {
                let id = try XCTUnwrap(state["id"] as? String)
                let title = try XCTUnwrap(state["title"] as? [String: String])
                XCTAssertEqual(SharedExperience.stateTitle(id), title[key])
            }
            for (id, label) in stages {
                XCTAssertEqual(SharedExperience.stageLabel(id), label[key])
                XCTAssertEqual(SharedExperience.stageLabel(try XCTUnwrap(label["zh-Hans"])), label[key])
            }
            for id in ["job.succeeded", "job.cancelled"] {
                let result = try XCTUnwrap(results[id] as? [String: Any])
                let title = try XCTUnwrap(result["title"] as? [String: String])
                XCTAssertEqual(SharedExperience.terminalTitle(id), title[key])
            }
            XCTAssertEqual(PackGraphicsMode.direct.title, labels["direct"]?[key])
            XCTAssertEqual(PackGraphicsMode.unknown.title, labels["unknown"]?[key])
            XCTAssertEqual(Set(labels.keys), ["direct", "unknown"])
        }
        XCTAssertEqual(SharedExperience.specification.revision, json["revision"] as? Int)
    }
}
