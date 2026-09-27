import Foundation
import Testing
@testable import GPTSwitcherCore

@Suite("Official application trust and selection")
struct InspectorSafetyTests {
    @Test("Bounded compatibility scans match strings across read boundaries")
    func compatibilityScanBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTSwitcherScanTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("fixture.bin")
        var bytes = Data(repeating: 0x78, count: 1_048_576 - 5)
        bytes.append(Data("CODEX_HOME".utf8))
        bytes.append(Data(repeating: 0x78, count: 1_048_576))
        try bytes.write(to: file)

        let inspector = ChatGPTInspector()
        #expect(inspector.fileContainsASCII(file, needle: "CODEX_HOME"))
        #expect(!inspector.fileContainsASCII(file, needle: "CODEX_ELECTRON_USER_DATA_PATH"))
        #expect(!inspector.fileContainsASCII(root.appendingPathComponent("missing"), needle: "CODEX_HOME"))
    }

    @Test("A forged bundle identifier and compatibility strings do not establish trust")
    func forgedBundleRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTSwitcherInspectorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.openai.codex",
            "CFBundleExecutable": "ChatGPT",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "999.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("CODEX_ELECTRON_USER_DATA_PATH".utf8).write(to: resources.appendingPathComponent("app.asar"))
        for executable in [macOS.appendingPathComponent("ChatGPT"), resources.appendingPathComponent("codex")] {
            try Data("CODEX_HOME".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        #expect(throws: ChatGPTInspectionError.self) {
            _ = try ChatGPTInspector().inspect(preferredPath: app.path)
        }
    }

    @Test("Compatibility flags alone cannot mark an installation supported")
    func compatibilityIsNotTrust() {
        let installation = ChatGPTInstallation(
            appURL: URL(fileURLWithPath: "/untrusted/ChatGPT.app"),
            bundleIdentifier: "com.openai.codex", version: "1", build: "1", chromiumVersion: nil,
            supportsExplicitUserDataPath: true, supportsCodexHome: true
        )
        #expect(!installation.isSupported)
    }

    @Test("A claimed prior trust result does not bypass on-disk verification")
    func claimedTrustMustBeRevalidated() {
        let installation = ChatGPTInstallation(
            appURL: URL(fileURLWithPath: "/usr/bin/true"),
            bundleIdentifier: "com.openai.codex", version: "1", build: "1", chromiumVersion: nil,
            supportsExplicitUserDataPath: true, supportsCodexHome: true, isTrustedInstallation: true
        )
        #expect(throws: ChatGPTInspectionError.self) {
            try ChatGPTInspector().verifyTrustedInstallation(installation)
        }
    }

    @Test("Explicit app selection takes precedence and never silently falls back")
    func preferredSelection() {
        let preferred = URL(fileURLWithPath: "/selected/Codex.app")
        let running = URL(fileURLWithPath: "/running/ChatGPT.app")
        #expect(ChatGPTInspector.locate(
            preferredPath: preferred.path, runningAppURLs: [running], standardAppURLs: [], registeredAppURL: nil,
            fileExists: { _ in true }
        ) == preferred)
        #expect(ChatGPTInspector.locate(
            preferredPath: preferred.path, runningAppURLs: [running], standardAppURLs: [], registeredAppURL: nil,
            fileExists: { $0 == running.path }
        ) == nil)
    }

    @Test("The running official app is retained instead of switching versions")
    func runningVersionSelection() {
        let running = URL(fileURLWithPath: "/running/ChatGPT.app")
        let installed = URL(fileURLWithPath: "/Applications/Codex.app")
        #expect(ChatGPTInspector.locate(
            preferredPath: nil, runningAppURLs: [running], standardAppURLs: [installed], registeredAppURL: installed,
            fileExists: { _ in true }
        ) == running)
        #expect(ChatGPTInspector.locate(
            preferredPath: nil, runningAppURLs: [], standardAppURLs: [installed], registeredAppURL: running,
            fileExists: { _ in true }
        ) == installed)
    }

    @Test("An embedded helper cannot escape its application through a symbolic link")
    func helperSymlinkEscapeRejected() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GPTSwitcherHelperTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: resources.appendingPathComponent("codex"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        #expect(ChatGPTInspector.bundledCodexExecutable(in: app) == nil)
    }
}
