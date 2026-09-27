import Darwin
import Foundation

public struct UsageLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Int, windowDurationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int { 100 - usedPercent }
}

public struct UsageLimitBucket: Codable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let windows: [UsageLimitWindow]

    public init(id: String, name: String?, windows: [UsageLimitWindow]) {
        self.id = id
        self.name = name
        self.windows = windows
    }
}

public struct AccountUsageSnapshot: Codable, Equatable, Sendable {
    public let planType: String?
    public let buckets: [UsageLimitBucket]
    public let fetchedAt: Date

    public init(planType: String?, buckets: [UsageLimitBucket], fetchedAt: Date = Date()) {
        self.planType = planType
        self.buckets = buckets
        self.fetchedAt = fetchedAt
    }

    public var allWindows: [UsageLimitWindow] {
        buckets.flatMap(\.windows)
    }

    public var planDisplayName: String? {
        switch planType?.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro 5x"
        case "free": return "Free"
        case "go": return "Go"
        case "team", "business", "self_serve_business_prolite", "self_serve_business_usage_based":
            return "Business"
        case "enterprise", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "ent26":
            return "Enterprise"
        case "edu", "edu_plus", "edu_pro": return "Edu"
        case .some(let value) where !value.isEmpty && value != "unknown": return value
        default: return nil
        }
    }
}

public enum AccountUsageServiceError: LocalizedError {
    case missingCredential
    case missingCodexExecutable
    case launchFailed
    case requestTimedOut
    case serverError(code: Int?)
    case invalidResponse
    case officialRefreshRequired
    case loginInProgress
    case unsafeStorage
    case credentialRecoveryRequired(URL)

    public var errorDescription: String? {
        switch self {
        case .missingCredential: return "账号登录状态不可用"
        case .missingCodexExecutable: return "当前 ChatGPT 安装中没有找到 Codex 用量查询组件"
        case .launchFailed: return "无法启动本地用量查询组件"
        case .requestTimedOut: return "额度查询超时"
        case .serverError(let code):
            return code.map { "额度接口返回错误（代码 \($0)）" } ?? "额度接口返回错误"
        case .invalidResponse: return "收到的额度数据格式暂不支持"
        case .officialRefreshRequired:
            return "当前账号的访问令牌需要刷新；请先在官方客户端完成刷新或重新登录，再重试额度查询"
        case .loginInProgress: return "请先完成或取消正在进行的账号登录，再刷新额度"
        case .unsafeStorage: return "登录快照或查询目录不安全，已停止查询；凭据必须是当前用户拥有的普通文件并使用 0600 权限"
        case .credentialRecoveryRequired(let folder):
            return "额度查询留下需要核对的登录副本，已暂停新查询以免覆盖。恢复目录：\(folder.path)"

        }
    }
}

public actor AccountUsageService {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    public func fetch(
        profilePaths: ProfilePaths,
        installation: ChatGPTInstallation,
        paths: GPTSwitcherPaths = .live
    ) async throws -> AccountUsageSnapshot {
        let timeout = timeout
        return try await Task.detached(priority: .utility) {
            try Self.fetchBlocking(
                profilePaths: profilePaths,
                installation: installation,
                paths: paths,
                timeout: timeout
            )
        }.value
    }

    static func decodeRateLimitResponse(_ data: Data, fetchedAt: Date = Date()) throws -> AccountUsageSnapshot? {
        let envelope: RPCEnvelope
        do {
            envelope = try JSONDecoder().decode(RPCEnvelope.self, from: data)
        } catch {
            return nil
        }
        guard envelope.id == 2 else { return nil }
        if let error = envelope.error { throw AccountUsageServiceError.serverError(code: error.code) }
        guard let response = envelope.result else { throw AccountUsageServiceError.invalidResponse }

        let snapshots: [(String, RateLimitSnapshotDTO)]
        if let byID = response.rateLimitsByLimitId, !byID.isEmpty {
            snapshots = byID.sorted { lhs, rhs in
                if lhs.key == "codex" { return true }
                if rhs.key == "codex" { return false }
                return lhs.key < rhs.key
            }
        } else {
            snapshots = [(response.rateLimits.limitId ?? "codex", response.rateLimits)]
        }

        let buckets = snapshots.compactMap { fallbackID, snapshot -> UsageLimitBucket? in
            let windows = [snapshot.primary, snapshot.secondary].compactMap { dto -> UsageLimitWindow? in
                guard let dto else { return nil }
                return UsageLimitWindow(
                    usedPercent: dto.usedPercent,
                    windowDurationMinutes: dto.windowDurationMins,
                    resetsAt: dto.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
            guard !windows.isEmpty else { return nil }
            return UsageLimitBucket(
                id: snapshot.limitId ?? fallbackID,
                name: snapshot.limitName,
                windows: windows
            )
        }
        let preferredPlan = response.rateLimitsByLimitId?["codex"]?.planType
            ?? response.rateLimits.planType
            ?? snapshots.compactMap { $0.1.planType }.first
        return AccountUsageSnapshot(planType: preferredPlan, buckets: buckets, fetchedAt: fetchedAt)
    }

    private static func fetchBlocking(
        profilePaths: ProfilePaths,
        installation: ChatGPTInstallation,
        paths: GPTSwitcherPaths,
        timeout: TimeInterval
    ) throws -> AccountUsageSnapshot {
        // Verify again immediately before handing an executable any credential.
        try ChatGPTInspector().verifyTrustedInstallation(installation)
        guard let executable = ChatGPTInspector.bundledCodexExecutable(in: installation.appURL) else {
            throw AccountUsageServiceError.missingCodexExecutable
        }
        return try fetchUsingExecutable(
            profilePaths: profilePaths, paths: paths, executable: executable, timeout: timeout
        )
    }

    // Internal seam for local fixture executables. The public entry point always verifies trust.
    static func fetchUsingExecutable(
        profilePaths: ProfilePaths,
        paths: GPTSwitcherPaths,
        executable: URL,
        timeout: TimeInterval
    ) throws -> AccountUsageSnapshot {
        let lock = try OperationLock.acquire(paths: paths)
        defer { lock.release() }
        guard try LoginSessionStore(paths: paths).load() == nil else {
            throw AccountUsageServiceError.loginInProgress
        }
        guard let id = ProfileID(rawValue: profilePaths.root.lastPathComponent) else {
            throw AccountUsageServiceError.unsafeStorage
        }
        let expected = paths.profile(id)
        guard expected.root == profilePaths.root,
              expected.codex == profilePaths.codex,
              expected.chatGPT == profilePaths.chatGPT else {
            throw AccountUsageServiceError.unsafeStorage
        }
        let isActive = try AccountAuthStore(paths: paths).readActiveProfileID() == id
        _ = try paths.createProfileDirectories(for: id)
        // Active credentials are owned by the official client. Supply only a short-lived access
        // token through external auth; never give this child a refresh token or write active auth.
        let externalCredential: ExternalCredential?
        let original: Data?
        if isActive {
            try paths.validatePrivatePath(paths.sharedAuthURL)
            externalCredential = try ExternalCredential.decode(readCredential(paths.sharedAuthURL))
            original = nil
        } else {
            externalCredential = nil
            original = try readCredential(profilePaths.authSnapshot)
        }
        let fileManager = FileManager.default
        let queriesRoot = paths.applicationSupportRoot.appendingPathComponent("usage-queries", isDirectory: true)
        try paths.createPrivateDirectory(queriesRoot)
        // A previous interrupted query may hold a rotated refresh token. Never silently delete it.
        guard try fileManager.contentsOfDirectory(atPath: queriesRoot.path).isEmpty else {
            throw AccountUsageServiceError.credentialRecoveryRequired(queriesRoot)
        }
        let queryRoot = queriesRoot.appendingPathComponent("query-\(UUID().uuidString)", isDirectory: true)
        try paths.createPrivateDirectory(queryRoot)
        var mayRemoveQuery = true
        do {
            let temporaryHome = queryRoot.appendingPathComponent("home", isDirectory: true)
            let codexHome = queryRoot.appendingPathComponent("codex", isDirectory: true)
            let workspace = queryRoot.appendingPathComponent("workspace", isDirectory: true)
            let temporaryDirectory = queryRoot.appendingPathComponent("tmp", isDirectory: true)
            for directory in [temporaryHome, codexHome, workspace, temporaryDirectory] {
                try paths.createPrivateDirectory(directory)
            }
            let temporaryAuth = codexHome.appendingPathComponent("auth.json")
            if let original { try writeCredential(original, to: temporaryAuth) }
            let credentialStore = externalCredential == nil ? "file" : "ephemeral"
            try writeCredential(
                Data("cli_auth_credentials_store = \"\(credentialStore)\"\n".utf8),
                to: codexHome.appendingPathComponent("config.toml")
            )
            let environment = isolatedEnvironment(home: temporaryHome, codexHome: codexHome, temporaryDirectory: temporaryDirectory)
            let outcome = runQuery(
                executable: executable, workspace: workspace, environment: environment,
                externalCredential: externalCredential, timeout: timeout
            )
            // Never remove credentials while a child could still be writing refreshed state.
            mayRemoveQuery = outcome.terminated
            guard outcome.terminated else {
                throw AccountUsageServiceError.credentialRecoveryRequired(queryRoot)
            }
            if outcome.launched, let original {
                mayRemoveQuery = false
                let refreshed = try readCredential(temporaryAuth)
                if refreshed != original {
                    // The inter-process lock serializes this app; compare bytes as well to detect
                    // changes made by other software. Auth contents remain opaque and unlogged.
                    guard try readCredential(profilePaths.authSnapshot) == original else {
                        throw AccountUsageServiceError.credentialRecoveryRequired(queryRoot)
                    }
                    try writeCredential(refreshed, to: profilePaths.authSnapshot)
                }
                mayRemoveQuery = true
            }
            try fileManager.removeItem(at: queryRoot)
            return try outcome.result.get()
        } catch {
            guard mayRemoveQuery else {
                throw AccountUsageServiceError.credentialRecoveryRequired(queryRoot)
            }
            if fileManager.fileExists(atPath: queryRoot.path) {
                do { try fileManager.removeItem(at: queryRoot) }
                catch { throw AccountUsageServiceError.credentialRecoveryRequired(queryRoot) }
            }
            throw error
        }
    }

    static func isolatedEnvironment(home: URL, codexHome: URL, temporaryDirectory: URL) -> [String: String] {
        // Do not inherit proxy, endpoint, injected-library, plugin, or parent CODEX_* settings.
        [
            "PATH": "/usr/bin:/bin",
            "HOME": home.path,
            "CODEX_HOME": codexHome.path,
            "TMPDIR": temporaryDirectory.path,
            "LANG": "en_US.UTF-8",
        ]
    }

    private struct QueryOutcome {
        let result: Result<AccountUsageSnapshot, Error>
        let launched: Bool
        let terminated: Bool
    }

    private static func runQuery(
        executable: URL,
        workspace: URL,
        environment: [String: String],
        externalCredential: ExternalCredential?,
        timeout: TimeInterval
    ) -> QueryOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio", "--disable", "plugins"]
        process.currentDirectoryURL = workspace
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let state = QueryResponseState()
        output.fileHandleForReading.readabilityHandler = { handle in
            state.receive(handle.availableData)
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        // A child that exits before reading must cause a write error, not kill the GUI via SIGPIPE.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            return QueryOutcome(result: .failure(AccountUsageServiceError.launchFailed), launched: false, terminated: true)
        }
        do { try process.run() }
        catch {
            return QueryOutcome(result: .failure(AccountUsageServiceError.launchFailed), launched: false, terminated: true)
        }
        // Close the parent's copies of the child's endpoints so EOF is observable.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        let result: Result<AccountUsageSnapshot, Error>
        do {
            try writeRPC([
                "id": 1, "method": "initialize",
                "params": ["clientInfo": ["name": "gpt-switcher", "title": "GPT Switcher", "version": "1.2.2"],
                           "capabilities": ["experimentalApi": true]],
            ], to: input.fileHandleForWriting, deadline: deadline)
            try validateRPCSuccess(state.wait(for: 1, deadline: deadline))
            try writeRPC(["method": "initialized"], to: input.fileHandleForWriting, deadline: deadline)
            if let externalCredential {
                try writeRPC([
                    "id": 7, "method": "account/login/start",
                    "params": ["type": "chatgptAuthTokens", "accessToken": externalCredential.accessToken,
                               "chatgptAccountId": externalCredential.accountID],
                ], to: input.fileHandleForWriting, deadline: deadline)
                try validateRPCSuccess(state.wait(for: 7, deadline: deadline))
            }
            try writeRPC(["id": 2, "method": "account/rateLimits/read"], to: input.fileHandleForWriting, deadline: deadline)
            let response = try state.wait(for: 2, deadline: deadline)
            guard let snapshot = try decodeRateLimitResponse(response) else {
                throw AccountUsageServiceError.invalidResponse
            }
            result = .success(snapshot)
        } catch {
            // External auth may request a fresh access token. Do not refresh it ourselves or pass
            // a refresh token; ask the official active client to refresh before the next query.
            for requestID in state.takeRefreshRequestIDs() {
                try? writeRPC([
                    "id": requestID,
                    "error": ["code": -32000, "message": "Refresh in the official client and retry."],
                ], to: input.fileHandleForWriting, deadline: ProcessInfo.processInfo.systemUptime + 0.1)
            }
            result = .failure(error)
        }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        let terminated = stopAndWait(process)
        return QueryOutcome(result: result, launched: true, terminated: terminated)
    }

    private struct ExternalCredential {
        let accessToken: String
        let accountID: String

        static func decode(_ data: Data) throws -> ExternalCredential {
            struct Auth: Decodable {
                struct Tokens: Decodable {
                    let access_token: String
                    let account_id: String
                }
                let tokens: Tokens
            }
            guard let auth = try? JSONDecoder().decode(Auth.self, from: data),
                  !auth.tokens.access_token.isEmpty, auth.tokens.access_token.utf8.count <= 32_768,
                  !auth.tokens.account_id.isEmpty, auth.tokens.account_id.utf8.count <= 1_024 else {
                throw AccountUsageServiceError.officialRefreshRequired
            }
            return ExternalCredential(accessToken: auth.tokens.access_token, accountID: auth.tokens.account_id)
        }
    }

    private static func validateRPCSuccess(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountUsageServiceError.invalidResponse
        }
        if let error = object["error"] as? [String: Any] {
            throw AccountUsageServiceError.serverError(code: error["code"] as? Int)
        }
        guard object["result"] != nil else { throw AccountUsageServiceError.invalidResponse }
    }

    private static func writeRPC(_ object: [String: Any], to handle: FileHandle, deadline: TimeInterval) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw AccountUsageServiceError.invalidResponse
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw AccountUsageServiceError.requestTimedOut
                }
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                throw AccountUsageServiceError.invalidResponse
            }
        }
    }

    private static func stopAndWait(_ process: Process) -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if waitForExit(process, seconds: 0.5) { return true }
        // Process.waitUntilExit() has no timeout; a stuck child must not hang the app forever.
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        return waitForExit(process, seconds: 1)
    }

    private static func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }

    private static func readCredential(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AccountUsageServiceError.missingCredential }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600,
              info.st_size > 0, info.st_size <= 5_000_000 else {
            throw AccountUsageServiceError.unsafeStorage
        }
        guard let data = try handle.readToEnd(), !data.isEmpty, data.count <= 5_000_000 else {
            throw AccountUsageServiceError.missingCredential
        }
        return data
    }

    private static func writeCredential(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".gpt-switcher-usage-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AccountUsageServiceError.unsafeStorage }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw AccountUsageServiceError.unsafeStorage }
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw AccountUsageServiceError.unsafeStorage }
        try handle.close()
        guard rename(temporary.path, destination.path) == 0 else {
            throw AccountUsageServiceError.unsafeStorage
        }
    }

}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let result: GetAccountRateLimitsResponseDTO?
    let error: RPCErrorDTO?
}

private struct RPCErrorDTO: Decodable {
    let code: Int?
}

private struct GetAccountRateLimitsResponseDTO: Decodable {
    let rateLimits: RateLimitSnapshotDTO
    let rateLimitsByLimitId: [String: RateLimitSnapshotDTO]?
}

private struct RateLimitSnapshotDTO: Decodable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindowDTO?
    let secondary: RateLimitWindowDTO?
}

private struct RateLimitWindowDTO: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

private final class QueryResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private let available = DispatchSemaphore(value: 0)
    private var buffered = Data()
    private var totalBytes = 0
    private var responses: [Int: Data] = [:]
    private var refreshRequestIDs: [Any] = []
    private var failure: Error?

    func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        totalBytes += data.count
        guard !data.isEmpty, totalBytes <= 1_048_576 else {
            failure = AccountUsageServiceError.invalidResponse
            available.signal()
            return
        }
        buffered.append(data)
        while let newline = buffered.firstIndex(of: 0x0A) {
            let line = Data(buffered[..<newline])
            buffered.removeSubrange(...newline)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if object["method"] as? String == "account/chatgptAuthTokens/refresh",
               let id = object["id"], id is String || id is NSNumber {
                refreshRequestIDs.append(id)
                failure = AccountUsageServiceError.officialRefreshRequired
                available.signal()
                return
            }
            if let id = object["id"] as? Int, [1, 2, 7].contains(id), object["method"] == nil {
                responses[id] = line
                available.signal()
            }
        }
    }

    func wait(for id: Int, deadline: TimeInterval) throws -> Data {
        while true {
            lock.lock()
            // Consume an already received response even if EOF followed it immediately.
            let response = responses.removeValue(forKey: id)
            let failure = self.failure
            lock.unlock()
            if let response { return response }
            if let failure { throw failure }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, available.wait(timeout: .now() + remaining) == .success else {
                throw AccountUsageServiceError.requestTimedOut
            }
        }
    }

    func takeRefreshRequestIDs() -> [Any] {
        lock.lock()
        defer { lock.unlock() }
        let ids = refreshRequestIDs
        refreshRequestIDs.removeAll()
        return ids
    }
}
