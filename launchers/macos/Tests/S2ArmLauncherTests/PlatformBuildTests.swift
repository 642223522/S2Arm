import XCTest
import SwiftUI
import AppKit
import Darwin
@testable import S2ArmLauncher

@MainActor final class PlatformBuildTests: XCTestCase {
    func testAndroidAvailabilityFollowsRuntimeAndBlocksStaleBuild() throws {
        let previous = Localization.preference; defer {Localization.preference = previous}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let source = root.appendingPathComponent("source")
        let gradle = source.appendingPathComponent("android/app/build.gradle")
        let activity = source.appendingPathComponent("android/app/src/main/java/org/s2arm/android/LibraryActivity.java")
        try FileManager.default.createDirectory(at:gradle.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:activity.deletingLastPathComponent(),withIntermediateDirectories:true)
        try "// shell only".write(to:gradle,atomically:true,encoding:.utf8)
        let store = Store(privateRoot:root.appendingPathComponent("private"),resources:root.appendingPathComponent("resources"))
        store.language = .simplifiedChinese
        store.preferences.engineDir = source.path
        store.setPlatformConfiguration(.init(enabled:true),for:.android)
        store.games = [.init(id:"game",name:"Game",display:"Game",packages:[],hidden:false,compatibility:"experimental")]
        store.selectedGame = "game"; store.hasImportedKeys = true
        store.platformChecks["android"] = [.init(name:"fixture",ok:true,message:"")]
        store.platformCheckRequests["android"] = NSDictionary(dictionary:store.platformRequest(.android))
        XCTAssertFalse(store.platformAvailable(.android))
        XCTAssertEqual(store.platformUnavailableReason(.android),"即将上线，敬请期待")   // 11-02 维护者：安卓未开放，置灰
        store.selectBuildPlatform(.android)
        XCTAssertEqual(store.buildPlatform,.mac)
        store.buildPlatform = .android // persisted selection from an older engine
        XCTAssertEqual(store.displayedBuildPlatform,.mac)
        XCTAssertFalse(store.canBuildPlatform(.android))
        store.runPlatform(.android,operation:"platformBuild")
        XCTAssertNil(store.executionTask)
        XCTAssertTrue(store.tasks.isEmpty)
        try "// s2arm.nativeMode".write(to:gradle,atomically:true,encoding:.utf8)
        XCTAssertFalse(store.platformAvailable(.android)) // marker alone is insufficient
        try Data().write(to:activity)
        XCTAssertTrue(store.platformAvailable(.android))   // 引擎能力探测照常
        // 11-02 维护者：引擎有了安卓支持也不对玩家开放——选项卡选不中、页面不显示它，原因写「即将上线，敬请期待」；执行层仍按引擎探测
        XCTAssertFalse(store.platformSelectable(.android))
        XCTAssertEqual(store.platformUnavailableReason(.android),"即将上线，敬请期待")
        store.selectBuildPlatform(.android)
        XCTAssertEqual(store.displayedBuildPlatform,.mac)
        XCTAssertTrue(store.canBuildPlatform(.android))
        try FileManager.default.removeItem(at:activity)
        XCTAssertFalse(store.canBuildPlatform(.android)) // a stale green check cannot start a build
        store.runPlatform(.android,operation:"platformBuild")
        XCTAssertNil(store.executionTask)
        // 可选实树核验：同一个页面分别指向当前源码和带运行时的叠层。
        if let absent = ProcessInfo.processInfo.environment["S2A_TEST_ANDROID_ABSENT_ENGINE"],
           let present = ProcessInfo.processInfo.environment["S2A_TEST_ANDROID_PRESENT_ENGINE"] {
            for (label,path,expected) in [("absent",absent,false),("present",present,true)] {
                store.preferences.engineDir = path
                XCTAssertEqual(store.platformAvailable(.android),expected,label)
                store.buildPlatform = .ios
                store.selectBuildPlatform(.android)
                XCTAssertEqual(store.displayedBuildPlatform,.ios,label)   // 安卓未开放：探测到支持也选不中
                let view = NSHostingView(rootView:PlatformBuildView().environmentObject(store).frame(width:1000,height:900).background(LibraryBackdrop()))
                view.frame = NSRect(x:0,y:0,width:1000,height:900); view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
                view.cacheDisplay(in:view.bounds,to:bitmap)
                if let directory = ProcessInfo.processInfo.environment["S2A_TEST_ANDROID_PREVIEWS"] {
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:directory).appendingPathComponent("android-\(label).png"))
                }
                print("Android actual engine \(label): available=\(expected)")
            }
        }
    }
    func testSourceToolFailureUsesEnglishSummaryAndSuggestion() {
        let previous=Localization.preference;defer {Localization.preference=previous}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-tool-error-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        store.language = .english
        let summary="S2Arm 工具退出，当前阶段未完成。"
        let suggestion="检查环境和输入文件，查看对应日志后重试。"
        store.error=summary
        store.errorDiagnostic = .init(code:"tool_exit",severity:"error",summary:summary,suggestion:suggestion,detail:"")
        XCTAssertEqual(L(summary),"The S2Arm tool exited before completing this stage.")
        XCTAssertTrue(store.failureMessage.contains("Check the environment and input files, review the task log, then retry."))
        XCTAssertFalse(store.failureMessage.contains(summary))
        XCTAssertFalse(store.failureMessage.contains(suggestion))
    }
    func testOptionalPlatformsPersistAndInvalidateReadinessWhenSettingsChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = Store(privateRoot:root)
        let legacy = try JSONDecoder().decode(Preferences.self,from:Data(#"{"library":"","libraryId":"","developerDir":"","onboardingComplete":true}"#.utf8))
        XCTAssertNil(legacy.platformBuilds)
        XCTAssertTrue(store.platformConfiguration(.mac).enabled)
        XCTAssertEqual(store.buildPlatform,.mac)
        XCTAssertTrue(store.platformConfiguration(.ios).enabled, "iOS 是主产品，缺省启用（审计 P2-8）")
        XCTAssertTrue([BuildPlatform.android,.ohos].allSatisfy{!store.platformConfiguration($0).enabled})
        var config = PlatformBuildConfiguration()
        config.enabled = true
        store.setPlatformConfiguration(config,for:.ohos)
        store.platformChecks["ohos"] = [.init(name:"fixture",ok:true,message:"")]
        store.platformCheckRequests["ohos"] = NSDictionary(dictionary:store.platformRequest(.ohos))
        XCTAssertTrue(store.canBuildPlatform(.ohos))
        store.preferences.developerDir = "/another/Xcode.app/Contents/Developer"
        XCTAssertFalse(store.canBuildPlatform(.ohos))
        store.savePreferences()
        let reopened = Store(privateRoot:root)
        XCTAssertEqual(reopened.platformConfiguration(.ohos),config)
        XCTAssertFalse(reopened.platformConfiguration(.android).enabled)
        XCTAssertFalse(reopened.canBuildPlatform(.ohos))
        XCTAssertNil(reopened.executionTask)
    }

    func testMacDefaultDoesNotOverwriteExplicitPlatformPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = Store(privateRoot:root)
        store.buildPlatform = .ios
        store.setPlatformConfiguration(.init(enabled:false),for:.mac)
        let reopened = Store(privateRoot:root)
        XCTAssertEqual(reopened.buildPlatform,.ios)
        XCTAssertFalse(reopened.platformConfiguration(.mac).enabled)
        XCTAssertTrue(reopened.platformConfiguration(.ios).enabled, "没显式设过 iOS：取缺省（启用）")
        reopened.preferences.selectedBuildPlatform = "obsolete"
        XCTAssertEqual(reopened.buildPlatform,.mac)
    }

    func testLegacyCompilationPathsAreIgnoredAndPlayerDataIsReused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = Store(privateRoot:root)
        let legacy = Data(#"{"enabled":true,"inputDir":"/player/game","sourceDir":"/legacy/source","outputDir":"/legacy/output","ndkDir":"/legacy/sdk","keysPath":"/legacy/prod.keys","fontsDir":"/legacy/fonts"}"#.utf8)
        store.setPlatformConfiguration(try JSONDecoder().decode(PlatformBuildConfiguration.self,from:legacy),for:.ios)
        store.preferences.fontsDir = "/player/shared-fonts"
        let request = store.platformRequest(.ios)
        for key in ["sourceDir","outputDir","ndkDir","inputDir"] {XCTAssertNil(request[key])}
        XCTAssertEqual(request["keysPath"] as? String,root.appendingPathComponent("keys/prod.keys").path)
        XCTAssertEqual(request["fontsDir"] as? String,"/player/shared-fonts")
        XCTAssertNil(store.platformRequest(.android)["inputDir"])
    }

    func testIOSReadinessReusesLibraryKeysEnvironmentAndTargetDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = Store(privateRoot:root)
        store.setPlatformConfiguration(.init(enabled:true),for:.ios)
        store.games = [.init(id:"game",name:"Game",display:"Game",packages:[],hidden:false,compatibility:"experimental")]
        store.selectedGame = "game"
        store.environmentReportComplete = true
        store.checks = [.init(name:"Xcode",ok:true,message:"",requiredFor:["prepare"]),
                        .init(name:".NET SDK",ok:false,message:"",action:"installDotnet",requiredFor:["ipa"])]
        store.hasImportedKeys = true
        let target = IPhoneTarget(model:"iPhone",productType:"iPhone17,1",gpuArch:"apple9",os:26)
        store.chooseTarget(target)
        store.targetProbe.osChoices = [26]
        XCTAssertTrue(store.canBuildPlatform(.ios)) // The existing iPhone action installs the SDK on demand.
        XCTAssertFalse(store.dotnetReady)
        XCTAssertEqual(store.currentPlatformChecks(.ios).count,2)
        store.targetProbe.osChoices = [25]
        XCTAssertTrue(store.canBuildPlatform(.ios)) // 一包通用（10-30）：直连包按 iOS 18 下限编，目标系统比 Xcode SDK 新也照出
        store.targetProbe.osChoices = [26]
        store.hasImportedKeys = false
        XCTAssertFalse(store.canBuildPlatform(.ios))
        store.hasImportedKeys = true
        store.selectedGame = nil
        XCTAssertFalse(store.canBuildPlatform(.ios))
        let reopened = Store(privateRoot:root)
        XCTAssertEqual(reopened.preferences.iphoneTarget,target)
        XCTAssertTrue(reopened.platformConfiguration(.ios).enabled)
    }

    // 10-25 维护者：四个选项 iOS / iPad、Mac、安卓、鸿蒙；出不了能玩的包的置灰并写原因；Mac 复用游戏库的「准备」（同一套环境检查、要游戏可准备）
    func testFourTargetsMacReusesPrepareAndUnplayableTargetsAreGreyed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        XCTAssertEqual(BuildPlatform.allCases.map(\.rawValue),["ios","mac","android","ohos"])
        let store = Store(privateRoot:root)
        XCTAssertTrue(store.platformAvailable(.ios)); XCTAssertTrue(store.platformAvailable(.mac))
        XCTAssertNil(store.platformUnavailableReason(.ios)); XCTAssertNil(store.platformUnavailableReason(.mac))
        XCTAssertFalse(store.platformAvailable(.ohos)); XCTAssertNotNil(store.platformUnavailableReason(.ohos))
        // 11-02 维护者：iPhone / iPad、Mac 开放；安卓、鸿蒙置灰，写「即将上线，敬请期待」
        XCTAssertEqual(BuildPlatform.allCases.filter(\.released),[.ios,.mac])
        XCTAssertEqual(BuildPlatform.ios.name,L("iPhone / iPad"))
        for p in [BuildPlatform.android,.ohos] { XCTAssertFalse(store.platformSelectable(p)); XCTAssertEqual(store.platformUnavailableReason(p),L("即将上线，敬请期待")) }
        store.setPlatformConfiguration(.init(enabled:true),for:.mac)
        store.games = [.init(id:"game",name:"Game",display:"Game",packages:[],hidden:false,compatibility:"experimental")]
        store.selectedGame = "game"
        store.environmentReportComplete = true
        store.checks = [.init(name:"Xcode",ok:true,message:"",requiredFor:["prepare"]),
                        .init(name:".NET SDK",ok:false,message:"",action:"installDotnet",requiredFor:["ipa"])]
        store.hasImportedKeys = true
        XCTAssertTrue(store.canBuildPlatform(.mac))   // 不要 iPhone 目标设备、不看出包专用的检查项
        XCTAssertEqual(store.currentPlatformChecks(.mac).map(\.name),["Xcode"])
        store.hasImportedKeys = false
        XCTAssertFalse(store.canBuildPlatform(.mac))
        store.hasImportedKeys = true
        store.selectedGame = nil
        XCTAssertFalse(store.canBuildPlatform(.mac))
    }

    func testPlatformTasksRemainVisibleWithUpstreamTaskFiltering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = Store(privateRoot:root)
        store.tasks = ["platformSource","platformSetup","platformBuild","platformCheck","ipa","installDotnet"].map {
            TaskRecord(id:$0,operation:$0,state:"completed")
        }
        XCTAssertEqual(Set(store.visibleTasks.map(\.operation)),["platformSource","platformSetup","platformBuild","ipa","installDotnet"])
    }

    func testPackagedAvailabilityUsesBundledOrManagedComponentsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let resources = root.appendingPathComponent("Resources")
        let external = root.appendingPathComponent("old-checkout")
        let entry = BuildPlatform.android.entry
        try FileManager.default.createDirectory(at:resources.appendingPathComponent("Engine"),withIntermediateDirectories:true)
        try Data("{}".utf8).write(to:resources.appendingPathComponent("Engine/engine.json"))
        try FileManager.default.createDirectory(at:external.appendingPathComponent(entry).deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data().write(to:external.appendingPathComponent(entry))
        let store = Store(privateRoot:root.appendingPathComponent("private"),resources:resources)
        store.preferences.engineDir = external.path
        XCTAssertFalse(store.platformComponentsAvailable(.android))
        let managed = store.privateRoot.appendingPathComponent("platform-sources/android").appendingPathComponent(entry)
        try FileManager.default.createDirectory(at:managed.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data().write(to:managed)
        XCTAssertFalse(store.platformComponentsAvailable(.android)) // 不混用单独下载的源码与内置引擎
    }

    func testAndroidRuntimeProbeUsesBundledEngineBeforeExternalCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let resources = root.appendingPathComponent("Resources")
        let bundled = resources.appendingPathComponent("Engine")
        let external = root.appendingPathComponent("checkout")
        let gradle = "android/app/build.gradle"
        let activity = "android/app/src/main/java/org/s2arm/android/LibraryActivity.java"
        for engine in [bundled,external] {
            for path in [gradle,activity] {
                try FileManager.default.createDirectory(at:engine.appendingPathComponent(path).deletingLastPathComponent(),withIntermediateDirectories:true)
            }
        }
        try Data("{}".utf8).write(to:bundled.appendingPathComponent("engine.json"))
        try Data("s2arm.nativeMode".utf8).write(to:external.appendingPathComponent(gradle))
        try Data().write(to:external.appendingPathComponent(activity))
        let store = Store(privateRoot:root.appendingPathComponent("private"),resources:resources)
        store.preferences.engineDir = external.path
        XCTAssertFalse(store.platformAvailable(.android)) // 有外部运行时也不能替代内置引擎
        try Data().write(to:bundled.appendingPathComponent(activity))
        XCTAssertFalse(store.platformAvailable(.android)) // 缺 build.gradle
        try Data("s2arm.nativeMode".utf8).write(to:bundled.appendingPathComponent(gradle))
        XCTAssertTrue(store.platformAvailable(.android))
        try FileManager.default.removeItem(at:bundled.appendingPathComponent(activity))
        try FileManager.default.createDirectory(at:bundled.appendingPathComponent(activity),withIntermediateDirectories:true)
        XCTAssertFalse(store.platformAvailable(.android)) // is_file，目录不能冒充文件
    }

    func testActualGUIWorkerChecksDispatchesAndRecoversWithoutMacLibrary() async throws {
        // Foundation preserves /var aliases; Python Path.resolve uses realpath.
        let temporary = try XCTUnwrap(realpath(NSTemporaryDirectory(),nil))
        defer {free(temporary)}
        let root = URL(fileURLWithPath:String(cString:temporary)).appendingPathComponent("s2arm-gui-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let source = root.appendingPathComponent("source with spaces")
        let script = source.appendingPathComponent("runtime/ohos/build.sh")
        let ndk = root.appendingPathComponent("private/toolchains/ohos/native")
        try FileManager.default.createDirectory(at:script.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:ndk.appendingPathComponent("sysroot"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:ndk.appendingPathComponent("llvm/bin"),withIntermediateDirectories:true)
        try "#!/bin/sh\nexit 0\n".write(to:ndk.appendingPathComponent("llvm/bin/clang"),atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:ndk.appendingPathComponent("llvm/bin/clang").path)
        // A fixture source entry proves the frontend calls the script with its
        // paths/environment; no compiler, game, SDK download or device is used.
        try "mkdir -p \"$1\"\nprintf '%s' \"$OHOS_NDK\" > \"$1/called.o\"\n".write(to:script,atomically:true,encoding:.utf8)
        let store = Store(privateRoot:root.appendingPathComponent("private"))
        store.preferences.engineDir = source.path
        let config = PlatformBuildConfiguration(enabled:true)
        store.setPlatformConfiguration(config,for:.ohos)
        store.runPlatform(.ohos,operation:"platformCheck")
        for _ in 0..<200 where store.executionBusy {try await Task.sleep(for:.milliseconds(50))}
        XCTAssertTrue(store.canBuildPlatform(.ohos),store.errorDiagnostic?.detail ?? store.error ?? "check did not complete")
        store.runPlatform(.ohos,operation:"platformBuild")
        for _ in 0..<200 where store.executionBusy {try await Task.sleep(for:.milliseconds(50))}
        XCTAssertNil(store.executionTask)
        XCTAssertEqual(store.tasks.first?.state,"completed",store.error ?? "")
        let output = store.privateRoot.appendingPathComponent("exports/ohos/native")
        XCTAssertEqual(try String(contentsOf:output.appendingPathComponent("called.o"),encoding:.utf8),ndk.path)
        let reopened = Store(privateRoot:store.privateRoot)
        XCTAssertEqual(reopened.tasks.first?.target,"ohos")
        XCTAssertEqual(reopened.tasks.first?.outputPath,output.path)
        reopened.retry(try XCTUnwrap(reopened.tasks.first))
        XCTAssertEqual(reopened.selection,"platforms")
        XCTAssertEqual(reopened.buildPlatform,.ohos)
        XCTAssertTrue(reopened.preferences.library.isEmpty)
    }

    func testPlatformViewsRenderInBothLanguages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let previous = Localization.preference
        defer {Localization.preference = previous}
        let store = Store(privateRoot:root)
        for language in [AppLanguage.simplifiedChinese,.english] {
            Localization.preference = language
            for platform in BuildPlatform.allCases {
                store.buildPlatform = platform
                store.setPlatformConfiguration(.init(enabled:true),for:platform)
                let view = NSHostingView(rootView:PlatformBuildView().environmentObject(store).frame(width:870,height:1150).background(LibraryBackdrop()))
                view.frame = NSRect(x:0,y:0,width:870,height:1150)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
                view.cacheDisplay(in:view.bounds,to:bitmap)
                let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
                if let directory = ProcessInfo.processInfo.environment["S2ARM_GUI_PREVIEW_DIR"] {
                    let output = URL(fileURLWithPath:directory)
                    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                    try png.write(to:output.appendingPathComponent("\(platform.rawValue)-\(language.rawValue).png"))
                }
            }
        }
        // The shared iPhone target row starts a read-only device/SDK probe.
        for _ in 0..<400 where !store.processes.isEmpty {try await Task.sleep(for:.milliseconds(50))}
        XCTAssertTrue(store.processes.isEmpty)
    }

    /// 出 iPhone 包进行中的整屏（卡片 + 窗口底部任务条），按 870×1150 内容区出预览图（S2ARM_GUI_PREVIEW_DIR）
    func testRunningIPhonePackPagePreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let previous = Localization.preference
        defer {Localization.preference = previous}
        let store = Store(privateRoot:root)
        store.games = [Game(id:"hades", name:"Hades", display:"Hades", packages:[], hidden:false)]
        store.selectedGame = "hades"; store.selection = "platforms"
        store.buildPlatform = .ios
        store.setPlatformConfiguration(.init(enabled:true),for:.ios)
        let now = Date().timeIntervalSince1970
        // 与 pack/jobs/milestones.py PLANS["ipa_dual"] 同形；本机没有出包记录（expected = nil、source = none）：页面上不许出现预计时间
        let ids = [("unpack","解包"),("refresh","改写与准备资源"),("direct","直连着色器库"),("ipa","编 App 与签名")]
        let plan = ids.map { Milestone(id:$0.0, label:$0.1, purpose:$0.0 == "direct" ? "按游戏文件出直连着色器库。" : "",
                                       expected:nil, source:"none", samples:0, basis:"本机还没有这一步的记录") }
        let space = Store.decode(SpaceBudget.self, ["gameBytes":6_200_000_000, "volumes":[["role":"library","volume":"系统盘","needBytes":24_000_000_000,
            "freeBytes":300_000_000_000,"enough":true,"basis":"rule","note":"游戏大小 × 2 + 10 GB 经验门槛（10-23 Spare-host 实测，偏保守）","unknown":["shader_cache"]]],
            "unknown":[["id":"shader_cache","role":"library","label":"着色器缓存","note":"着色器缓存另占若干 GB，随游戏与设备而变，未量化，不计入门槛。"]]] as [String:Any])
        store.tasks = [TaskRecord(id:"t", operation:"ipa", state:"running", gameId:"hades", stage:"直连着色器库", message:"直连着色器库",
                                  stageIndex:3, stageCount:4, started:now-300, done:1200, total:48000, unit:"shaders", space:space,
                                  milestones:plan, milestone:"direct",
                                  milestoneStarted:["unpack":now-300,"refresh":now-260,"direct":now-60])]
        // 页面已整卡显示这个任务：窗口底部任务条不出（与 Views.swift 的显示条件同一判据）
        XCTAssertEqual(store.pageTask?.id, "t")
        XCTAssertFalse(store.activeTasks.contains(where:{$0.id != store.pageTask?.id}))
        for language in [AppLanguage.simplifiedChinese,.english] {
            Localization.preference = language
            for (name,height) in [("window",1150.0),("full",2400.0)] {
                let page = VStack(spacing:0) { PlatformBuildView() }.environmentObject(store)
                    .frame(width:870,height:height).background(LibraryBackdrop())
                let view = NSHostingView(rootView:page)
                view.frame = NSRect(x:0,y:0,width:870,height:height)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
                view.cacheDisplay(in:view.bounds,to:bitmap)
                let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
                if let directory = ProcessInfo.processInfo.environment["S2ARM_GUI_PREVIEW_DIR"] {
                    let output = URL(fileURLWithPath:directory)
                    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                    try png.write(to:output.appendingPathComponent("ios-packing-\(name)-\(language.rawValue).png"))
                }
                // 一屏判据：在 2400 高的纯白底上排同一页，从下往上找第一行非白像素 = 页面内容的实际底边（读渲染结果，不是估）
                if name == "full" {
                    let probe = NSHostingView(rootView:PlatformBuildView().environmentObject(store).frame(width:870,height:height).background(Color.white)
                        .environment(\.colorScheme,.light))
                    probe.appearance = NSAppearance(named:.aqua)
                    probe.frame = NSRect(x:0,y:0,width:870,height:height); probe.layoutSubtreeIfNeeded()
                    let rep = try XCTUnwrap(probe.bitmapImageRepForCachingDisplay(in:probe.bounds)); probe.cacheDisplay(in:probe.bounds,to:rep)
                    let scale = Double(rep.pixelsHigh) / height
                    func inkBottom(_ image:NSBitmapImageRep)->Int {
                        for y in stride(from:image.pixelsHigh - 1, through:0, by:-1) {
                            for x in stride(from:0, to:image.pixelsWide, by:2) {
                                if let c=image.colorAt(x:x,y:y), c.redComponent+c.greenComponent+c.blueComponent < 2.9 {return y}
                            }
                        }
                        return 0
                    }
                    // Empty-image negative control replaces a minimum page height: compact content may be <600 pt.
                    let blank=NSHostingView(rootView:Color.white.frame(width:870,height:height))
                    blank.frame=probe.frame;blank.layoutSubtreeIfNeeded()
                    let blankRep=try XCTUnwrap(blank.bitmapImageRepForCachingDisplay(in:blank.bounds))
                    blank.cacheDisplay(in:blank.bounds,to:blankRep)
                    XCTAssertEqual(inkBottom(blankRep),0,"空白负控必须被判为空白")
                    let contentHeight=Double(inkBottom(rep))/scale
                    print("ios-packing \(language.rawValue): content bottom at \(contentHeight) pt")
                    XCTAssertGreaterThan(contentHeight, 0, "页面没有绘出内容")
                    XCTAssertLessThanOrEqual(contentHeight, 668, "\(language.rawValue)：出包中的页面超出最小窗口内容区（720 − 52 点标题栏）")
                }
            }
        }
        for _ in 0..<400 where !store.processes.isEmpty {try await Task.sleep(for:.milliseconds(50))}
    }

    // 一包通用（10-30 维护者）：出 iPhone 包不依赖目标设备；有目标才带进请求（只用来提示地址窗口），没有照样能出
    func testIPhonePackDoesNotRequireTargetDevice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = Store(privateRoot:root)
        store.setPlatformConfiguration(.init(enabled:true),for:.ios)
        let game = Game(id:"game",name:"Game",display:"Game",packages:[],hidden:false,compatibility:"experimental")
        store.games = [game]; store.selectedGame = "game"
        store.environmentReportComplete = true
        store.checks = [.init(name:"Xcode",ok:true,message:"",requiredFor:["prepare"])]
        store.hasImportedKeys = true
        store.preferences.iphoneTarget = nil; store.targetProbe = TargetProbe()
        XCTAssertNil(store.iphoneTarget)
        XCTAssertTrue(store.canBuildPlatform(.ios))
        XCTAssertNil(store.ipaRequest(game, target:nil)["target"])
        XCTAssertEqual(store.ipaRequest(game, target:nil)["gameId"] as? String, "game")
        let target = IPhoneTarget(model:"iPhone",productType:"iPhone18,2",gpuArch:"applegpu_g18p",os:27)
        let sent = store.ipaRequest(game, target:target)["target"] as? [String:Any]
        XCTAssertEqual(sent?["gpuArch"] as? String, "applegpu_g18p")
        XCTAssertEqual(sent?["os"] as? Int, 27)
        // 「装到 iPhone」照常选设备：选过的机型仍记住、仍是 iphoneTarget
        store.chooseTarget(target)
        XCTAssertEqual(store.iphoneTarget, target)
        XCTAssertEqual(Store(privateRoot:root).preferences.iphoneTarget, target)
    }

    // T76/#740：选中逻辑三条分支（不改 Store 运行时；只钉住 iphoneTarget 计算属性）
    func testIphoneTargetSelectsSoleConnectedDevice() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-t76-one-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        let only = IPhoneTarget(model: "fixture-a", productType: "iPhone18,2", gpuArch: "applegpu_g18p", os: 27, connected: true, deviceName: "A")
        store.targetProbe = TargetProbe(connected: [only], models: [], osChoices: [27])
        store.preferences.iphoneTarget = nil
        XCTAssertEqual(store.iphoneTarget, only)
    }

    func testIphoneTargetPicksAnyWhenTwoSameArchAndOs() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-t76-same-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        let a = IPhoneTarget(model: "fixture-a", productType: "iPhone18,2", gpuArch: "applegpu_g18p", os: 27, connected: true, deviceName: "A")
        let b = IPhoneTarget(model: "fixture-b", productType: "iPhone18,2", gpuArch: "applegpu_g18p", os: 27, connected: true, deviceName: "B")
        store.targetProbe = TargetProbe(connected: [a, b], models: [], osChoices: [27])
        store.preferences.iphoneTarget = nil
        let picked = store.iphoneTarget
        XCTAssertNotNil(picked)
        XCTAssertTrue(picked == a || picked == b, "同架构同系统应自动选中其中一台，实际 \(String(describing: picked))")
        XCTAssertEqual(picked?.gpuArch, "applegpu_g18p")
        XCTAssertEqual(picked?.os, 27)
    }

    func testIphoneTargetFallsBackToPreferenceWhenTwoDifferentArch() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-t76-diff-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(privateRoot: root)
        let a = IPhoneTarget(model: "fixture-a", productType: "iPhone18,2", gpuArch: "applegpu_g18p", os: 27, connected: true, deviceName: "A")
        let b = IPhoneTarget(model: "fixture-b", productType: "iPad16,3", gpuArch: "applegpu_g17p", os: 27, connected: true, deviceName: "B")
        store.targetProbe = TargetProbe(connected: [a, b], models: [], osChoices: [27])
        // 无记忆 → nil
        store.preferences.iphoneTarget = nil
        XCTAssertNil(store.iphoneTarget)
        // 有记忆且与其中一台 arch+os 一致 → 用记忆
        let remembered = IPhoneTarget(model: "remembered", productType: "iPad16,3", gpuArch: "applegpu_g17p", os: 27)
        store.preferences.iphoneTarget = remembered
        XCTAssertEqual(store.iphoneTarget, remembered)
    }
}
