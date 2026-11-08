import AppKit
import SwiftUI
import XCTest
@testable import S2ArmLauncher

// 装机步骤页：中英文都能渲染、每条文案都有英文（漏译会原样显示中文）
@MainActor final class InstallGuideTests: XCTestCase {
    func testInstallGuideRendersInChineseAndEnglish() throws {
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:temp)}
        let store=Store(privateRoot:temp)
        store.lastIPAPath=temp.appendingPathComponent("t0100535012974000.ipa")
        let previous=Localization.preference
        defer {Localization.preference=previous}
        for language in [AppLanguage.simplifiedChinese,.english] {
            Localization.preference=language
            let view=NSHostingView(rootView:InstallGuideView().environmentObject(store))
            view.frame=NSRect(x:0,y:0,width:560,height:640);view.layoutSubtreeIfNeeded()
            let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            XCTAssertNotNil(bitmap.representation(using:.png,properties:[:]))
        }
        Localization.preference = .english
        XCTAssertEqual(L("查看装机步骤"),"Install steps")
        for text in InstallGuideView.steps+["把 iPhone 包装到手机","iPhone 装机步骤","在访达中显示 iPhone 包",
            "iPhone 包已出好，在访达里打开了。按装机步骤用 AltStore 装到手机，再把「资源包」文件夹拷进去。"] {
            XCTAssertNotEqual(L(text),text)
        }
    }
}
