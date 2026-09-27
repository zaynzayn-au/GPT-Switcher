import Foundation
import Testing
@testable import GPTSwitcherCore

@Suite("Read-only account identity checks")
struct AccountIdentityCheckTests {
    private struct Fixture {
        let root: URL
        let paths: GPTSwitcherPaths
        let ids = [ProfileID.accountA, .accountB, ProfileID(rawValue: "account-c")!, ProfileID(rawValue: "account-d")!]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("GPTSwitcherIdentityTests-\(UUID().uuidString)")
            paths = GPTSwitcherPaths(
                applicationSupportRoot: root.appendingPathComponent("support"),
                logsRoot: root.appendingPathComponent("logs"),
                sharedCodexHome: root.appendingPathComponent("shared"),
                sharedChatGPTData: root.appendingPathComponent("electron")
            )
            try paths.createSupportDirectories()
            let accounts = ids.map { AccountProfile(id: $0, displayName: "label-may-contain-an-email@example.invalid", isConfigured: true) }
            try ConfigStore(paths: paths).save(SwitcherConfig(accounts: accounts))
            for (index, id) in ids.enumerated() {
                _ = try paths.createProfileDirectories(for: id)
                try writeIdentity("private-fixture-id-\(index)", to: paths.profile(id).authSnapshot)
            }
        }

        func writeIdentity(_ identity: String, to url: URL) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "tokens": ["account_id": identity, "access_token": "private-fixture-access", "refresh_token": "private-fixture-refresh"],
                "email": "private-fixture-email@example.invalid",
            ])
            try PrivateFileIO.atomicWrite(data, to: url)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Four different local identities return only slot names and never change stored data")
    func distinctSlots() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let before = try fixture.ids.map { try Data(contentsOf: fixture.paths.profile($0).authSnapshot) }
        let configBefore = try Data(contentsOf: fixture.paths.configURL)
        let result = try AccountIdentityCheck.checkConfiguredAccounts(paths: fixture.paths)
        #expect(result.allDistinct)
        #expect(result.verifiedSlots == fixture.ids)
        #expect(result.duplicateGroups.isEmpty)
        #expect(result.unverifiableSlots.isEmpty)
        let description = String(reflecting: result)
        #expect(!description.contains("private-fixture"))
        #expect(!description.contains("example.invalid"))
        #expect(try fixture.ids.map { try Data(contentsOf: fixture.paths.profile($0).authSnapshot) } == before)
        #expect(try Data(contentsOf: fixture.paths.configURL) == configBefore)
    }

    @Test("Repeated identities group their slots without returning the identity")
    func duplicateGroups() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeIdentity("private-same-a-c", to: fixture.paths.profile(fixture.ids[0]).authSnapshot)
        try fixture.writeIdentity("private-same-a-c", to: fixture.paths.profile(fixture.ids[2]).authSnapshot)
        try fixture.writeIdentity("private-same-b-d", to: fixture.paths.profile(fixture.ids[1]).authSnapshot)
        try fixture.writeIdentity("private-same-b-d", to: fixture.paths.profile(fixture.ids[3]).authSnapshot)
        let result = try AccountIdentityCheck.checkConfiguredAccounts(paths: fixture.paths)
        #expect(!result.allDistinct)
        #expect(result.duplicateGroups == [[fixture.ids[0], fixture.ids[2]], [fixture.ids[1], fixture.ids[3]]])
        #expect(!String(reflecting: result).contains("private-same"))
    }

    @Test("Missing, malformed, or absent account IDs prevent an all-different conclusion")
    func incompleteIdentities() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.paths.profile(fixture.ids[0]).authSnapshot)
        try PrivateFileIO.atomicWrite(Data("not-json".utf8), to: fixture.paths.profile(fixture.ids[1]).authSnapshot)
        try PrivateFileIO.atomicWrite(Data(#"{"tokens":{"access_token":"not-an-identity"}}"#.utf8), to: fixture.paths.profile(fixture.ids[2]).authSnapshot)
        let result = try AccountIdentityCheck.checkConfiguredAccounts(paths: fixture.paths)
        #expect(!result.allDistinct)
        #expect(result.verifiedSlots == [fixture.ids[3]])
        #expect(result.unverifiableSlots == Array(fixture.ids.prefix(3)))
    }

    @Test("Active slot reads shared auth in preference to its stale snapshot")
    func activeSharedPreferred() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeIdentity("private-fixture-id-1", to: fixture.paths.profile(.accountA).authSnapshot)
        try AccountAuthStore(paths: fixture.paths).activate(.accountA)
        try fixture.writeIdentity("private-active-updated", to: fixture.paths.sharedAuthURL)
        let sharedBefore = try Data(contentsOf: fixture.paths.sharedAuthURL)
        let slotBefore = try Data(contentsOf: fixture.paths.profile(.accountA).authSnapshot)
        let result = try AccountIdentityCheck.checkConfiguredAccounts(paths: fixture.paths)
        #expect(result.allDistinct)
        #expect(try Data(contentsOf: fixture.paths.sharedAuthURL) == sharedBefore)
        #expect(try Data(contentsOf: fixture.paths.profile(.accountA).authSnapshot) == slotBefore)
        try FileManager.default.removeItem(at: fixture.paths.sharedAuthURL)
        let missingShared = try AccountIdentityCheck.checkConfiguredAccounts(paths: fixture.paths)
        #expect(!missingShared.allDistinct)
        #expect(missingShared.unverifiableSlots == [.accountA])
    }

    @Test("Unsafe permissions and symlinks are reported as unverifiable")
    func unsafeFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.paths.profile(.accountA).authSnapshot.path)
        let link = fixture.paths.profile(.accountB).authSnapshot
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.paths.profile(fixture.ids[2]).authSnapshot)
        let result = try AccountIdentityCheck.checkConfiguredAccounts(paths: fixture.paths)
        #expect(!result.allDistinct)
        #expect(result.unverifiableSlots == [.accountA, .accountB])
    }

    @Test("No identity reads proceed while another operation holds the shared lock")
    func operationLocked() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let lock = try OperationLock.acquire(paths: fixture.paths)
        defer { lock.release() }
        #expect(throws: PrivateFileError.self) {
            _ = try AccountIdentityCheck.checkConfiguredAccounts(paths: fixture.paths)
        }
    }

    @Test("Unconfigured slots are excluded and one configured account is not a multi-account verification")
    func unconfiguredExcluded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var config = try ConfigStore(paths: fixture.paths).load()
        for index in 1..<config.accounts.count { config.accounts[index].isConfigured = false }
        try ConfigStore(paths: fixture.paths).save(config)
        let result = try AccountIdentityCheck.checkConfiguredAccounts(paths: fixture.paths)
        #expect(result.configuredCount == 1)
        #expect(result.verifiedSlots == [.accountA])
        #expect(!result.allDistinct)
    }
}
