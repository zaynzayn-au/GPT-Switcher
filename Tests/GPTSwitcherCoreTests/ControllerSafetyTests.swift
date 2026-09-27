import Foundation
import Testing
@testable import GPTSwitcherCore

@Suite("Controller safety")
struct ControllerSafetyTests {
    private func paths() -> GPTSwitcherPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GPTSwitcherControllerTests-" + UUID().uuidString)
        return GPTSwitcherPaths(applicationSupportRoot: root.appendingPathComponent("support"),
            logsRoot: root.appendingPathComponent("logs"), sharedCodexHome: root.appendingPathComponent("shared"),
            sharedChatGPTData: root.appendingPathComponent("desktop"))
    }

    @Test("Pending login prevents all normal switching before inspecting or touching any app")
    @MainActor func pendingLoginRejectsSwitch() async throws {
        let p = paths()
        defer { try? FileManager.default.removeItem(at: p.applicationSupportRoot.deletingLastPathComponent()) }
        try LoginSessionStore(paths: p).save(LoginSession(profileID: .accountB, previousProfileID: .accountA))
        let controller = ChatGPTController(paths: p)
        do {
            _ = try await controller.switchProfile(to: AccountProfile(id: .accountA), currentProfileID: .accountA)
            Issue.record("Switch should reject pending enrollment")
        } catch ChatGPTControllerError.loginInProgress { }
        #expect(!FileManager.default.fileExists(atPath: p.sharedAuthURL.path))
    }

    @Test("Completing the wrong enrollment cannot launch a client or activate a credential")
    @MainActor func wrongEnrollmentRejected() async throws {
        let p = paths()
        defer { try? FileManager.default.removeItem(at: p.applicationSupportRoot.deletingLastPathComponent()) }
        try LoginSessionStore(paths: p).save(LoginSession(profileID: .accountB, previousProfileID: .accountA))
        do {
            _ = try await ChatGPTController(paths: p).completeLoginSetup(for: AccountProfile(id: .accountA))
            Issue.record("Mismatched enrollment must fail")
        } catch ChatGPTControllerError.noMatchingLogin { }
        #expect(!FileManager.default.fileExists(atPath: p.sharedAuthURL.path))
    }

    @Test("Another process operation prevents switching before any app or auth mutation")
    @MainActor func operationLockRejectsSwitch() async throws {
        let p = paths()
        defer { try? FileManager.default.removeItem(at: p.applicationSupportRoot.deletingLastPathComponent()) }
        let lock = try OperationLock.acquire(paths: p)
        defer { lock.release() }
        do {
            _ = try await ChatGPTController(paths: p).switchProfile(to: AccountProfile(id: .accountB), currentProfileID: .accountA)
            Issue.record("Must not run a concurrent switch")
        } catch PrivateFileError.operationInProgress { }
        #expect(!FileManager.default.fileExists(atPath: p.sharedAuthURL.path))
    }

    @Test("Old configurations default to five minute refresh; disabled setting survives round trip")
    func refreshConfigMigration() throws {
        var config = SwitcherConfig()
        #expect(config.effectiveUsageRefreshMinutes == 5)
        config.usageRefreshMinutes = 0
        let decoded = try JSONDecoder().decode(SwitcherConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.effectiveUsageRefreshMinutes == 0)
        config.usageRefreshMinutes = 2
        #expect(config.effectiveUsageRefreshMinutes == 5)
    }

    @Test("Browser enrollment rejects an already configured inactive slot before app inspection")
    @MainActor func configuredBrowserSlotRejected() async throws {
        let p = paths()
        defer { try? FileManager.default.removeItem(at: p.applicationSupportRoot.deletingLastPathComponent()) }
        var config = SwitcherConfig()
        config.updateAccount(AccountProfile(id: .accountB, isConfigured: true))
        try ConfigStore(paths: p).save(config)
        do {
            try await ChatGPTController(paths: p).enrollUsingBrowser(for: .accountB, preferredPath: p.applicationSupportRoot.path)
            Issue.record("Configured slot must not be replaced")
        } catch ChatGPTControllerError.accountSlotOccupied { }
        #expect(try ConfigStore(paths: p).load() == config)
        #expect(!FileManager.default.fileExists(atPath: p.sharedAuthURL.path))
    }

    @Test("Browser enrollment preserves a credential orphaned before configuration was saved")
    @MainActor func orphanedBrowserSlotRejected() async throws {
        let p = paths()
        defer { try? FileManager.default.removeItem(at: p.applicationSupportRoot.deletingLastPathComponent()) }
        let id = ProfileID(rawValue: "account-c")!
        let profile = try p.createProfileDirectories(for: id)
        let fake = Data("recoverable-fake-login".utf8)
        try fake.write(to: profile.authSnapshot)
        do {
            try await ChatGPTController(paths: p).enrollUsingBrowser(for: id, preferredPath: p.applicationSupportRoot.path)
            Issue.record("An existing orphaned credential must occupy its slot")
        } catch ChatGPTControllerError.accountSlotOccupied { }
        #expect(try Data(contentsOf: profile.authSnapshot) == fake)
        #expect(!FileManager.default.fileExists(atPath: p.sharedAuthURL.path))
    }

    @Test("An empty credential is preserved for explicit recovery rather than silently overwritten")
    @MainActor func malformedBrowserSlotRejected() async throws {
        let p = paths()
        defer { try? FileManager.default.removeItem(at: p.applicationSupportRoot.deletingLastPathComponent()) }
        let profile = try p.createProfileDirectories(for: .accountB)
        try Data().write(to: profile.authSnapshot)
        do {
            try await ChatGPTController(paths: p).enrollUsingBrowser(for: .accountB, preferredPath: p.applicationSupportRoot.path)
            Issue.record("Even an empty auth file must not be silently replaced")
        } catch ChatGPTControllerError.accountSlotOccupied { }
        #expect(try Data(contentsOf: profile.authSnapshot).isEmpty)
    }

    @Test("CLI-added accounts receive free shortcuts without replacing user preferences")
    @MainActor func browserShortcuts() throws {
        let p = paths()
        defer { try? FileManager.default.removeItem(at: p.applicationSupportRoot.deletingLastPathComponent()) }
        let lock = try OperationLock.acquire(paths: p)
        defer { lock.release() }
        let store = ConfigStore(paths: p)
        let controller = ChatGPTController(paths: p)
        let c = ProfileID(rawValue: "account-c")!
        let d = ProfileID(rawValue: "account-d")!
        try controller.synchronizeConfiguration(configuredProfile: c)
        try controller.synchronizeConfiguration(configuredProfile: d)
        var config = try store.load()
        #expect(config.account(c).isConfigured)
        #expect(config.account(d).isConfigured)
        #expect(config.shortcuts[c]?.key == "3")
        #expect(config.shortcuts[d]?.key == "4")
        config.shortcuts[c] = HotKeyConfiguration(key: "", command: false, option: false)
        config.shortcuts[d] = HotKeyConfiguration(key: "K", command: true, option: false, control: true)
        try store.save(config)
        try controller.synchronizeConfiguration(configuredProfile: c)
        try controller.synchronizeConfiguration(configuredProfile: d)
        #expect(try store.load().shortcuts == config.shortcuts)
    }
}
