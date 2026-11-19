import XCTest
@testable import S2ArmAppleAdapter

/// 作业层文字的翻译（BackendText）：真资源包（Localizable.json + 共享体验规格），期望值按对照表里的英文手写。
final class BackendTextTests: XCTestCase {
    func testUpdatePopupCopyInSixLanguages() {
        let languages = ["zh-Hans", "en", "zh-Hant", "ja", "es", "fr"]
        let expected: [(String, [String])] = [
            ("update.menu.check", ["检查更新", "Check for Updates", "檢查更新", "アップデートを確認", "Buscar actualizaciones", "Rechercher des mises à jour"]),
            ("update.menu.checking", ["正在检查更新", "Checking for Updates", "正在檢查更新", "アップデートを確認中", "Buscando actualizaciones", "Recherche de mises à jour"]),
            ("update.menu.available", ["有新版本可用（v{0}）", "Update Available (v{0})", "有新版本可用（v{0}）", "新しいバージョンがあります（v{0}）", "Actualización disponible (v{0})", "Mise à jour disponible (v{0})"]),
            ("update.menu.downloading", ["正在下载更新（{0}%）", "Downloading Update ({0}%)", "正在下載更新（{0}%）", "アップデートをダウンロード中（{0}%）", "Descargando actualización ({0}%)", "Téléchargement de la mise à jour ({0}%)"]),
            ("update.menu.downloadingPlain", ["正在下载更新", "Downloading Update", "正在下載更新", "アップデートをダウンロード中", "Descargando actualización", "Téléchargement de la mise à jour"]),
            ("update.menu.ready", ["更新已就绪（v{0}）", "Ready to Update (v{0})", "更新已就緒（v{0}）", "アップデートの準備完了（v{0}）", "Listo para actualizar (v{0})", "Prêt à mettre à jour (v{0})"]),
            ("update.upToDate.title", ["已是最新版本", "You’re up to date", "已是最新版本", "最新バージョンです", "Tienes la versión más reciente", "Vous avez la dernière version"]),
            ("update.top.restart", ["重启以更新", "Restart to update", "重啟以更新", "再起動して更新", "Reiniciar para actualizar", "Redémarrer pour mettre à jour"]),
            ("update.checkFailed.title", ["无法检查更新", "Could not check for updates", "無法檢查更新", "アップデートを確認できませんでした", "No se pudo buscar actualizaciones", "Impossible de vérifier les mises à jour"]),
            ("update.popup.close", ["关闭", "Close", "關閉", "閉じる", "Cerrar", "Fermer"]),
            ("update.popup.updateNow", ["立即更新", "Update now", "立即更新", "今すぐ更新", "Actualizar ahora", "Mettre à jour"]),
            ("update.popup.downloadingBtn", ["下载中", "Downloading…", "下載中", "ダウンロード中…", "Descargando…", "Téléchargement…"]),
            ("update.popup.restartNow", ["立即重启", "Restart now", "立即重啟", "今すぐ再起動", "Reiniciar ahora", "Redémarrer"]),
            ("update.popup.retryNow", ["重试", "Retry", "重試", "再試行", "Reintentar", "Réessayer"]),
            ("update.popup.autoRestart", ["下载完自动重启", "Restart automatically when downloaded", "下載完自動重啟", "ダウンロード後に自動で再起動", "Reiniciar automáticamente al descargar", "Redémarrer automatiquement après le téléchargement"]),
        ]
        for (key, translations) in expected {
            for (language, text) in zip(languages, translations) {
                XCTAssertEqual(BackendText.launcherText(key, language: language), text, "\(language) \(key)")
            }
        }
    }

    /// 0.5.1 Sparkle「更新并重启」退出崩溃（11-17）：文案资源第一次用到才读，退出前重画界面时 Sparkle 正换盘上的 .app，读不到就停进程。
    ///   修法是启动时 preload 一次读完；这里核「preload 之后翻译、取界面文案、换语言都不再读资源包」，各语言都走一遍（含叠加语言与回落）
    func testAfterPreloadNothingReadsTheBundle() {
        BackendText.preload()
        let before = BackendText.resourceReads
        for language in ["zh-Hans", "en", "zh-Hant", "ja", "es", "fr"] {   // 界面能选的语言（没有文案文件的未知语言第一次会查一次、读不到不停进程，不在这里）
            _ = BackendText.translate("操作完成", language: language)
            _ = BackendText.translate("上传诊断超过 90 秒还没完成（网络太慢或连接卡住），已停止。可以先导出诊断包，手动发给我们。", language: language)
            _ = BackendText.launcherText("duration.s", language: language)
        }
        XCTAssertEqual(BackendText.resourceReads, before, "preload 之后不该再读资源包（Sparkle 换 .app 时读不到会停进程）")
    }

    /// 共享文案表缺这门语言回落英文、缺键才显示 [键名]（11-14 i18n 打底）：duration.s 只有 zh-Hans / en 两列
    func testLauncherTextFallsBackToEnglish() {
        XCTAssertEqual(BackendText.launcherText("duration.s", language: "zh-Hans"), "{0} 秒")
        XCTAssertEqual(BackendText.launcherText("duration.s", language: "en"), "{0}s")
        XCTAssertEqual(BackendText.launcherText("duration.s", language: "xx"), "{0}s")   // 没有文案文件的语言
        XCTAssertEqual(BackendText.launcherText("no.such.key", language: "xx"), "[no.such.key]")
    }

    /// 作业层拼出来的整句按多占位句式翻，占位里的中文再翻、数字原样（11-14 i18n 第四批：诊断上传总时限）
    func testMultiSlotPatternTranslatesSlots() {
        XCTAssertEqual(BackendText.translate("上传诊断超过 90 秒还没完成（网络太慢或连接卡住），已停止。可以先导出诊断包，手动发给我们。", language: "en"),
                       "Uploading diagnostics didn't finish within 90 seconds (the network is too slow or the connection stalled), so it was stopped. You can export a diagnostic package and send it to us yourself.")
    }

    /// Windows 环境检查「Apple 移动设备支持」：句式 → 「；」拆段 → 每段再套句式（11-14 i18n 第四批 winenv）
    func testAppleDriverCheckedListTranslates() {
        XCTAssertEqual(BackendText.translate("没找到Apple设备支持。查过：本机usbmux端口 127.0.0.1:27015：连不上；服务 Apple Mobile Device Service：已停止；商店版 Apple Devices：没装", language: "en"),
                       "Apple device support not found. Checked: local usbmux port 127.0.0.1:27015: not reachable; Apple Mobile Device Service: stopped; Apple Devices (Store version): not installed")
    }

    /// 出包前空间预算提示：外层句式 → 分项按「；」拆开逐项翻（11-14 i18n：分项分隔由「，」改「；」）
    func testSpaceBudgetWarningTranslates() {
        XCTAssertEqual(BackendText.translate("磁盘空间不够：游戏存放位置所在的盘这次出包预计要 106 GB（解包 12 GB；单一 IMG 边写边腾解包、不另占；直连着色器上限 4 GB），现在只剩 48 GB。已按你的选择仍然继续。", language: "en"),
                       "Not enough disk space: on the drive where the games are stored this build needs about 106 GB (Unpack 12 GB; single IMG written while freeing the unpacked files, no extra space; direct shaders up to 4 GB), but only 48 GB is left. Continuing anyway, as you chose.")
    }

    /// 叠加语言（11-14 加繁中）：资源包里的 l10n.zh-Hant.json 生效；没有文件的语言整表回落英文
    func testOverlayLanguages() {
        XCTAssertEqual(BackendText.launcherText("report.button", language: "zh-Hant"), "故障報修")
        XCTAssertEqual(BackendText.translate("游戏已停止。", language: "zh-Hant"), "遊戲已停止。")
        XCTAssertEqual(BackendText.translate("游戏已停止。", language: "xx"), "Game stopped.")
        XCTAssertEqual(BackendText.launcherText("report.button", language: "xx"), BackendText.launcherText("report.button", language: "en"))
    }

    func testWholeSentenceAndSharedLabels() {
        XCTAssertEqual(BackendText.translate("游戏已停止。", language: "en"), "Game stopped.")
        XCTAssertEqual(BackendText.translate("游戏库所在磁盘", language: "en"), "Library Drive")
        // 共享体验规格里的阶段名与状态名（不在 Localizable.json 里）
        XCTAssertEqual(BackendText.translate("解包", language: "en"), "Unpack")
        XCTAssertEqual(BackendText.translate("运行中", language: "en"), "Running")
    }

    func testIosPlatformItemAndStageHaveEnglish() {
        // 11-08：切到英文后作业页只剩大标题是英文，副标题与日志行还是中文——阶段原句没有对照；项名也漏了 components
        XCTAssertEqual(BackendText.translate("下载 Xcode 的 iOS 平台组件（约 8 GB）", language: "en"),
                       "Downloading Xcode's iOS Platform Components (about 8 GB)")
        XCTAssertEqual(BackendText.translate("iOS 平台组件", language: "en"), "iOS Platform Components")
    }

    func testCheckMessageWithSdkVersionTranslates() {
        // 11-08：环境检查里带版本号的整句原来是中文（模板 {0} 不在对照表里，回退原文）
        XCTAssertEqual(BackendText.translate("已装 Xcode 的 iOS 27.2 平台组件。", language: "en"),
                       "Xcode's iOS 27.2 Platform Components are installed.")
        XCTAssertEqual(BackendText.translate("Xcode 的 iOS 27.2 平台组件还没装（新装或刚升级的 Xcode 要另下）：打 iPhone 包、装到 iPhone 都要用它。点「一键下载」自动安装（苹果官方，约 8 GB，要些时间），下完自动重新检查。只在 Mac 上玩不需要它。", language: "en"),
                       "Xcode's iOS 27.2 Platform Components are not installed (a new or newly upgraded Xcode installs them separately): building iPhone packages and installing to iPhone need them. Click Download to install them automatically (from Apple, about 8 GB; it takes a while); the check runs again when it finishes. Not needed if you only play on this Mac.")
    }

    func testChineseInterfaceKeepsOriginalAndMapsEnglishBack() {
        XCTAssertEqual(BackendText.translate("游戏已停止。", language: "zh-Hans"), "游戏已停止。")
        XCTAssertEqual(BackendText.translate("Game stopped.", language: "zh-Hans"), "游戏已停止。")
        XCTAssertEqual(BackendText.translate("Some text nobody knows", language: "en"), "Some text nobody knows")
    }

    func testTemplatesAndJoinedSentences() {
        XCTAssertEqual(BackendText.translate("托管游戏文件缺失，请重新导入：0100535012974000", language: "en"),
                       "Managed game file is missing, import it again: 0100535012974000")
        // 新前端「这款还缺文件：」+ 作业层的缺件说明（多条用「；」连）
        XCTAssertEqual(BackendText.translate("这款还缺文件：缺游戏本体：只放了更新或 DLC，把本体的 NSP / XCI 也放进来；托管游戏文件缺失，请重新导入：0100", language: "en"),
                       "This game is missing files: Base game missing: only an update or DLC was added. Add the base game’s NSP / XCI too.; Managed game file is missing, import it again: 0100")
        // 准备运行页实测出现过的两行（出包进度计数、复用兄弟平台产物根，后者占位里还套一句定句）
        XCTAssertEqual(BackendText.translate("刷新各阶段 4/11", language: "en"), "Refresh stages 4/11")
        XCTAssertEqual(BackendText.translate("复用兄弟平台的产物根 0100535012974000@rx-9f61ea4e（提交 8607b717c；克隆路线：APFS 克隆 77 项）：平台无关阶段按键核对，键相同跳过、不同照常重做", language: "en"),
                       "Reused the sibling platform's build root 0100535012974000@rx-9f61ea4e (commit 8607b717c; clone route: APFS clone, 77 items): platform-independent stages are checked by key, skipped when equal and redone when different")
        // 占位里的值原样带过去（花括号、$ 不当模板）
        XCTAssertEqual(BackendText.translate("构建工具不可用：{x}$1", language: "en"), "Build tool unavailable: {x}$1")
        // #479：装机遇到带不进的款，作业层按行给固定句式（pack/jobs/ipa.py assemble），英文界面逐行翻、游戏名原样
        XCTAssertEqual(BackendText.translate("手机上有几款游戏这次放不进同一个 App。\n这台电脑上没有它们的 iPhone 版：「丙款」\n它们是旧版 S2Arm 出的 iPhone 版，新版认不得，要重新「打 iPhone 包」：「乙款」\n"
                                             + "确认继续的话，这次先不带它们照装，它们的存档和资源都留在手机上，之后给它们「打 iPhone 包」再装一次就回来。同意一次后，这台手机在这一版 S2Arm 上不再为它们问。", language: "en"),
                       "Some games on the phone can't go into the same app this time.\nThis computer has no iPhone build of: 「丙款」\nBuilt for iPhone by an older S2Arm, which this version can't use. Run \"Build for iPhone\" again for: 「乙款」\n"
                       + "Confirm to install without them this time. Their saves and resources stay on the phone, and they come back once you build them for iPhone and install again. "
                       + "After you agree once, this phone won't ask about them again on this S2Arm version.")
        // 装机遇到库里已删 / 别的电脑装的款（pack/jobs/install.py container_others）：同样按行给固定句式，英文界面逐行翻
        XCTAssertEqual(BackendText.translate("这次装完，手机上这几款游戏会打不开（存档和资源包都还在手机上）。\n它们已从这台电脑的游戏库删除，重新加回游戏库、「打 iPhone 包」再装一次就回来：「乙款」\n确认继续再点一次。", language: "en"),
                       "After this install, these games on the phone won't open (their saves and resources stay on the phone).\n"
                       + "Deleted from this computer's library; they come back once you add them again, \"Build for iPhone\" and install: 「乙款」\nConfirm and try again to continue.")
    }

    func testSharedEntriesComeFromTheSpecification() throws {
        let entries = try BackendText.sharedEntries(Data(contentsOf: BackendText.experienceURL()))
        XCTAssertTrue(entries.contains(BackendText.Entry(source: "解包", en: "Unpack")))
        XCTAssertTrue(entries.contains(BackendText.Entry(source: "运行中", en: "Running")))
        XCTAssertThrowsError(try BackendText.sharedEntries(Data(#"{"states":[{"id":"running","title":{"zh-Hans":"运行中"}}]}"#.utf8)))
    }
}
