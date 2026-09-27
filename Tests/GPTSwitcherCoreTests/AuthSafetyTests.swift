import Foundation
import Testing
@testable import GPTSwitcherCore

@Suite("Credential safety", .serialized)
struct AuthSafetyTests {
    private func withPaths(_ body: (GPTSwitcherPaths) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTSwitcherSafety-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(GPTSwitcherPaths(
            applicationSupportRoot: root.appendingPathComponent("support"),
            logsRoot: root.appendingPathComponent("logs"),
            sharedCodexHome: root.appendingPathComponent("shared"),
            sharedChatGPTData: root.appendingPathComponent("chatgpt")
        ))
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test("Independent lock acquisitions exclude each other and release is idempotent")
    func operationLock() throws {
        try withPaths { paths in
            let first = try OperationLock.acquire(paths: paths)
            #expect(throws: PrivateFileError.self) { try OperationLock.acquire(paths: paths) }
            first.release()
            first.release()
            let second = try OperationLock.acquire(paths: paths)
            second.release()
            #expect(try permissions(paths.applicationSupportRoot) == 0o700)
            #expect(try permissions(paths.operationLockURL) == 0o600)
        }
    }

    @Test("Lock deinitialization releases its descriptor")
    func lockDeinit() throws {
        try withPaths { paths in
            var token: OperationLock.Token? = try OperationLock.acquire(paths: paths)
            #expect(token != nil)
            token = nil
            let replacement = try OperationLock.acquire(paths: paths)
            replacement.release()
        }
    }

    @Test("A symlinked support root is rejected before altering its destination")
    func supportSymlink() throws {
        try withPaths { paths in
            let external = paths.applicationSupportRoot.deletingLastPathComponent().appendingPathComponent("external")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: external.path)
            try FileManager.default.createSymbolicLink(at: paths.applicationSupportRoot, withDestinationURL: external)
            #expect(throws: PrivateFileError.self) { try OperationLock.acquire(paths: paths) }
            #expect(try permissions(external) == 0o755)
            #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent("operation.lock").path))
        }
    }

    @Test("Pending login persists with private permissions and malformed state fails closed")
    func loginSession() throws {
        try withPaths { paths in
            let store = LoginSessionStore(paths: paths)
            #expect(try store.load() == nil)
            let session = LoginSession(profileID: .accountB, previousProfileID: .accountA)
            try store.save(session)
            #expect(try store.load() == session)
            #expect(try permissions(paths.loginSessionURL) == 0o600)
            try Data("malformed".utf8).write(to: paths.loginSessionURL)
            #expect(throws: (any Error).self) { try store.load() }
            try store.clear()
            #expect(try store.load() == nil)
        }
    }

    @Test("Nested symlink auth directories cannot replace shared credentials")
    func nestedSymlink() throws {
        try withPaths { paths in
            try paths.createSupportDirectories()
            try paths.createSharedCodexDirectory()
            try Data("original-fake".utf8).write(to: paths.sharedAuthURL)
            let profile = paths.profile(.accountA)
            let external = paths.applicationSupportRoot.appendingPathComponent("external")
            try paths.createPrivateDirectory(external)
            try Data("other-fake".utf8).write(to: external.appendingPathComponent("auth.json"))
            try paths.createPrivateDirectory(profile.root)
            try FileManager.default.createSymbolicLink(at: profile.codex, withDestinationURL: external)
            #expect(throws: (any Error).self) { try paths.createProfileDirectories(for: .accountA) }
            #expect(throws: AccountAuthStoreError.self) { try AccountAuthStore(paths: paths).activate(.accountA) }
            #expect(try Data(contentsOf: paths.sharedAuthURL) == Data("original-fake".utf8))
        }
    }

    @Test("Rollback restores exact active credentials and marker without using the old migration backup")
    func rollback() throws {
        try withPaths { paths in
            let a = try paths.createProfileDirectories(for: .accountA)
            let b = try paths.createProfileDirectories(for: .accountB)
            try paths.createSharedCodexDirectory()
            try Data("original-fake".utf8).write(to: paths.sharedAuthURL)
            try Data("a-fake".utf8).write(to: a.authSnapshot)
            try Data("b-fake".utf8).write(to: b.authSnapshot)
            let store = AccountAuthStore(paths: paths)
            try store.activate(.accountA)
            try Data("a-refreshed-fake".utf8).write(to: paths.sharedAuthURL)
            let checkpoint = try store.captureCurrentState()
            try store.activate(.accountB)
            try store.restoreCurrentState(checkpoint)
            #expect(try store.readActiveProfileID() == .accountA)
            #expect(try Data(contentsOf: paths.sharedAuthURL) == Data("a-refreshed-fake".utf8))
            #expect(try Data(contentsOf: paths.originalSharedAuthBackupURL) == Data("original-fake".utf8))
            #expect(try permissions(paths.sharedAuthURL) == 0o600)
            #expect(try permissions(paths.activeAuthMarkerURL) == 0o600)
        }
    }

    @Test("Rollback can restore the absence of an initial login")
    func rollbackNoOriginal() throws {
        try withPaths { paths in
            let a = try paths.createProfileDirectories(for: .accountA)
            try Data("a-fake".utf8).write(to: a.authSnapshot)
            let store = AccountAuthStore(paths: paths)
            let checkpoint = try store.captureCurrentState()
            try store.activate(.accountA)
            try store.restoreCurrentState(checkpoint)
            #expect(!FileManager.default.fileExists(atPath: paths.sharedAuthURL.path))
            #expect(try store.readActiveProfileID() == nil)
        }
    }

    @Test("Deletion protects pending login and authoritative active state despite stale GUI state")
    func deletionState() throws {
        try withPaths { paths in
            let b = try paths.createProfileDirectories(for: .accountB)
            try Data("b-fake".utf8).write(to: b.authSnapshot)
            let manager = ProfileManager(paths: paths)
            let sessions = LoginSessionStore(paths: paths)
            try sessions.save(LoginSession(profileID: .accountB, previousProfileID: .accountA))
            #expect(throws: ProfileManagerError.self) {
                try manager.delete(.accountB, activeProfileID: .accountA, chatGPTIsRunning: false)
            }
            try sessions.clear()
            try AccountAuthStore(paths: paths).activate(.accountB)
            #expect(throws: ProfileManagerError.self) {
                try manager.delete(.accountB, activeProfileID: .accountA, chatGPTIsRunning: true)
            }
            #expect(FileManager.default.fileExists(atPath: b.authSnapshot.path))
        }
    }

    @Test("Adopting the current login only copies opaque bytes and records its slot")
    func adoptCurrent() throws {
        try withPaths { paths in
            try paths.createSharedCodexDirectory()
            let fake = Data("fake-current-login".utf8)
            try fake.write(to: paths.sharedAuthURL)
            let originalModification = try paths.sharedAuthURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let store = AccountAuthStore(paths: paths)
            try store.adoptCurrentCredential(as: .accountA)
            #expect(try Data(contentsOf: paths.sharedAuthURL) == fake)
            #expect(try paths.sharedAuthURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == originalModification)
            #expect(try Data(contentsOf: paths.profile(.accountA).authSnapshot) == fake)
            #expect(try Data(contentsOf: paths.originalSharedAuthBackupURL) == fake)
            #expect(try store.readActiveProfileID() == .accountA)
            #expect(try permissions(paths.profile(.accountA).authSnapshot) == 0o600)
        }
    }

    @Test("Fresh enrollment preserves existing slots until explicitly imported")
    func stagedEnrollment() throws {
        try withPaths { paths in
            let existing = try paths.createProfileDirectories(for: .accountB)
            let old = Data("old-b-fake".utf8)
            try old.write(to: existing.authSnapshot)
            let session = LoginSession(profileID: .accountB, previousProfileID: .accountA)
            let sessions = LoginSessionStore(paths: paths)
            try sessions.save(session)
            let staged = try session.enrollmentPaths(in: paths)
            #expect(staged.root != existing.root)
            #expect(!FileManager.default.fileExists(atPath: staged.authSnapshot.path))
            let restored = try #require(try sessions.load())
            #expect(try restored.enrollmentPaths(in: paths) == staged)
            try Data("new-b-fake".utf8).write(to: staged.authSnapshot)
            #expect(try Data(contentsOf: existing.authSnapshot) == old)
            #expect(try permissions(staged.root) == 0o700)
            try AccountAuthStore(paths: paths).saveCredential(from: staged.authSnapshot, for: .accountB)
            #expect(try Data(contentsOf: existing.authSnapshot) == Data("new-b-fake".utf8))
            #expect(try permissions(existing.authSnapshot) == 0o600)
            #expect(!FileManager.default.fileExists(atPath: paths.sharedAuthURL.path))
        }
    }
}
