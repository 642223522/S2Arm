import Foundation
import XCTest
@testable import S2ArmAppleAdapter

/// 假的作业进程：记下怎么起的、起的那一刻读走请求文件（退出时适配层会删它），按脚本吐行、退出。
final class FakeRunner: JobProcessRunner {
    struct Start {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let request: [String: Any]
        let requestMode: Int
        let requestDirMode: Int
        let requestPath: String
    }

    final class Handle: JobProcessHandle {
        var terminated = 0
        var onTerminate: (() -> Void)?
        func terminate() { terminated += 1; onTerminate?() }
    }

    /// 每次 start 吐的行（按 operation 取，缺省用 script）与退出码；hold = 不自己退出，等 terminate。
    var script: (_ request: [String: Any]) -> (lines: [String], exit: Int32, hold: Bool) = { _ in ([], 0, false) }
    private(set) var starts: [Start] = []
    private(set) var handles: [Handle] = []
    private let queue = DispatchQueue(label: "fake.runner")

    func start(executable: URL, arguments: [String], environment: [String: String],
               onLine: @escaping (Data) -> Void, onStderr: @escaping (Data) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> JobProcessHandle {
        let path = arguments.last ?? ""
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let mode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        let dirMode = (try FileManager.default.attributesOfItem(atPath: (path as NSString).deletingLastPathComponent)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        starts.append(Start(executable: executable, arguments: arguments, environment: environment, request: request,
                            requestMode: mode, requestDirMode: dirMode, requestPath: path))
        let (lines, exit, hold) = script(request)
        let handle = Handle()
        handles.append(handle)
        let queue = self.queue
        let task = request["taskId"] as? String ?? ""
        queue.async {
            onStderr(Data("bootstrap noise\n".utf8))
            for line in lines { onLine(Data(line.replacingOccurrences(of: "$TASK", with: task).utf8)) }
            if !hold { onExit(exit) }
        }
        if hold {
            // 同作业层：收到 SIGTERM 记取消，打一条 cancelled 结果后以 130 退出
            handle.onTerminate = {
                queue.async {
                    onLine(Data(#"{"schema":1,"jobId":"\#(task)","type":"result","state":"cancelled","message":"任务已取消；上次成功的运行版本和存档已保留。","result":{}}"#.utf8))
                    onExit(130)
                }
            }
        }
        return handle
    }
}

/// 临时目录：数据目录 + 资源目录（带可执行的内置 Python 与 Jobs/main.py）。
struct Sandbox {
    let root: URL
    let privateRoot: URL
    let resources: URL

    init(bundledPython: Bool = true, jobs: Bool = true, engine: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("s2arm-adapter-" + UUID().uuidString)
        privateRoot = root.appendingPathComponent("data")
        resources = root.appendingPathComponent("Resources")
        let fm = FileManager.default
        try fm.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        if bundledPython {
            let python = resources.appendingPathComponent("Runtime/python/bin/python3")
            try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: python)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        }
        if jobs {
            let main = resources.appendingPathComponent("Jobs/main.py")
            try fm.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: main)
        }
        if engine {
            let manifest = resources.appendingPathComponent("Engine/engine.json")
            try fm.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: manifest)
        }
    }

    func environment(library: String? = nil) -> JobEnvironment {
        JobEnvironment(privateRoot: privateRoot, resources: resources, library: library ?? root.appendingPathComponent("lib").path, libraryId: "lib-1", developerDir: "/Applications/Xcode.app")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// 适配层回调统一落在这条串行队列上，测试在它上面等。
let testQueue = DispatchQueue(label: "s2arm.adapter.tests")

extension XCTestCase {
    func client(_ sandbox: Sandbox, _ runner: FakeRunner, env: JobEnvironment? = nil,
                processEnvironment: [String: String] = ["PATH": "/usr/bin", "PYTHONPATH": "/evil", "PYTHONHOME": "/evil"]) -> JobClient {
        JobClient(environment: env ?? sandbox.environment(), runner: runner, callbackQueue: testQueue,
                  parentPid: 4242, processEnvironment: processEnvironment)
    }
}

func eventLine(_ type: String, state: String = "running", message: String = "", extra: String = "") -> String {
    #"{"schema":1,"jobId":"$TASK","taskId":"$TASK","type":"\#(type)","state":"\#(state)","message":"\#(message)"\#(extra)}"#
}
