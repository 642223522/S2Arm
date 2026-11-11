import Foundation

package struct Stage: Identifiable {
    package let id: Int          // k, the stage number in the script's own plan
    package var name: String
    package var state: StepState = .running
    package var detail: String = ""
    package var percent: Double? = nil
    package var started: Date? = nil   // when the stage began here: its clock runs while the count may stand still
    package var eta: Double? = nil     // the script's estimate of the seconds left, as of etaAt
    package var etaAt: Date? = nil

    package init(id: Int, name: String, state: StepState = .running, detail: String = "", percent: Double? = nil,
                 started: Date? = nil, eta: Double? = nil, etaAt: Date? = nil) {
        self.id = id; self.name = name; self.state = state; self.detail = detail; self.percent = percent
        self.started = started; self.eta = eta; self.etaAt = etaAt
    }

    /// "3:42" since the stage began, then "1 min left" while the script's estimate, counted down from when it came,
    /// lasts: the estimate only arrives with a new count, so one taken as it was would stand still with the count.
    package func clock(at now: Date, left: String) -> String {
        var parts: [String] = []
        if let started {
            let t = max(0, Int(now.timeIntervalSince(started)))
            parts.append(t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60))
        }
        if let eta, let etaAt {
            let remaining = eta - now.timeIntervalSince(etaAt)
            if remaining >= 1 { parts.append(String(format: left, BuildProgress.duration(remaining))) }
        }
        return parts.joined(separator: " · ")
    }
}

/// The state of one stage of a build. Its colour is in the app (`StepState.color`).
package enum StepState: Equatable {
    case pending, running, done, failed
    package var icon: String {
        switch self {
        case .pending: return "circle"
        case .running: return "spinner"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

/// Reading what a build prints: its JSON progress events and durations.
/// a failed install says. Pure functions of the text.
package enum BuildProgress {

    /// "splitting · 1.2 / 3.4 GB", "1,203 / 19,592 shaders", "2,301 files": the step and the count (the time left is the Stage's clock).
    package static func progressDetail(_ e: [String: Any]) -> String {
        let step = e["step"] as? String ?? "", unit = e["unit"] as? String ?? "", note = e["note"] as? String ?? ""
        let done = (e["done"] as? NSNumber)?.doubleValue, total = (e["total"] as? NSNumber)?.doubleValue
        let estimate = (e["est"] as? Bool ?? false) ? "~" : ""
        var count = ""
        if let done {
            if unit == "B" {
                let bytes = { (v: Double) in ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .file) }
                count = total.map { "\(bytes(done)) / \(estimate)\(bytes($0))" } ?? bytes(done)
            } else {
                let number = { (v: Double) in NumberFormatter.localizedString(from: NSNumber(value: Int(v)), number: .decimal) }
                count = (total.map { "\(number(done)) / \(estimate)\(number($0))" } ?? number(done)) + (unit.isEmpty ? "" : " \(unit)")
            }
        }
        return [step, count, note].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    package static func duration(_ seconds: Double) -> String {
        // Formatted by hand, not DateComponentsFormatter: the formatter follows the system
        // locale, so a Chinese macOS wrote "4秒" into a log whose every other line was English
        // (and the test that pinned "4s" failed on any non-English machine). The abbreviations
        // are the interface language's, via the same string table as everything else.
        let s = max(Int(seconds.rounded(.up)), 1)
        if s >= 3600 {
            let h = s / 3600, m = (s % 3600) / 60
            return h > 0 && m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        if s >= 60 {
            let m = s / 60, sec = s % 60
            return sec > 0 ? "\(m)m \(sec)s" : "\(m)m"
        }
        return "\(s)s"
    }

}
