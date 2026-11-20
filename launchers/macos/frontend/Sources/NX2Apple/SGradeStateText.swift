// S2Arm（不是上游文件）：S 级优化每一类（满屏 / 帧率 / 画面）此刻是什么状态、给玩家看哪一句（三端状态与文案对照定稿）。
//   数据来自作业层 describe_game 的 sgradeState（作业层，pack/jobs/community.py）；同一状态在设置、出包页、升级页说同一句（文案键 sgrade.state.*）。
//   纯函数：输入一类的状态字典，输出那一句 + 要不要给「重新打开」（作业 sgradeReenable 的 key）。没有 sgradeState（作业层还没出这个字段）= 不画
import Foundation

struct SGradeCategoryState: Equatable {
    var state = ""            // on / ineffective / off_user / off_auto / version / none / opted_out / pending / mac_only / unknown
    var source = ""           // 满屏：patch / own / none
    var active = ""           // 满屏：adaptive（按屏幕比例自动选）/ fixed（固定画幅）/ own
    var target = 0            // 帧率：在用的档（active.pick；"0" = 自动 → 取 levels 最高档）
    var lastRun = ""          // 上一局结果原句（作业层 patch_result，中文原句，界面经 BackendText 翻）
    var autoOffCause = "", autoOffAt: Date? = nil
    var mine = "", available: [String] = [], port = ""
    var fiSupported: Bool? = nil   // 帧率：设备能不能补帧（作业层 fiSupported，Mac 按 macOS 26 起；没给 = nil，按能补帧算）
    var failedWhy = ""             // 没能打入（state = failed）的第一条原因：文案键 result.why.*（作业层 sgrade.fps_failed）

    init(_ raw: [String: Any]) {
        state = raw["state"] as? String ?? ""; source = raw["source"] as? String ?? ""
        // 作业层 feat/sgrade-state 口径：满屏 active 是字符串；帧率 active 是 {levels: [60, 120], pick: "0" | "60" | "120"}；gfx / cheats 是开着的编号列表
        if let a = raw["active"] as? String { active = a }
        if let fps = raw["active"] as? [String: Any] {
            let levels = (fps["levels"] as? [NSNumber] ?? []).map(\.intValue), pick = Int(fps["pick"] as? String ?? "") ?? 0
            target = pick > 0 ? pick : levels.max() ?? 0
        }
        lastRun = raw["lastRun"] as? String ?? (raw["lastRun"] as? [String: Any])?["text"] as? String ?? ""
        let off = raw["autoOff"] as? [String: Any] ?? [:]
        autoOffCause = off["cause"] as? String ?? ""
        autoOffAt = (off["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let v = raw["versions"] as? [String: Any] ?? [:]
        mine = v["mine"] as? String ?? ""; available = v["available"] as? [String] ?? []; port = v["port"] as? String ?? ""
        fiSupported = raw["fiSupported"] as? Bool
        failedWhy = (raw["failed"] as? [[String: Any]])?.first?["why"] as? String ?? ""
    }
}

enum SGradeStateText {
    /// 版本号按段比较（1.10 > 1.9；段数不同短的补 0）
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    /// 版本不同时写哪个版本（维护者 11-15 定）：离玩家最近、且比它新的；全是旧的取最新的旧版本。→ (版本, 是否比玩家新)；没有 = nil
    static func pick(_ available: [String], mine: String) -> (version: String, newer: Bool)? {
        if let v = available.filter({ compare($0, mine) > 0 }).sorted(by: { compare($0, $1) < 0 }).first { return (v, true) }
        return available.sorted { compare($0, $1) < 0 }.last.map { ($0, false) }
    }

    /// 一类的那一句。cat = widescreen / fps / gfx；catName = 这一类给玩家看的名字（export.sgrade.cat.*）；t = 取文案；date = 日期写法；
    ///   backend = 作业层中文原句译成界面语言。→ (那一句, 「重新打开」要传的 key；nil = 不给按钮)；没有可说的 = nil
    static func line(cat: String, catName: String, _ s: SGradeCategoryState, t: (String) -> String,
                     date: (Date) -> String, backend: (String) -> String = { $0 }) -> (text: String, reenable: String?)? {
        func f(_ id: String, _ args: String...) -> String {
            args.enumerated().reduce(t(id)) { $0.replacingOccurrences(of: "{\($1.offset)}", with: $1.element) }
        }
        let key = cat == "widescreen" ? "fullscreen" : cat
        switch s.state {
        case "on":
            if cat == "fps", s.target > 0 { return (f("sgrade.state.on.fps", "\(s.target)"), nil) }
            if cat == "widescreen" {
                if s.source == "own" || s.active == "own" { return (t("sgrade.state.on.own"), nil) }
                return (t(s.active == "fixed" ? "sgrade.state.on.fixed" : "sgrade.state.on.adaptive"), nil)
            }
            return nil
        case "ineffective": return s.lastRun.isEmpty ? nil : (backend(s.lastRun), nil)   // 作业层原句本身就写「没生效：… / 开着，但上一局…」，不再套一层
        case "off_user": return (t("sgrade.state.off_user"), nil)
        case "off_auto":
            let when = s.autoOffAt.map(date) ?? ""
            let cause = s.autoOffCause == "stall" ? "stall" : s.autoOffCause == "widen_fit" ? "widen_fit" : "crash"   // widen_fit：手动开的通用满屏局内没铺满或被拉伸
            return (f("sgrade.state.off_auto." + cause, when), key)
        case "version":
            // 维护者 11-15 定：写离玩家最近、且比它新的那个版本；全是旧版本写「只有旧版本 X 的」，不劝降级
            guard let p = pick(s.available, mine: s.mine) else { return nil }
            var text = p.newer ? f("sgrade.state.version.newer", p.version, s.mine) : f("sgrade.state.version.older", p.version)
            if cat == "widescreen", s.port == "failed" { text += t("sgrade.state.version.port_failed") }
            return (text, nil)
        case "failed":   // 补丁库有、一份没打进去（11-15 #934）：如实写原因，不说成开着生效
            return (f("sgrade.state.failed", catName, s.failedWhy.isEmpty ? t("sgrade.result.why.mismatch") : t("sgrade." + s.failedWhy)), nil)
        case "none": return (f("sgrade.state.none", catName), nil)
        case "opted_out": return (t("sgrade.state.opted_out"), nil)
        case "mac_only": return (t("sgrade.state.mac_only"), nil)
        default: return nil   // pending（Mac 下次起局自动补上，不用说）/ unknown / 还没有这个字段
        }
    }

    /// 启动设置 S 级金卡最上面两行（满屏 / 帧率解锁，11-15 维护者定）的副标题：写现在用的是什么；自动关 / 没生效 / 没打入照状态句。
    ///   与 iPhone ios/sgrade_line.m s2a_sgrade_row_note 同一套判断。→ (那一句, 这一行真用不了要置灰)
    static func rowNote(cat: String, _ s: SGradeCategoryState?, hasFpsPatch: Bool, fpsOn: Bool, t: (String) -> String,
                        date: (Date) -> String, backend: (String) -> String = { $0 }) -> (text: String, disabled: Bool)? {
        let st = s ?? SGradeCategoryState([:])
        if ["off_auto", "ineffective", "opted_out"].contains(st.state),
           let l = line(cat: cat, catName: "", st, t: t, date: date, backend: backend) { return (l.text, false) }
        if cat == "widescreen" {
            if st.source == "patch" { return (t(st.active == "fixed" ? "sgrade.src.fs.fixed" : "sgrade.src.fs.adaptive"), false) }
            return (t("sgrade.src.fs.own"), false)   // 没有社区满屏补丁的款一律走 S2Arm 通用满屏（不看名单）
        }
        guard cat == "fps" else { return nil }
        if st.state == "unsupported" { return (t("sgrade.unavail.fi"), true) }   // 没补丁又不能补帧（作业层定）
        if st.state == "failed", let l = line(cat: cat, catName: t("export.sgrade.cat.fps"), st, t: t, date: date, backend: backend) {
            return (l.text, !(st.fiSupported ?? true))   // 帧率补丁没打进去：写原因；还能补帧就不置灰（开关管补帧）
        }
        let fi = st.fiSupported ?? true
        var src = st.source
        if src.isEmpty { src = hasFpsPatch && fpsOn ? "patch" : fi ? "fi" : "none" }
        let patchLine = st.target > 0 ? t("sgrade.src.fps.patch").replacingOccurrences(of: "{0}", with: String(st.target)) : nil
        let fiLine = t(hasFpsPatch ? "sgrade.src.fps.fi" : "sgrade.src.fps.fi.nopatch")
        if src == "patch" { return (patchLine ?? fiLine, false) }
        if src == "fi" { return (fiLine, false) }
        if hasFpsPatch, let patchLine { return (patchLine, false) }
        if fi { return (fiLine, false) }
        return (t("sgrade.unavail.fi"), true)
    }
}
