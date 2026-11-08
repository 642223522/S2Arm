import XCTest
@testable import S2ArmLauncher

@MainActor final class DiagnosticsTests: XCTestCase {
    private func diagnostic(severity: String = "error", path: String? = nil) -> TaskDiagnostic {
        .init(code:"shader_compile_failed",severity:severity,summary:"Metal 着色器编译失败。",suggestion:"在设置中安装 Metal 编译组件，完成后重新检查环境并重试。",detail:"sample.metal:7: error: unknown type",stage:"转换并编译 Metal 着色器",logPath:path,component:"dmsh_build.py",exitCode:1)
    }
    func testFailureEventKeepsDiagnosticLogAndActionableAlert() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-errors-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        let log=root.appendingPathComponent("logs/shader.log").path
        let value=diagnostic(path:log)
        let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
        store.tasks=[.init(id:"build",operation:"build",state:"running")]
        store.event(["schema":1,"taskId":"build","type":"diagnostic","diagnostic":object],visible:true)
        store.event(["schema":1,"taskId":"build","type":"result","state":"failed","message":value.summary],visible:true)
        XCTAssertEqual(store.tasks[0].diagnostics,[value]);XCTAssertEqual(store.errorDiagnostic,value)
        XCTAssertTrue(store.failureMessage.contains("shader_compile_failed"))
        XCTAssertTrue(store.failureMessage.contains(L(value.suggestion)))
        XCTAssertEqual(store.diagnosticLogURL(value).path,URL(fileURLWithPath:log).resolvingSymlinksInPath().path)
        store.showFailedTask();XCTAssertEqual(store.selection,"tasks");XCTAssertNil(store.errorDiagnostic)
    }
    func testResultCanRestoreDiagnosticsWithoutEarlierStreamingEvent() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-result-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root);let value=diagnostic(severity:"warning")
        let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode([value]))
        store.tasks=[.init(id:"build",operation:"build",state:"running")]
        store.event(["schema":1,"taskId":"build","type":"result","state":"completed","diagnostics":object],visible:true)
        XCTAssertTrue(store.tasks[0].hasWarnings);XCTAssertEqual(store.tasks[0].stateName,L("完成（有警告）"))
        XCTAssertNil(store.error)
    }
    func testLegacyJobsDecodeAndLogLinksStayWithinManagedLogLocations() throws {
        let legacy=try JSONDecoder().decode(TaskRecord.self,from:Data(#"{"id":"old","operation":"build","state":"failed"}"#.utf8))
        XCTAssertNil(legacy.diagnostics)
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-log-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        let fallback=root.appendingPathComponent("logs")
        XCTAssertEqual(store.diagnosticLogURL(diagnostic(path:"/etc/hosts")),fallback)
        XCTAssertEqual(store.diagnosticLogURL(diagnostic(path:root.appendingPathComponent("logs/../keys/prod.keys").path)),fallback)
        XCTAssertFalse(diagnostic(path:"/private/secret.log").reportText.contains("/private/secret.log"))
    }
    func testNativeErrorsAreRedactedBeforeCopying() {
        let secret=String(repeating:"a",count:64)
        let raw="header_key = \(secret) password=privatepass /Users/player/library/game.nsp\nAuthorization: Bearer bearer-secret\nhttps://user:linkpass@example.invalid"
        let result=TaskDiagnostic.redact(raw,paths:[("/Users/player/library","[LIBRARY]")])
        XCTAssertFalse(result.contains(secret));XCTAssertFalse(result.contains("privatepass"))
        XCTAssertFalse(result.contains("bearer-secret"));XCTAssertFalse(result.contains("linkpass"))
        XCTAssertTrue(result.contains("[LIBRARY]"));XCTAssertTrue(result.contains("[REDACTED]"))
    }
    func testQuotedValuesKeepQuotesSoJSONStaysParseable() {
        XCTAssertEqual(TaskDiagnostic.redact(#"{"header_key": "abc def", "n": 1}"#,paths:[]),#"{"header_key": "[REDACTED]", "n": 1}"#)
        XCTAssertEqual(TaskDiagnostic.redact("token='x y' ok",paths:[]),"token='[REDACTED]' ok")
        XCTAssertEqual(TaskDiagnostic.redact(#"password="a"b rest"#,paths:[]),#"password="[REDACTED]" rest"#)
        XCTAssertEqual(TaskDiagnostic.redact(#"password="abc"#,paths:[]),#"password="[REDACTED]"#)
        XCTAssertEqual(TaskDiagnostic.redact("secret=plain, x",paths:[]),"secret=[REDACTED], x")
        // 相邻引号片段整段吞掉，引号取开头那个（与 tools/redact.py #64 ad941520 同规则）
        XCTAssertEqual(TaskDiagnostic.redact(#"password="a"'b' x"#,paths:[]),#"password="[REDACTED]" x"#)
        XCTAssertEqual(TaskDiagnostic.redact(#"password='a'"b"c x"#,paths:[]),"password='[REDACTED]' x")
    }
    func testSwitchKeysAreRedactedWithoutHidingNCAIdentifiers() {
        let value=String(repeating:"89abcdef",count:4)
        let rights=String(repeating:"01234567",count:4)
        let names=["master_kek_00","titlekek_05","eticket_rsa_kek","mariko_kek","tsec_root_kek_02","master_seed_00","key_area_key_application_00","header_key"]
        for name in names {
            let result=TaskDiagnostic.redact(name+" = "+value,paths:[])
            XCTAssertFalse(result.contains(value));XCTAssertTrue(result.contains("[REDACTED]"))
        }
        let line=TaskDiagnostic.redact("  "+rights+" = "+value+" # title.keys\r\n",paths:[])
        XCTAssertFalse(line.contains(value));XCTAssertTrue(line.contains(rights))
        XCTAssertEqual(TaskDiagnostic.redact("Missing NCA "+value+".nca",paths:[]),"Missing NCA "+value+".nca")
    }
    func testQuotedCredentialsDoNotExposeTrailingValues() {
        let fixtures=["password=synthetic'credential", "password=synthetic\"credential",
                      "password=\"synthetic credential\"", "password='synthetic credential'",
                      "password=\"synthetic\"credential", "password='synthetic'credential",
                      #"{"token":"synthetic\"credential"}"#]
        for fixture in fixtures {
            let result=TaskDiagnostic.redact(fixture,paths:[])
            XCTAssertFalse(result.contains("synthetic"));XCTAssertFalse(result.contains("credential"))
        }
    }
    func testSpecificFinalDiagnosticReplacesEarlierGenericToolError() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-g01-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        var generic=diagnostic();generic.code="tool_exit"
        var specific=diagnostic();specific.code="content_unreadable";specific.exitCode=3
        let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(specific))
        let final=try JSONSerialization.jsonObject(with:JSONEncoder().encode([specific]))
        store.tasks=[.init(id:"import",operation:"import",state:"running",diagnostics:[generic])]
        store.event(["schema":1,"taskId":"import","type":"diagnostic","diagnostic":object,"diagnostics":final],visible:true)
        store.event(["schema":1,"taskId":"import","type":"result","state":"failed","message":specific.summary,"diagnostics":final],visible:true)
        XCTAssertEqual(store.tasks[0].diagnostics,[specific]);XCTAssertEqual(store.errorDiagnostic,specific)
        XCTAssertTrue(store.failureMessage.contains("content_unreadable"))
    }
    func testEnvironmentDiagnosticAndLegacyChecksBothDecode() throws {
        let value=diagnostic()
        let object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))
        let raw:[String:Any] = ["name":"Metal","ok":false,"message":"missing","action":"downloadMetal","diagnostic":object]
        let check=try JSONDecoder().decode(ToolCheck.self,from:JSONSerialization.data(withJSONObject:raw))
        XCTAssertEqual(check.diagnostic,value);XCTAssertEqual(check.action,"downloadMetal")
        let old=try JSONDecoder().decode(ToolCheck.self,from:Data(#"{"name":"Metal","ok":true,"message":"OK"}"#.utf8))
        XCTAssertNil(old.diagnostic)
    }
    func testGameRequirementsKeepStructuredRecoveryAndLegacyFallback() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-requirements-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        var value=diagnostic();value.code="input_base_missing"
        var game=Game(id:"0100000000000000",name:"fixture",display:"1",packages:[],hidden:false,missing:[value.summary],requirementDiagnostics:[value])
        store.showRequirements(game)
        XCTAssertEqual(store.errorDiagnostic,value);XCTAssertTrue(store.failureMessage.contains("input_base_missing"))
        game.requirementDiagnostics=nil;store.showRequirements(game)
        XCTAssertNil(store.errorDiagnostic);XCTAssertEqual(store.error,value.summary)
    }
    func testIPhoneRetryStartsIPhoneOperationAndClearsPreviousError() {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-retry-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        // Fail before Process.run so this tests dispatch without launching an
        // application, downloading a runtime or touching a user's game library.
        store.preferences.pythonPath="/nonexistent-g01-python"
        store.preferences.iphoneTarget=IPhoneTarget(model:"fixture",productType:"iPhone18,2",gpuArch:"applegpu_g18p",os:26)
        let game=Game(id:"0100000000000000",name:"fixture",display:"1",packages:[],hidden:false)
        store.games=[game];store.errorDiagnostic=diagnostic();store.error="previous"
        store.retry(.init(id:"old",operation:"ipa",state:"failed",gameId:game.id))
        XCTAssertEqual(store.tasks.first?.operation,"ipa")
        XCTAssertEqual(store.tasks.first?.state,"failed")
        XCTAssertEqual(store.errorDiagnostic?.code,"worker_start_failed")
        XCTAssertFalse(store.tasks.contains(where:{$0.operation=="build"}))
    }

    func testCrashSessionDetailRedactsPathAndPasswordOnce() {
        // T77/#741：模拟上次会话 host.log 含【红】CRASH，构造 TaskDiagnostic 后走 redact()。
        let libraryPath = "/Users/player/Library/Application Support/S2Arm"
        let password = "crash-demo-secret"
        let raw = "session start\npassword=\(password) log=\(libraryPath)/logs/host.log\n【红】CRASH signal=SIGSEGV\n"
        XCTAssertTrue(raw.contains("【红】CRASH"))
        let diagnostic = TaskDiagnostic(
            code: "session_crash",
            severity: "error",
            summary: "上次会话异常结束，检测到崩溃标记。",
            suggestion: "导出诊断包并反馈；可重试启动游戏。",
            detail: raw,
            stage: "运行游戏",
            logPath: libraryPath + "/logs/host.log",
            component: "host",
            exitCode: nil
        )
        let redacted = TaskDiagnostic.redact(diagnostic.detail, paths: [(libraryPath, "[LIBRARY]")])
        XCTAssertFalse(redacted.contains(libraryPath), "路径原值不得外泄")
        XCTAssertFalse(redacted.contains(password), "password 原值不得外泄")
        XCTAssertTrue(redacted.contains("【红】CRASH"), "崩溃标记应保留")
        XCTAssertEqual(redacted.components(separatedBy: "[LIBRARY]").count - 1, 1, "路径应脱敏恰好一次")
        XCTAssertEqual(redacted.components(separatedBy: "[REDACTED]").count - 1, 1, "password 应脱敏恰好一次")
    }
}
