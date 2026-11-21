import XCTest

extension XCTestCase {
    /// 「出完之后」（S2AIosAfterPack）存在测试进程的 UserDefaults 里，会跨用例、跨轮次留下来：哪轮中途被打断，就可能一直是 export（导出自签），
    ///   之后靠「推到 iPhone」才走的路径（准备手机更新、更新 iPhone 走装机）原先被「出完之后」挡掉（11-19 起不再挡，钉着只为用例互不影响）。用到这条路的用例开头钉成 install，结束还原
    func pinIosAfterPackInstall() {
        let key = "S2AIosAfterPack", before = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set("install", forKey: key)
        addTeardownBlock { UserDefaults.standard.set(before, forKey: key) }
    }
}
