import XCTest
@testable import S2ArmLauncher

@MainActor final class WorkerIntegrationTests: XCTestCase {
    func testRealWorkerDrainsFastResultsAndCanReadItsLibrary() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-worker-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root.appendingPathComponent("private"))
        let library=root.appendingPathComponent("library")
        // Exercise the actual Python CLI, pipes, JSON decoder and callback; no
        // substitute engine or synthetic completion event is used here.
        let created=expectation(description:"worker setup callback")
        let id=store.worker("setup",extra:["library":library.path,"libraryId":""]) { result in
            store.preferences.library=result["library"] as? String ?? ""
            store.preferences.libraryId=result["libraryId"] as? String ?? ""
            created.fulfill()
        }
        await fulfillment(of:[created],timeout:15)
        let marker=try JSONSerialization.jsonObject(with:Data(contentsOf:library.appendingPathComponent(".s2arm-library.json"))) as? [String:Any]
        XCTAssertEqual(marker?["id"] as? String,store.preferences.libraryId)
        XCTAssertFalse(store.preferences.libraryId.isEmpty)
        XCTAssertEqual(store.tasks.first(where:{$0.id==id})?.state,"completed")
        // 游戏库结构 P3：setup 起跑时库还没建好，任务记录退回 <私有目录>/logs/jobs；库建好后的作业写 <库>/logs/jobs
        let firstRequest=try JSONSerialization.jsonObject(with:Data(contentsOf:store.privateRoot.appendingPathComponent("logs/jobs/\(id).request.json"))) as? [String:Any]
        XCTAssertEqual(firstRequest?["metalHud"] as? Bool,false)
        store.preferences.metalHud=true
        store.savePreferences()
        XCTAssertEqual(Store(privateRoot:store.privateRoot).preferences.metalHud,true)
        let read=expectation(description:"actual catalogue callback")
        store.refresh {read.fulfill()}
        await fulfillment(of:[read],timeout:15)
        XCTAssertTrue(store.games.isEmpty)
        XCTAssertNil(store.error)
        for _ in 0..<6 {
            let done=expectation(description:"fast catalogue EOF")
            store.worker("catalog",visible:false) {_ in done.fulfill()}
            await fulfillment(of:[done],timeout:10)
        }
        // catalog 是只读探测、不落任务记录（剃刀 H4）：「请求带上 metalHud」改用会落记录的作业核——keys 不给路径，作业当场失败，
        //   请求在建任务时就已落盘；等那份文件出现（失败的作业不走完成回调）
        let keysID=store.worker("keys",visible:false)
        let keysRequest=library.appendingPathComponent("logs/jobs/\(keysID).request.json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath:keysRequest.path) { try await Task.sleep(nanoseconds:100_000_000) }
        let request=try JSONSerialization.jsonObject(with:Data(contentsOf:keysRequest)) as? [String:Any]
        XCTAssertEqual(request?["metalHud"] as? Bool,true)
        store.terminate()
    }
    func testExplicitInvalidPythonDoesNotSilentlyUseAnotherInterpreter() {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-worker-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=Store(privateRoot:root)
        store.preferences.pythonPath="/nonexistent-python"
        XCTAssertThrowsError(try store.pythonExecutable())
        store.checkEnvironment()
        XCTAssertFalse(store.checkingEnvironment)
        XCTAssertFalse(store.environmentReady)
        XCTAssertEqual(store.tasks.first?.state,"failed")
    }
}
