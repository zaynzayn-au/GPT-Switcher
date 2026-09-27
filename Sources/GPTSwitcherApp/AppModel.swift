import AppKit
import Combine
import GPTSwitcherCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var config: SwitcherConfig
    @Published private(set) var installation: ChatGPTInstallation?
    @Published var statusMessage: String?
    @Published var isSwitching = false
    @Published var pendingForceProfileID: ProfileID?
    @Published var pendingLoginProfileID: ProfileID?
    @Published private(set) var usageByProfile: [ProfileID: AccountUsageSnapshot] = [:]
    @Published private(set) var usageErrors: [ProfileID: String] = [:]
    @Published private(set) var isRefreshingUsage = false
    @Published private(set) var lastUsageRefresh: Date?

    let paths: GPTSwitcherPaths
    private let store: ConfigStore
    private let controller: ChatGPTController
    private let profiles: ProfileManager
    private let logger: SafeLogger
    private let usageService: AccountUsageService
    private var backgroundTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(paths: GPTSwitcherPaths = .live) {
        self.paths = paths
        self.store = ConfigStore(paths: paths)
        self.logger = SafeLogger(paths: paths)
        self.controller = ChatGPTController(paths: paths, logger: logger)
        self.profiles = ProfileManager(paths: paths)
        self.usageService = AccountUsageService()
        do {
            self.config = try store.load()
        } catch {
            self.config = SwitcherConfig()
            self.statusMessage = error.localizedDescription
        }
        synchronizeState()
        refreshInstallation()
        backgroundTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isSwitching, !self.isRefreshingUsage else { return }
                self.synchronizeState()
                if self.config.effectiveUsageRefreshMinutes > 0 { self.refreshUsageIfNeeded() }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.config.effectiveUsageRefreshMinutes > 0 else { return }
                self.refreshUsageIfNeeded(force: true)
            }
        }
    }

    var configuredAccounts: [AccountProfile] {
        config.accounts.filter { $0.isConfigured && hasCredential($0.id) }
    }

    var isChatGPTRunning: Bool { controller.isRunning }

    var activeAccount: AccountProfile? {
        guard let id = config.activeProfileID,
              config.accounts.contains(where: { $0.id == id }) else { return nil }
        return config.account(id)
    }

    func account(_ id: ProfileID) -> AccountProfile { config.account(id) }

    func hasCredential(_ id: ProfileID) -> Bool {
        controller.authStore.hasCredential(for: id)
    }

    func usageError(_ id: ProfileID) -> String? { usageErrors[id] }

    func refreshUsageIfNeeded(force: Bool = false) {
        guard !isRefreshingUsage, !isSwitching, pendingLoginProfileID == nil,
              let installation, installation.isSupported else { return }
        if !force, config.effectiveUsageRefreshMinutes == 0 { return }
        if !force, let lastUsageRefresh, Date().timeIntervalSince(lastUsageRefresh) < Double(max(1, config.effectiveUsageRefreshMinutes) * 60) {
            return
        }
        let accounts = configuredAccounts
        guard !accounts.isEmpty else { return }
        isRefreshingUsage = true
        for account in accounts { usageErrors[account.id] = nil }

        Task {
            defer { isRefreshingUsage = false }
            for account in accounts {
                do {
                    let snapshot = try await usageService.fetch(
                        profilePaths: paths.profile(account.id),
                        installation: installation,
                        paths: paths
                    )
                    usageByProfile[account.id] = snapshot
                    usageErrors[account.id] = nil
                } catch PrivateFileError.operationInProgress {
                    // Enrollment/switching takes priority. Keep the last results
                    // and let the next timer tick retry after the lock is free.
                    return
                } catch {
                    usageByProfile[account.id] = nil
                    usageErrors[account.id] = error.localizedDescription
                    logger.log("Usage refresh failed for \(account.id.rawValue): \(type(of: error))")
                }
            }
            // Back off after failures too; individual rows show errors and their last timestamp.
            lastUsageRefresh = Date()
        }
    }

    func refreshInstallation() {
        do {
            installation = try controller.installation(preferredPath: config.preferredChatGPTPath)
        } catch {
            installation = nil
            statusMessage = error.localizedDescription
        }
    }

    func switchTo(_ id: ProfileID, force: Bool = false) {
        guard !isSwitching, !isRefreshingUsage else { return }
        synchronizeState()
        guard pendingLoginProfileID == nil else {
            statusMessage = ChatGPTControllerError.loginInProgress.localizedDescription
            return
        }
        let target = config.account(id)
        guard target.isConfigured, hasCredential(id) else {
            beginLoginSetup(id, force: force)
            return
        }

        isSwitching = true
        statusMessage = force ? "正在强制退出并切换…" : "正在切换到 \(target.displayName)…"

        Task {
            do {
                let result = try await controller.switchProfile(
                    to: target,
                    currentProfileID: config.activeProfileID,
                    preferredPath: config.preferredChatGPTPath,
                    launchAfterSwitch: config.automaticallyLaunchChatGPT,
                    force: force
                )
                pendingForceProfileID = nil
                switch result {
                case .alreadyActive:
                    statusMessage = "\(target.displayName) 已在运行"
                case .launched:
                    statusMessage = "已切换到 \(target.displayName)，本地项目与历史保持不变"
                case .stopped:
                    statusMessage = "已选择 \(target.displayName)，未自动打开 ChatGPT"
                }
            } catch ChatGPTControllerError.quitTimedOut {
                pendingForceProfileID = id
                statusMessage = ChatGPTControllerError.quitTimedOut.localizedDescription
            } catch {
                statusMessage = error.localizedDescription
                logger.log("Switch failed for \(id.rawValue): \(type(of: error))")
            }
            isSwitching = false
            synchronizeState()
            registerHotKeys()
            if pendingLoginProfileID == nil { refreshUsageIfNeeded(force: true) }
        }
    }

    func beginLoginSetup(_ id: ProfileID, force: Bool = false) {
        guard !isSwitching, !isRefreshingUsage else { return }
        synchronizeState()
        let target = config.account(id)
        isSwitching = true
        statusMessage = "正在打开 \(target.displayName) 的官方登录窗口…"

        Task {
            do {
                try await controller.beginLoginSetup(
                    for: target,
                    preferredPath: config.preferredChatGPTPath,
                    force: force
                )
                pendingLoginProfileID = id
                statusMessage = "请在 ChatGPT 中完成 \(target.displayName) 登录，然后点击“完成登录”"
            } catch {
                statusMessage = error.localizedDescription
                logger.log("Login setup failed for \(id.rawValue): \(type(of: error))")
            }
            isSwitching = false
            synchronizeState()
            registerHotKeys()
            if pendingLoginProfileID == nil { refreshUsageIfNeeded(force: true) }
        }
    }

    func completeLoginSetup(_ id: ProfileID, force: Bool = false) {
        guard !isSwitching, !isRefreshingUsage else { return }
        synchronizeState()
        let target = config.account(id)
        isSwitching = true
        statusMessage = "正在保存 \(target.displayName) 登录并返回共享工作区…"

        Task {
            do {
                _ = try await controller.completeLoginSetup(
                    for: target,
                    preferredPath: config.preferredChatGPTPath,
                    force: force
                )
                pendingForceProfileID = nil
                statusMessage = "\(target.displayName) 已保存；所有账号共享同一套本地项目与历史"
            } catch {
                statusMessage = error.localizedDescription
                logger.log("Completing login failed for \(id.rawValue): \(type(of: error))")
            }
            isSwitching = false
            synchronizeState()
            registerHotKeys()
            if pendingLoginProfileID == nil { refreshUsageIfNeeded(force: true) }
        }
    }

    func addAccount() {
        guard !isSwitching, !isRefreshingUsage, pendingLoginProfileID == nil else { return }
        var newID: ProfileID?
        guard updateConfiguration({
            let (id, displayName) = nextAccountIdentity()
            config.updateAccount(AccountProfile(id: id, displayName: displayName))
            if let key = nextShortcutKey() { config.shortcuts[id] = HotKeyConfiguration(key: key) }
            newID = id
        }) else { return }
        registerHotKeys()
        if let newID { beginLoginSetup(newID) }
    }

    func cancelLoginSetup() {
        guard !isSwitching, !isRefreshingUsage else { return }
        isSwitching = true
        Task {
            do {
                try await controller.cancelLoginSetup(preferredPath: config.preferredChatGPTPath)
                statusMessage = "已取消登录并恢复共享工作区"
            } catch { statusMessage = error.localizedDescription }
            isSwitching = false
            synchronizeState()
            registerHotKeys()
            if pendingLoginProfileID == nil { refreshUsageIfNeeded(force: true) }
        }
    }

    func adoptCurrentAccount() {
        guard !isSwitching, !isRefreshingUsage, pendingLoginProfileID == nil else { return }
        do {
            let operation = try OperationLock.acquire(paths: paths)
            defer { operation.release() }
            guard try LoginSessionStore(paths: paths).load() == nil else {
                throw ChatGPTControllerError.loginInProgress
            }
            config = try store.load()
            guard !config.account(.accountA).isConfigured else { return }
            let app = try controller.installation(preferredPath: config.preferredChatGPTPath)
            try ChatGPTInspector().verifyTrustedInstallation(app)
            try controller.authStore.adoptCurrentCredential(as: .accountA)
            var account = config.account(.accountA)
            account.isConfigured = true
            config.updateAccount(account)
            config.activeProfileID = .accountA
            try store.save(config)
            statusMessage = "已将当前登录保存为 Account A；当前 Codex 未退出"
        } catch { statusMessage = error.localizedDescription }
        synchronizeState()
        registerHotKeys()
    }

    func openChatGPT() {
        if let active = config.activeProfileID,
           config.account(active).isConfigured,
           hasCredential(active) {
            switchTo(active)
        } else if let first = configuredAccounts.first {
            switchTo(first.id)
        } else {
            statusMessage = "请先添加并登录一个账号"
        }
    }

    func rename(_ id: ProfileID, to rawName: String) {
        _ = updateConfiguration {
            var account = config.account(id)
            account.displayName = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            if account.displayName.isEmpty { account.displayName = id.defaultDisplayName }
            config.updateAccount(account)
        }
    }

    func updateShortcut(_ id: ProfileID, _ shortcut: HotKeyConfiguration) {
        if updateConfiguration({ config.shortcuts[id] = shortcut }) { registerHotKeys() }
    }

    func setAutomaticallyLaunch(_ enabled: Bool) {
        _ = updateConfiguration { config.automaticallyLaunchChatGPT = enabled }
    }

    func setUsageRefreshMinutes(_ minutes: Int) {
        _ = updateConfiguration { config.usageRefreshMinutes = minutes }
    }

    func setPreferredApplication(_ path: String) {
        if updateConfiguration({ config.preferredChatGPTPath = path.isEmpty ? nil : path }) {
            refreshInstallation()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        _ = updateConfiguration {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            config.launchAtLogin = enabled
        }
    }

    func deleteProfile(_ id: ProfileID) {
        guard !isSwitching, !isRefreshingUsage, pendingLoginProfileID == nil else { return }
        do {
            let operation = try OperationLock.acquire(paths: paths)
            defer { operation.release() }
            config = try store.load()
            config.activeProfileID = try controller.authStore.readActiveProfileID()
            try profiles.delete(
                id,
                activeProfileID: config.activeProfileID,
                chatGPTIsRunning: controller.isRunning
            )
            if try controller.authStore.readActiveProfileID() == id {
                try controller.authStore.clearActiveMarker()
            }
            let name = config.account(id).displayName
            config.removeAccount(id)
            usageByProfile[id] = nil
            usageErrors[id] = nil
            if pendingLoginProfileID == id { pendingLoginProfileID = nil }
            try store.save(config)
            registerHotKeys()
            logger.log("Deleted GPT Switcher account slot \(id.rawValue)")
            statusMessage = "已删除 \(name) 的账号登录快照；共享项目和历史未删除"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func openProfileFolder(_ id: ProfileID) {
        do {
            let path = try profiles.prepare(id).root
            NSWorkspace.shared.activateFileViewerSelecting([path])
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func openSharedWorkspaceFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([paths.sharedCodexHome])
    }

    func openLogsFolder() {
        do {
            try paths.createSupportDirectories()
            NSWorkspace.shared.open(paths.logsRoot)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func registerHotKeys() {
        let accountIDs = config.accounts.filter(\.isConfigured).map(\.id)
        HotKeyManager.shared.register(shortcuts: config.shortcuts, accountOrder: accountIDs) { [weak self] id in
            guard let self else { return }
            guard self.account(id).isConfigured, self.hasCredential(id) else {
                self.statusMessage = "请先完成 \(self.account(id).displayName) 登录"
                return
            }
            self.switchTo(id)
        }
    }

    private func nextAccountIdentity() -> (ProfileID, String) {
        let used = Set(config.accounts.map(\.id))
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            guard let letter = UnicodeScalar(scalar).map({ String(Character($0)) }) else { continue }
            let raw = "account-\(letter.lowercased())"
            if let id = ProfileID(rawValue: raw), !used.contains(id) {
                return (id, "Account \(letter)")
            }
        }
        let raw = "account-\(UUID().uuidString.lowercased())"
        return (ProfileID(rawValue: raw)!, "新账号")
    }

    private func nextShortcutKey() -> String? {
        let used = Set(config.shortcuts.values.map { $0.key.uppercased() })
        return (1...9).map(String.init).first { !used.contains($0) }
    }

    func synchronizeState() {
        guard !isSwitching, !isRefreshingUsage else { return }
        do {
            let operation = try OperationLock.acquire(paths: paths)
            defer { operation.release() }
            config = try store.load()
            config.activeProfileID = try controller.authStore.readActiveProfileID()
            pendingLoginProfileID = try LoginSessionStore(paths: paths).load()?.profileID
            if statusMessage == PrivateFileError.operationInProgress.localizedDescription {
                statusMessage = nil
            }
        } catch {
            // A busy external operation must not overwrite an in-progress UI state.
            statusMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func updateConfiguration(_ change: () throws -> Void) -> Bool {
        guard !isSwitching, !isRefreshingUsage else { return false }
        do {
            let operation = try OperationLock.acquire(paths: paths)
            defer { operation.release() }
            config = try store.load()
            config.activeProfileID = try controller.authStore.readActiveProfileID()
            try change()
            try store.save(config)
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }
}
