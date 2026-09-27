import Foundation

public struct GPTSwitcherPaths: Sendable {
    public let applicationSupportRoot: URL
    public let logsRoot: URL
    private let sharedCodexHomeOverride: URL?
    private let sharedChatGPTDataOverride: URL?

    public init(
        applicationSupportRoot: URL,
        logsRoot: URL,
        sharedCodexHome: URL? = nil,
        sharedChatGPTData: URL? = nil
    ) {
        self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
        self.logsRoot = logsRoot.standardizedFileURL
        self.sharedCodexHomeOverride = sharedCodexHome?.standardizedFileURL
        self.sharedChatGPTDataOverride = sharedChatGPTData?.standardizedFileURL
    }

    public static var live: GPTSwitcherPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return GPTSwitcherPaths(
            applicationSupportRoot: home
                .appendingPathComponent("Library/Application Support/GPT Switcher", isDirectory: true),
            logsRoot: home.appendingPathComponent("Library/Logs/GPT Switcher", isDirectory: true)
        )
    }

    public var profilesRoot: URL {
        applicationSupportRoot.appendingPathComponent("profiles", isDirectory: true)
    }

    public var configURL: URL {
        applicationSupportRoot.appendingPathComponent("config.json")
    }

    public var activeAuthMarkerURL: URL {
        applicationSupportRoot.appendingPathComponent("active-auth-profile.json")
    }

    public var operationLockURL: URL {
        applicationSupportRoot.appendingPathComponent("operation.lock")
    }

    public var loginSessionURL: URL {
        applicationSupportRoot.appendingPathComponent("pending-login.json")
    }

    public var migrationBackupRoot: URL {
        applicationSupportRoot.appendingPathComponent("migration-backup", isDirectory: true)
    }

    public var originalSharedAuthBackupURL: URL {
        migrationBackupRoot.appendingPathComponent("original-auth.json")
    }

    public var sharedCodexHome: URL {
        sharedCodexHomeOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public var sharedAuthURL: URL {
        sharedCodexHome.appendingPathComponent("auth.json")
    }

    public var sharedChatGPTData: URL {
        sharedChatGPTDataOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Codex", isDirectory: true)
    }

    public func profile(_ id: ProfileID) -> ProfilePaths {
        let root = profilesRoot.appendingPathComponent(id.rawValue, isDirectory: true)
        return ProfilePaths(
            root: root,
            chatGPT: root.appendingPathComponent("chatgpt", isDirectory: true),
            codex: root.appendingPathComponent("codex", isDirectory: true)
        )
    }

    public func createProfileDirectories(for id: ProfileID) throws -> ProfilePaths {
        try createSupportDirectories()
        let profile = profile(id)
        try createPrivateDirectory(profile.chatGPT)
        try createPrivateDirectory(profile.codex)
        return profile
    }

    public func createSupportDirectories() throws {
        try createPrivateDirectory(applicationSupportRoot)
        try createPrivateDirectory(profilesRoot)
        try createPrivateDirectory(logsRoot)
        try createPrivateDirectory(migrationBackupRoot)
    }

    /// Creates only managed support/log directories, rejecting symlinks at every
    /// managed path component. Permissions must be applied successfully.
    public func createPrivateDirectory(_ url: URL) throws {
        try validatePrivatePath(url, includeSharedHome: false)
        let candidate = url.standardizedFileURL
        guard let root = [applicationSupportRoot, logsRoot].first(where: {
            candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/")
        }) else { throw PrivateFileError.unsafePath }
        var current = root
        var components = [root]
        for part in candidate.path.dropFirst(root.path.count).split(separator: "/") {
            current.appendPathComponent(String(part))
            components.append(current)
        }
        for component in components {
            try validatePrivatePath(component, includeSharedHome: false)
            try FileManager.default.createDirectory(
                at: component,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try validatePrivatePath(component, includeSharedHome: false)
            try PrivateFileIO.secureDirectory(component)
        }
    }

    public func validatePrivatePath(_ url: URL, includeSharedHome: Bool = true) throws {
        let candidate = url.standardizedFileURL
        let roots = [applicationSupportRoot, logsRoot] + (includeSharedHome ? [sharedCodexHome] : [])
        guard let root = roots.first(where: {
            candidate.path == $0.path || candidate.path.hasPrefix($0.path + "/")
        }) else { throw PrivateFileError.unsafePath }
        try PrivateFileIO.rejectSymlinkComponents(root: root, destination: candidate)
    }

    public func createSharedCodexDirectory() throws {
        try validatePrivatePath(sharedCodexHome)
        try FileManager.default.createDirectory(
            at: sharedCodexHome, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validatePrivatePath(sharedCodexHome)
        try PrivateFileIO.secureDirectory(sharedCodexHome)
    }
}
