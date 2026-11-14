import Foundation

enum CLIError: LocalizedError {
    case missing, cancelled, timedOut
    case authorizationRequired(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missing: return "未找到飞书官方 CLI。请先安装并配置 lark-cli。"
        case .cancelled: return "已取消授权。已完成的同步记录已保留。"
        case .timedOut: return "连接或授权已超时，请检查网络后重新授权。"
        case .authorizationRequired(let message), .failed(let message): return message
        }
    }

    var needsAuthorization: Bool {
        if case .authorizationRequired = self { return true }
        return false
    }
}

final class CLICancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

struct FeishuIdentity {
    let openID: String?
    let name: String?
    let isReady: Bool

    init(_ object: [String: Any]) {
        let identities = object["identities"] as? [String: Any]
        let user = identities?["user"] as? [String: Any] ?? [:]
        openID = user["openId"] as? String
        name = user["userName"] as? String
        // Bot readiness must never stand in for the user's calendar authorization.
        isReady = user["status"] as? String == "ready" && user["available"] as? Bool == true
            && user["verified"] as? Bool != false
    }
}

struct FeishuAuthorization {
    let deviceCode: String
    let url: URL
    let expiresIn: TimeInterval

    init(_ object: [String: Any]) throws {
        guard let code = object["device_code"] as? String, !code.isEmpty,
              let link = object["verification_url"] as? String
                ?? object["verification_uri_complete"] as? String,
              let url = URL(string: link), url.scheme == "https", url.host != nil else {
            throw CLIError.failed("飞书没有返回有效的授权链接，请检查 CLI 配置或更新 lark-cli 后重试。")
        }
        deviceCode = code
        self.url = url
        expiresIn = min(max(object["expires_in"] as? Double ?? 600, 1), 1800)
    }
}

final class FeishuCLI {
    private let executableOverride: String?
    private let processLock = NSLock()
    private var runningProcesses: [UUID: Process] = [:]
    init(executable: String? = nil) { executableOverride = executable }

    func cancelRunningCommands() {
        processLock.lock()
        defer { processLock.unlock() }
        for process in runningProcesses.values where process.isRunning { process.terminate() }
    }

    func identity(verify: Bool = false, cancellation: CLICancellation? = nil) throws -> FeishuIdentity {
        let object = try call(["auth", "status", "--json"] + (verify ? ["--verify"] : []), cancellation: cancellation)
        return FeishuIdentity(object)
    }

    func beginAuthorization(cancellation: CLICancellation) throws -> FeishuAuthorization {
        try FeishuAuthorization(call(["auth", "login", "--domain", "calendar", "--no-wait", "--json"], cancellation: cancellation))
    }

    func finishAuthorization(_ authorization: FeishuAuthorization, cancellation: CLICancellation) throws -> FeishuIdentity {
        _ = try call(["auth", "login", "--device-code", authorization.deviceCode, "--json"],
                     timeout: authorization.expiresIn, cancellation: cancellation)
        let identity = try self.identity(verify: true, cancellation: cancellation)
        guard identity.isReady else { throw CLIError.failed("授权尚未生效，请检查网络及飞书应用的日历权限后重试。") }
        return identity
    }

    private func executable() throws -> String {
        if let executableOverride { return executableOverride }
        let candidates = ["/opt/homebrew/bin/lark-cli", "/usr/local/bin/lark-cli"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw CLIError.missing }
        // npm's wrapper spawns a child process. Prefer its bundled native binary so
        // cancellation and deadlines also stop device-flow polling itself.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if resolved.lastPathComponent == "run.js" {
            let native = resolved.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bin/lark-cli").path
            if FileManager.default.isExecutableFile(atPath: native) { return native }
        }
        return path
    }

    func call(_ arguments: [String], timeout: TimeInterval = 60, cancellation: CLICancellation? = nil) throws -> [String: Any] {
        if cancellation?.isCancelled == true { throw CLIError.cancelled }
        let process = Process()
        let executable = try executable()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        environment["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        environment["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        // Read both streams while the child runs: waiting before draining can
        // deadlock once either pipe fills (including during long authorizations).
        let group = DispatchGroup()
        var stdout = Data(), stderr = Data()
        let processID = UUID()
        try process.run()
        processLock.lock()
        runningProcesses[processID] = process
        processLock.unlock()
        defer {
            processLock.lock()
            runningProcesses.removeValue(forKey: processID)
            processLock.unlock()
        }
        group.enter()
        DispatchQueue.global().async { stdout = output.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { stderr = error.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        var didTimeOut = false
        while process.isRunning {
            if cancellation?.isCancelled == true || Date() >= deadline {
                didTimeOut = Date() >= deadline
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        group.wait()
        if cancellation?.isCancelled == true { throw CLIError.cancelled }
        if didTimeOut { throw CLIError.timedOut }
        return try Self.decode(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    static func decode(stdout: Data, stderr: Data, exitCode: Int32) throws -> [String: Any] {
        let data = stdout.isEmpty ? stderr : stdout
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Do not echo raw auth output: it can contain temporary credentials.
            throw CLIError.failed("飞书 CLI 未返回有效结果（退出代码 \(exitCode)）。请检查网络、CLI 版本及应用配置。")
        }
        if exitCode != 0 || object["ok"] as? Bool == false {
            let error = object["error"] as? [String: Any] ?? [:]
            let message = error["message"] as? String ?? object["error"] as? String ?? "飞书操作失败（代码 \(exitCode)）"
            let type = error["type"] as? String
            let code = error["code"] as? Int
            let lower = message.lowercased()
            if type == "authentication" || code == 99991677 || code == 99991679
                || lower.contains("need_user_authorization") {
                throw CLIError.authorizationRequired(message)
            }
            throw CLIError.failed(message)
        }
        // Auth management commands return plain objects, API calls use {ok,data}.
        return object
    }
}

/// A confirmed batch keeps its cursor at the failed item while authorization runs.
/// Successfully saved items are never replayed when the same batch resumes.
final class SyncBatch<Item> {
    let items: [Item]
    private(set) var nextIndex = 0
    private(set) var succeeded = 0
    private(set) var failures: [String] = []
    var attemptedAuthorization = false
    var expectedOpenID: String?

    init(items: [Item]) { self.items = items }

    func acceptIdentity(_ identity: FeishuIdentity) throws {
        guard identity.isReady, let openID = identity.openID, !openID.isEmpty,
              expectedOpenID == nil || expectedOpenID == openID else {
            throw CLIError.failed("本次同步已停止。请重新授权原来的飞书账号，再预览并确认同步。")
        }
        expectedOpenID = openID
    }

    func run(perform: (Item) throws -> Void, title: (Item) -> String, progress: (Int) -> Void) -> Bool {
        while nextIndex < items.count {
            let item = items[nextIndex]
            do {
                try perform(item)
                succeeded += 1
            } catch let error as CLIError where error.needsAuthorization {
                return false
            } catch {
                failures.append("\(title(item))：\(error.localizedDescription)")
            }
            nextIndex += 1
            progress(nextIndex)
        }
        return true
    }
}
