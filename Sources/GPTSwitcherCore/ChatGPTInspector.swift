import AppKit
import Foundation
import Security

public struct ChatGPTInstallation: Equatable, Sendable {
    public let appURL: URL
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let chromiumVersion: String?
    public let supportsExplicitUserDataPath: Bool
    public let supportsCodexHome: Bool
    public let isTrustedInstallation: Bool

    public init(
        appURL: URL,
        bundleIdentifier: String,
        version: String,
        build: String,
        chromiumVersion: String?,
        supportsExplicitUserDataPath: Bool,
        supportsCodexHome: Bool,
        isTrustedInstallation: Bool = false
    ) {
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.chromiumVersion = chromiumVersion
        self.supportsExplicitUserDataPath = supportsExplicitUserDataPath
        self.supportsCodexHome = supportsCodexHome
        self.isTrustedInstallation = isTrustedInstallation
    }

    public var isSupported: Bool {
        bundleIdentifier == ChatGPTInspector.expectedBundleIdentifier
            && isTrustedInstallation
            && supportsExplicitUserDataPath
            && supportsCodexHome
    }
}

public enum ChatGPTInspectionError: LocalizedError {
    case notFound
    case invalidBundle(URL)
    case untrustedInstallation(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "未找到官方 Codex / ChatGPT 应用。请将它安装到 /Applications。"
        case .invalidBundle(let url):
            return "无法读取 ChatGPT 应用信息：\(url.path)"
        case .untrustedInstallation:
            return "无法验证应用及其用量查询组件的 OpenAI 开发者签名。为保护登录信息，已停止操作。"
        }
    }
}

public struct ChatGPTInspector {
    public static let expectedBundleIdentifier = "com.openai.codex"
    public static let expectedTeamIdentifier = "2DC432GLL2"
    public static let explicitUserDataEnvironment = "CODEX_ELECTRON_USER_DATA_PATH"

    private static var developerRequirement: String {
        "anchor apple generic "
            + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
            + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
            + "and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\""
    }

    static func bundledCodexExecutable(in appURL: URL) -> URL? {
        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let candidates = [
            "codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "codex",
        ]
        let canonicalApp = appURL.resolvingSymlinksInPath().standardizedFileURL
        return candidates.map { resources.appendingPathComponent($0) }
            .first {
                let canonical = $0.resolvingSymlinksInPath().standardizedFileURL
                return canonical.path.hasPrefix(canonicalApp.path + "/")
                    && FileManager.default.isExecutableFile(atPath: $0.path)
            }
    }

    public init() {}

    public func inspect(preferredPath: String? = nil) throws -> ChatGPTInstallation {
        guard let appURL = locate(preferredPath: preferredPath) else {
            throw ChatGPTInspectionError.notFound
        }
        guard let bundle = Bundle(url: appURL), let info = bundle.infoDictionary else {
            throw ChatGPTInspectionError.invalidBundle(appURL)
        }
        let codexExecutable = try verifiedCodexExecutable(in: appURL)

        let resources = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let asar = resources.appendingPathComponent("app.asar")
        let hasUserDataEnvironment = fileContainsASCII(
            asar,
            needle: Self.explicitUserDataEnvironment
        )
        let hasCodexHome = fileContainsASCII(codexExecutable, needle: "CODEX_HOME")

        return ChatGPTInstallation(
            appURL: appURL,
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "",
            version: info["CFBundleShortVersionString"] as? String ?? "未知",
            build: info["CFBundleVersion"] as? String ?? "未知",
            chromiumVersion: info["ChromiumBaseVersion"] as? String,
            supportsExplicitUserDataPath: hasUserDataEnvironment,
            supportsCodexHome: hasCodexHome,
            isTrustedInstallation: true
        )
    }

    /// Revalidates files on disk; callers must invoke this immediately before
    /// launching either the app or its helper, before making credentials available.
    /// An earlier inspection result is deliberately not a reusable trust cache.
    public func verifyTrustedInstallation(_ installation: ChatGPTInstallation) throws {
        _ = try verifiedCodexExecutable(in: installation.appURL)
    }

    private func verifiedCodexExecutable(in appURL: URL) throws -> URL {
        try verifySignature(
            at: appURL,
            requirement: Self.developerRequirement + " and identifier \"\(Self.expectedBundleIdentifier)\""
        )
        guard let executable = Self.bundledCodexExecutable(in: appURL) else {
            throw ChatGPTInspectionError.untrustedInstallation(appURL)
        }
        // The helper has its own identifier (for example "codex"). Its signing
        // identity must still be OpenAI's Apple-issued Developer ID certificate.
        try verifySignature(at: executable, requirement: Self.developerRequirement)
        return executable
    }

    private func verifySignature(at url: URL, requirement source: String) throws {
        try autoreleasepool {
            var staticCode: SecStaticCode?
            var requirement: SecRequirement?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
                  let staticCode,
                  SecRequirementCreateWithString(source as CFString, [], &requirement) == errSecSuccess,
                  let requirement else {
                throw ChatGPTInspectionError.untrustedInstallation(url)
            }
            // Validate executable bytes, sealed resources and nested code. Do not
            // opt in to network certificate checks: this inspection stays local.
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
            guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
                throw ChatGPTInspectionError.untrustedInstallation(url)
            }
        }
    }

    private func locate(preferredPath: String?) -> URL? {
        Self.locate(
            preferredPath: preferredPath,
            runningAppURLs: NSRunningApplication.runningApplications(withBundleIdentifier: Self.expectedBundleIdentifier)
                .filter { !$0.isTerminated }.compactMap(\.bundleURL),
            standardAppURLs: ["/Applications/Codex.app", "/Applications/ChatGPT.app"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) },
            registeredAppURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.expectedBundleIdentifier)
        )
    }

    static func locate(
        preferredPath: String?,
        runningAppURLs: [URL],
        standardAppURLs: [URL],
        registeredAppURL: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        // An explicit selection is authoritative, including when it is missing:
        // silently falling back could switch the user to a different app version.
        if let preferredPath, !preferredPath.isEmpty {
            return fileExists(preferredPath)
                ? URL(fileURLWithPath: preferredPath).standardizedFileURL : nil
        }
        // Preserve the user's currently running version when no path was chosen.
        let candidates = runningAppURLs + standardAppURLs + [registeredAppURL].compactMap { $0 }
        return candidates.first { fileExists($0.path) }?.standardizedFileURL
    }

    func fileContainsASCII(_ url: URL, needle: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let target = Data(needle.utf8)
        var carry = Data()
        while true {
            // Foundation may autorelease the underlying NSData for each read.
            // Drain each chunk while scanning large bundles instead of retaining
            // their contents until the menu's outer event pool is drained.
            let finished: Bool? = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty else { return false }
                var searchable = carry
                searchable.append(chunk)
                if searchable.range(of: target) != nil { return true }
                carry = Data(searchable.suffix(max(0, target.count - 1)))
                return nil
            }
            if let finished { return finished }
        }
    }
}
