import Foundation
import XCTest
@testable import S2ArmLauncher

final class RedactCasesTests: XCTestCase {
    func testSharedRedactionCases() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let table = try String(contentsOf: root.appendingPathComponent("tests/fixtures/redact_cases.tsv"), encoding: .utf8)
        let rows = table.components(separatedBy: "\n")
        XCTAssertEqual(rows.first, "category\tinput\texpected")
        let categories: Set<String> = ["email", "team", "bundle", "udid", "udid_legacy", "device_name"]
        var coverage: [String: (positive: Int, negative: Int)] = [:]
        for (index, row) in rows.dropFirst().enumerated() where !row.isEmpty && !row.hasPrefix("#") {
            let fields = row.components(separatedBy: "\t")
            guard fields.count == 3, categories.contains(fields[0]) else {
                XCTFail("Invalid shared redaction row \(index + 2)")
                throw NSError(domain: "RedactCasesTests", code: 1)
            }
            let category = fields[0], input = fields[1], expected = fields[2]
            let actual = TaskDiagnostic.redact(input, paths: [])
            XCTAssertEqual(Array(actual.utf8), Array(expected.utf8), "\(category) row \(index + 2)")
            var count = coverage[category, default: (0, 0)]
            if input == expected { count.negative += 1 } else { count.positive += 1 }
            coverage[category] = count
        }
        for category in categories {
            let count = coverage[category, default: (0, 0)]
            XCTAssertGreaterThan(count.positive, 0, "\(category) needs a redacted case")
            XCTAssertGreaterThan(count.negative, 0, "\(category) needs an unchanged case")
        }
    }
}
