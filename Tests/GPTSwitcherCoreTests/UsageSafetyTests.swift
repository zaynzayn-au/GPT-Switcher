import Foundation
import Testing
@testable import GPTSwitcherCore

@Suite("Usage credential and subprocess safety")
struct UsageSafetyTests {
    private struct Fixture {
        let root: URL
        let paths: GPTSwitcherPaths
        let profile: ProfilePaths
        let executable: URL

        init(script: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("GPTSwitcherUsageTests-\(UUID().uuidString)", isDirectory: true)
            paths = GPTSwitcherPaths(
                applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true),
                logsRoot: root.appendingPathComponent("logs", isDirectory: true),
                sharedCodexHome: root.appendingPathComponent("shared", isDirectory: true),
                sharedChatGPTData: root.appendingPathComponent("electron", isDirectory: true)
            )
            try paths.createSupportDirectories()
            profile = try paths.createProfileDirectories(for: .accountA)
            try Data("fake-original".utf8).write(to: profile.authSnapshot)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profile.authSnapshot.path)
            executable = root.appendingPathComponent("fixture.sh")
            try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        func run(timeout: TimeInterval = 2) throws -> AccountUsageSnapshot {
            try AccountUsageService.fetchUsingExecutable(
                profilePaths: profile, paths: paths, executable: executable, timeout: timeout
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        var queryDirectories: [URL] {
            (try? FileManager.default.contentsOfDirectory(
                at: paths.applicationSupportRoot.appendingPathComponent("usage-queries"),
                includingPropertiesForKeys: nil
            )) ?? []
        }
    }

    private static let readRequests = "read -r first\nprintf '%s\\n' '{\"id\":1,\"result\":{}}'\nread -r second\nread -r third\n"
    private static let success = #"printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"pro","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800000000}}}}'"# + "\n"

    @Test("A private environment and cwd return usage without exposing parent settings")
    func isolatedSuccess() throws {
        let fixture = try Fixture(script: Self.readRequests + """
        case "$PWD" in */usage-queries/query-*/workspace) ;; *) exit 20 ;; esac
        test "$HOME" != "$(/usr/bin/dirname "$CODEX_HOME")" || exit 21
        test -z "$HTTP_PROXY$HTTPS_PROXY$OPENAI_API_BASE$OPENAI_BASE_URL$DYLD_INSERT_LIBRARIES" || exit 22
        test "$(/usr/bin/stat -f %Lp "$CODEX_HOME/auth.json")" = 600 || exit 23
        /usr/bin/grep -q 'cli_auth_credentials_store = "file"' "$CODEX_HOME/config.toml" || exit 24
        """ + "\n" + Self.success)
        defer { fixture.cleanup() }
        let snapshot = try fixture.run()
        #expect(snapshot.planType == "pro")
        #expect(snapshot.allWindows.first?.remainingPercent == 88)
        #expect(fixture.queryDirectories.isEmpty)
        #expect(try String(contentsOf: fixture.profile.authSnapshot, encoding: .utf8) == "fake-original")
        let environment = AccountUsageService.isolatedEnvironment(
            home: URL(fileURLWithPath: "/fake/home"), codexHome: URL(fileURLWithPath: "/fake/codex"),
            temporaryDirectory: URL(fileURLWithPath: "/fake/tmp")
        )
        #expect(Set(environment.keys) == Set(["PATH", "HOME", "CODEX_HOME", "TMPDIR", "LANG"]))
    }

    @Test("Refreshed credentials survive a rate-limit RPC error")
    func preserveRefreshOnRPCError() throws {
        let fixture = try Fixture(script: Self.readRequests + """
        printf 'fake-refreshed' > "$CODEX_HOME/auth.json"
        printf '%s\\n' '{"id":2,"error":{"code":401}}'
        """)
        defer { fixture.cleanup() }
        do {
            _ = try fixture.run()
            Issue.record("Expected a server error")
        } catch AccountUsageServiceError.serverError(let code) {
            #expect(code == 401)
        }
        #expect(try String(contentsOf: fixture.profile.authSnapshot, encoding: .utf8) == "fake-refreshed")
        #expect(fixture.queryDirectories.isEmpty)
    }

    @Test("A child ignoring TERM is killed within a bounded interval and refresh is preserved")
    func boundedTimeout() throws {
        let fixture = try Fixture(script: Self.readRequests + """
        trap '' TERM
        printf 'fake-refreshed-on-timeout' > "$CODEX_HOME/auth.json"
        while :; do :; done
        """)
        defer { fixture.cleanup() }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try fixture.run(timeout: 1)
            Issue.record("Expected a timeout")
        } catch AccountUsageServiceError.requestTimedOut {}
        #expect(ProcessInfo.processInfo.systemUptime - start < 4)
        #expect(try String(contentsOf: fixture.profile.authSnapshot, encoding: .utf8) == "fake-refreshed-on-timeout")
        #expect(fixture.queryDirectories.isEmpty)
    }

    @Test("Immediate child exit does not signal-kill the parent or leave credentials behind")
    func immediateExit() throws {
        let fixture = try Fixture(script: "exit 0\n")
        defer { fixture.cleanup() }
        #expect(throws: AccountUsageServiceError.self) { _ = try fixture.run(timeout: 0.2) }
        #expect(fixture.queryDirectories.isEmpty)
    }

    @Test("A concurrently changed slot is never overwritten and a recovery copy blocks new queries")
    func conflictingRefresh() throws {
        let fixture = try Fixture(script: "exit 0\n")
        defer { fixture.cleanup() }
        let source = fixture.profile.authSnapshot.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\n" + Self.readRequests
            + "printf 'external-change' > '" + source + "'\n"
            + "printf 'fake-new-refresh' > \"$CODEX_HOME/auth.json\"\n" + Self.success
        try Data(script.utf8).write(to: fixture.executable)
        do {
            _ = try fixture.run()
            Issue.record("Expected recovery to be required")
        } catch AccountUsageServiceError.credentialRecoveryRequired(let directory) {
            #expect(try String(contentsOf: directory.appendingPathComponent("codex/auth.json"), encoding: .utf8) == "fake-new-refresh")
        }
        #expect(try String(contentsOf: fixture.profile.authSnapshot, encoding: .utf8) == "external-change")
        #expect(fixture.queryDirectories.count == 1)
        #expect(throws: AccountUsageServiceError.self) { _ = try fixture.run() }
    }

    @Test("Active queries pass only access-token external auth and never modify shared credentials")
    func activeExternalAuth() throws {
        let fixture = try Fixture(script: Self.readRequests + """
        test ! -e "$CODEX_HOME/auth.json" || exit 31
        /usr/bin/grep -q 'cli_auth_credentials_store = "ephemeral"' "$CODEX_HOME/config.toml" || exit 32
        case "$third" in *fake-access-token*) ;; *) exit 33 ;; esac
        case "$third" in *fake-account-id*) ;; *) exit 34 ;; esac
        case "$third" in *refresh_token*|*never-send-refresh*) exit 35 ;; esac
        printf '%s\\n' '{"id":7,"result":{}}'
        read -r fourth
        """ + "\n" + Self.success)
        defer { fixture.cleanup() }
        let credential = Data(#"{"tokens":{"access_token":"fake-access-token","account_id":"fake-account-id","refresh_token":"never-send-refresh"}}"#.utf8)
        try credential.write(to: fixture.profile.authSnapshot)
        try AccountAuthStore(paths: fixture.paths).activate(.accountA)
        let snapshot = try fixture.run()
        #expect(snapshot.planType == "pro")
        #expect(try Data(contentsOf: fixture.paths.sharedAuthURL) == credential)
        #expect(try Data(contentsOf: fixture.profile.authSnapshot) == credential)
        #expect(fixture.queryDirectories.isEmpty)
    }

    @Test("External refresh requests receive a generic rejection and preserve the active login")
    func externalRefreshRejected() throws {
        let fixture = try Fixture(script: Self.readRequests + """
        printf '%s\\n' '{"id":7,"result":{}}'
        read -r fourth
        printf '%s\\n' '{"id":42,"method":"account/chatgptAuthTokens/refresh","params":{}}'
        read -r fifth
        """)
        defer { fixture.cleanup() }
        let credential = Data(#"{"tokens":{"access_token":"fake-access","account_id":"fake-account","refresh_token":"never-forward"}}"#.utf8)
        try credential.write(to: fixture.profile.authSnapshot)
        try AccountAuthStore(paths: fixture.paths).activate(.accountA)
        do {
            _ = try fixture.run()
            Issue.record("Expected official refresh requirement")
        } catch AccountUsageServiceError.officialRefreshRequired {}
        #expect(try Data(contentsOf: fixture.paths.sharedAuthURL) == credential)
        #expect(fixture.queryDirectories.isEmpty)
    }

    @Test("Pending login blocks usage before a child or credential copy")
    func pendingLoginRejected() throws {
        let fixture = try Fixture(script: Self.readRequests + Self.success)
        defer { fixture.cleanup() }
        try LoginSessionStore(paths: fixture.paths).save(LoginSession(profileID: .accountB, previousProfileID: .accountA))
        do {
            _ = try fixture.run()
            Issue.record("Expected pending login rejection")
        } catch AccountUsageServiceError.loginInProgress {}
        #expect(fixture.queryDirectories.isEmpty)
    }

    @Test("The shared operation lock also protects usage queries")
    func operationLocked() throws {
        let fixture = try Fixture(script: Self.readRequests + Self.success)
        defer { fixture.cleanup() }
        let lock = try OperationLock.acquire(paths: fixture.paths)
        defer { lock.release() }
        #expect(throws: (any Error).self) { _ = try fixture.run() }
        #expect(fixture.queryDirectories.isEmpty)
    }

    @Test("Unsafe credential file permissions fail closed")
    func unsafePermissions() throws {
        let fixture = try Fixture(script: Self.readRequests + Self.success)
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.profile.authSnapshot.path)
        do {
            _ = try fixture.run()
            Issue.record("Expected permission rejection")
        } catch AccountUsageServiceError.unsafeStorage {}
        #expect(fixture.queryDirectories.isEmpty)
    }
}
