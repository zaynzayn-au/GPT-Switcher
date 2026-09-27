import AppKit
import Darwin
import Foundation

public enum SwitchResult: Equatable, Sendable {
    case alreadyActive
    case launched
    case stopped
}

public enum ChatGPTControllerError: LocalizedError {
    case incompatibleInstallation
    case quitTimedOut
    case launchFailed(String)
    case launchTimedOut
    case loginInProgress
    case noMatchingLogin
    case accountSlotOccupied

    public var errorDescription: String? {
        switch self {
        case .incompatibleInstallation:
            return "当前 ChatGPT 版本可能不支持账号登录配置。为保护数据，已停止切换。"
        case .quitTimedOut:
            return "ChatGPT 仍在运行。你可以选择强制退出后再切换。"
        case .launchFailed(let message):
            return "ChatGPT 启动失败：\(message)"
        case .loginInProgress:
            return "有尚未完成的账号登录，请先完成或取消登录，再切换账号。"
        case .noMatchingLogin:
            return "没有匹配的登录流程，请重新开始登录。"
        case .accountSlotOccupied:
            return "目标账号槽位已有登录或待恢复的凭据；为避免覆盖，已停止登录。请使用新槽位，或在设置中明确选择重新登录。"
        case .launchTimedOut:
            return "已发出启动请求，但未能在限定时间内确认 ChatGPT 正在运行。"
        }
    }
}

@MainActor
public final class ChatGPTController {
    public let paths: GPTSwitcherPaths
    public let logger: SafeLogger
    public let authStore: AccountAuthStore
    private let inspector: ChatGPTInspector

    public init(
        paths: GPTSwitcherPaths = .live,
        logger: SafeLogger? = nil,
        inspector: ChatGPTInspector = ChatGPTInspector(),
        authStore: AccountAuthStore? = nil
    ) {
        self.paths = paths
        self.logger = logger ?? SafeLogger(paths: paths)
        self.inspector = inspector
        self.authStore = authStore ?? AccountAuthStore(paths: paths)
    }

    public var isRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: ChatGPTInspector.expectedBundleIdentifier
        ).filter { !$0.isTerminated }.isEmpty
    }

    public func installation(preferredPath: String? = nil) throws -> ChatGPTInstallation {
        try inspector.inspect(preferredPath: preferredPath)
    }

    /// Switches only the active account credential. The official default ChatGPT
    /// and CODEX_HOME directories remain shared, so local projects and threads do not move.
    public func switchProfile(
        to profile: AccountProfile,
        currentProfileID: ProfileID?,
        preferredPath: String? = nil,
        launchAfterSwitch: Bool = true,
        force: Bool = false
    ) async throws -> SwitchResult {
        let operation = try OperationLock.acquire(paths: paths)
        defer { operation.release() }
        try requireNoPendingLogin()
        let installation = try supportedInstallation(preferredPath: preferredPath)
        guard authStore.hasCredential(for: profile.id) else {
            throw AccountAuthStoreError.missingCredential(profile.id)
        }

        if try authStore.readActiveProfileID() == profile.id && isRunning {
            try synchronizeConfiguration()
            return .alreadyActive
        }

        if isRunning {
            logger.log("Switch to \(profile.id.rawValue)")
            requestQuit(force: force)
            guard await waitUntilRunning(false, timeout: force ? 8 : 12) else {
                throw ChatGPTControllerError.quitTimedOut
            }
        }
        try authStore.preserveCurrentCredentialIfManaged()
        let checkpoint = try authStore.captureCurrentState()
        do {
            try authStore.activate(profile.id)
            try synchronizeConfiguration()
            guard launchAfterSwitch else { return .stopped }
            try inspector.verifyTrustedInstallation(installation)
            try launch(arguments: sharedLaunchArguments(installation: installation))
            guard await waitUntilRunning(true, timeout: 15) else {
                throw ChatGPTControllerError.launchTimedOut
            }
            logger.log("Activated \(profile.id.rawValue); shared workspace")
            return .launched
        } catch {
            // Never change credentials under a possibly running official process.
            // The auth marker remains authoritative if launch partially succeeded.
            if !isRunning {
                try authStore.restoreCurrentState(checkpoint)
                try synchronizeConfiguration()
            }
            throw error
        }
    }

    /// Starts a one-time isolated official login window. Once login finishes,
    /// completeLoginSetup moves only that opaque auth file into the shared workspace.
    public func beginLoginSetup(
        for profile: AccountProfile,
        preferredPath: String? = nil,
        force: Bool = false
    ) async throws {
        let operation = try OperationLock.acquire(paths: paths)
        defer { operation.release() }
        try requireNoPendingLogin()
        let installation = try supportedInstallation(preferredPath: preferredPath)
        if isRunning {
            requestQuit(force: force)
            guard await waitUntilRunning(false, timeout: force ? 8 : 12) else {
                throw ChatGPTControllerError.quitTimedOut
            }
        }
        try authStore.preserveCurrentCredentialIfManaged()
        try authStore.backupOriginalSharedCredentialIfNeeded()
        let pending = LoginSession(profileID: profile.id, previousProfileID: authStore.activeProfileID())
        let profilePaths = try pending.enrollmentPaths(in: paths)
        // Persist before launch: a Switcher restart must not confuse enrollment
        // with the active shared workspace.
        let sessions = LoginSessionStore(paths: paths)
        try sessions.save(pending)
        try inspector.verifyTrustedInstallation(installation)
        try launch(arguments: isolatedLoginArguments(installation: installation, profile: profilePaths))
        guard await waitUntilRunning(true, timeout: 15) else {
            throw ChatGPTControllerError.launchTimedOut
        }
        logger.log("Started official login setup for \(profile.id.rawValue)")
    }

    public func completeLoginSetup(
        for profile: AccountProfile,
        preferredPath: String? = nil,
        force: Bool = false
    ) async throws -> SwitchResult {
        let operation = try OperationLock.acquire(paths: paths)
        defer { operation.release() }
        let sessions = LoginSessionStore(paths: paths)
        guard let pending = try sessions.load(), pending.profileID == profile.id else {
            throw ChatGPTControllerError.noMatchingLogin
        }
        let installation = try supportedInstallation(preferredPath: preferredPath)
        let enrollment = try pending.enrollmentPaths(in: paths)
        guard authStore.isSafeCredentialFile(enrollment.authSnapshot) else {
            throw AccountAuthStoreError.missingCredential(profile.id)
        }
        if isRunning {
            requestQuit(force: force)
            guard await waitUntilRunning(false, timeout: force ? 8 : 12) else {
                throw ChatGPTControllerError.quitTimedOut
            }
        }
        let checkpoint = try authStore.captureCurrentState()
        do {
            try authStore.saveCredential(from: enrollment.authSnapshot, for: profile.id)
            try authStore.activate(profile.id)
            try synchronizeConfiguration(configuredProfile: profile.id)
            // Clear enrollment before starting shared mode. A cleanup failure
            // must never leave shared auth subject to an enrollment retry.
            try sessions.clear()
            try inspector.verifyTrustedInstallation(installation)
            try launch(arguments: sharedLaunchArguments(installation: installation))
            guard await waitUntilRunning(true, timeout: 15) else {
                throw ChatGPTControllerError.launchTimedOut
            }
            try? FileManager.default.removeItem(at: enrollment.root)
            logger.log("Completed login setup for \(profile.id.rawValue); shared workspace")
            return .launched
        } catch {
            if !isRunning {
                try authStore.restoreCurrentState(checkpoint)
                try synchronizeConfiguration()
                try sessions.save(pending)
            }
            throw error
        }
    }

    public func cancelLoginSetup(preferredPath: String? = nil, force: Bool = false) async throws {
        let operation = try OperationLock.acquire(paths: paths)
        defer { operation.release() }
        let sessions = LoginSessionStore(paths: paths)
        guard let pending = try sessions.load() else { throw ChatGPTControllerError.noMatchingLogin }
        let installation = try supportedInstallation(preferredPath: preferredPath)
        if isRunning {
            requestQuit(force: force)
            guard await waitUntilRunning(false, timeout: force ? 8 : 12) else {
                throw ChatGPTControllerError.quitTimedOut
            }
        }
        // The old slot and shared auth are untouched until explicit completion.
        let enrollment = try pending.enrollmentPaths(in: paths)
        try sessions.clear()
        try? FileManager.default.removeItem(at: enrollment.root)
        try synchronizeConfiguration()
        try inspector.verifyTrustedInstallation(installation)
        try launch(arguments: sharedLaunchArguments(installation: installation))
        guard await waitUntilRunning(true, timeout: 15) else {
            throw ChatGPTControllerError.launchTimedOut
        }
        logger.log("Cancelled login setup; restored shared workspace")
    }

    /// Enroll an inactive account via the official browser flow without closing
    /// the currently running desktop app. No credentials are printed or returned.
    public func enrollUsingBrowser(for id: ProfileID, preferredPath: String? = nil) async throws {
        let operation = try OperationLock.acquire(paths: paths)
        defer { operation.release() }
        try requireNoPendingLogin()
        guard try authStore.readActiveProfileID() != id else {
            throw ChatGPTControllerError.launchFailed("不能在当前活动账号槽位重新登录；请先切换到其他账号。")
        }
        let savedConfig = try ConfigStore(paths: paths).load()
        let targetAuth = paths.profile(id).authSnapshot
        try paths.validatePrivatePath(targetAuth)
        // An unregistered auth file may be the recoverable result of an earlier
        // config-write failure. Even an invalid/empty file occupies the slot.
        guard !savedConfig.account(id).isConfigured,
              try !PrivateFileIO.exists(targetAuth) else {
            throw ChatGPTControllerError.accountSlotOccupied
        }
        let installation = try supportedInstallation(preferredPath: preferredPath)
        guard let executable = ChatGPTInspector.bundledCodexExecutable(in: installation.appURL) else {
            throw ChatGPTControllerError.incompatibleInstallation
        }
        let staging = paths.applicationSupportRoot.appendingPathComponent("browser-login-" + UUID().uuidString, isDirectory: true)
        try paths.createPrivateDirectory(staging)
        let process = Process()
        defer {
            stopEnrollmentProcess(process)
            if !process.isRunning { try? FileManager.default.removeItem(at: staging) }
        }
        let configURL = staging.appendingPathComponent("config.toml")
        try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        process.executableURL = executable
        process.arguments = ["login"]
        let parent = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"] { environment[key] = parent[key] }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CODEX_HOME"] = staging.path
        process.environment = environment
        process.currentDirectoryURL = staging
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try inspector.verifyTrustedInstallation(installation)
        try process.run()
        print("请在自动打开的 OpenAI 官方网页中登录目标账号并完成 MFA。密码与验证码不用发到聊天中。")
        fflush(stdout)
        let deadline = Date().addingTimeInterval(600)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        if process.isRunning {
            process.terminate()
            throw ChatGPTControllerError.launchFailed("登录超时，请重试。")
        }
        guard process.terminationStatus == 0 else {
            throw ChatGPTControllerError.launchFailed("官方登录未完成或被取消；当前 Codex 登录保持不变。")
        }
        try authStore.saveCredential(from: staging.appendingPathComponent("auth.json"), for: id)
        try synchronizeConfiguration(configuredProfile: id)
    }

    private func stopEnrollmentProcess(_ process: Process) {
            if process.isRunning {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                let limit = ProcessInfo.processInfo.systemUptime + 1
                while process.isRunning && ProcessInfo.processInfo.systemUptime < limit { Thread.sleep(forTimeInterval: 0.01) }
            }
    }

    private func requireNoPendingLogin() throws {
        if try LoginSessionStore(paths: paths).load() != nil {
            throw ChatGPTControllerError.loginInProgress
        }
    }

    // Caller holds OperationLock. Internal visibility also permits fake-data
    // verification without launching a browser or an official application.
    func synchronizeConfiguration(configuredProfile: ProfileID? = nil) throws {
        let store = ConfigStore(paths: paths)
        var config = try store.load()
        if let id = configuredProfile {
            var account = config.account(id)
            account.isConfigured = true
            config.updateAccount(account)
            if config.shortcuts[id] == nil {
                let used = Set(config.shortcuts.values.map { $0.key.uppercased() })
                if let key = (1...9).map(String.init).first(where: { !used.contains($0) }) {
                    config.shortcuts[id] = HotKeyConfiguration(key: key)
                }
            }
        }
        config.activeProfileID = try authStore.readActiveProfileID()
        try store.save(config)
    }

    public func openActiveProfile(
        _ profile: AccountProfile,
        preferredPath: String? = nil
    ) async throws -> SwitchResult {
        try await switchProfile(
            to: profile,
            currentProfileID: profile.id,
            preferredPath: preferredPath
        )
    }

    public func forceQuit() async -> Bool {
        requestQuit(force: true)
        return await waitUntilRunning(false, timeout: 8)
    }

    public func sharedLaunchArguments(installation: ChatGPTInstallation) -> [String] {
        [
            "-n",
            "--env", "CODEX_HOME=\(paths.sharedCodexHome.path)",
            "--env", "\(ChatGPTInspector.explicitUserDataEnvironment)=\(paths.sharedChatGPTData.path)",
            installation.appURL.path,
            "--args",
            "--user-data-dir=\(paths.sharedChatGPTData.path)",
        ]
    }

    public func isolatedLoginArguments(
        installation: ChatGPTInstallation,
        profile: ProfilePaths
    ) -> [String] {
        [
            "-n",
            "--env", "CODEX_HOME=\(profile.codex.path)",
            "--env", "\(ChatGPTInspector.explicitUserDataEnvironment)=\(profile.chatGPT.path)",
            installation.appURL.path,
            "--args",
            "--user-data-dir=\(profile.chatGPT.path)",
        ]
    }

    private func supportedInstallation(preferredPath: String?) throws -> ChatGPTInstallation {
        let installation = try inspector.inspect(preferredPath: preferredPath)
        try inspector.verifyTrustedInstallation(installation)
        guard installation.isSupported else {
            logger.log("Compatibility check failed for ChatGPT \(installation.version) (\(installation.build))")
            throw ChatGPTControllerError.incompatibleInstallation
        }
        return installation
    }

    private func launch(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ChatGPTControllerError.launchFailed(message?.isEmpty == false ? message! : "open 返回错误")
        }
    }

    private func requestQuit(force: Bool) {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: ChatGPTInspector.expectedBundleIdentifier
        )
        for application in applications where !application.isTerminated {
            if force { application.forceTerminate() } else { application.terminate() }
        }
    }

    private func waitUntilRunning(_ expected: Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isRunning == expected { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return isRunning == expected
    }
}
