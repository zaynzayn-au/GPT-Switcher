import Foundation

public enum ProfileManagerError: LocalizedError {
    case unsafePath
    case activeProfileRunning
    case loginInProgress

    public var errorDescription: String? {
        switch self {
        case .unsafePath:
            return "Profile 路径不属于 GPT Switcher，已拒绝删除。"
        case .activeProfileRunning:
            return "请先切换或退出当前 ChatGPT，再删除这个 Profile。"
        case .loginInProgress:
            return "这个账号正在登录，请先完成或取消登录再删除。"
        }
    }
}

public struct ProfileManager {
    public let paths: GPTSwitcherPaths

    public init(paths: GPTSwitcherPaths = .live) {
        self.paths = paths
    }

    public func prepare(_ id: ProfileID) throws -> ProfilePaths {
        try paths.createProfileDirectories(for: id)
    }

    public func delete(_ id: ProfileID, activeProfileID: ProfileID?, chatGPTIsRunning: Bool) throws {
        // The caller holds OperationLock. Consult persisted state because the
        // GUI may have been open while a CLI operation changed the account.
        if try LoginSessionStore(paths: paths).load()?.profileID == id {
            throw ProfileManagerError.loginInProgress
        }
        let authoritativeID = try AccountAuthStore(paths: paths).readActiveProfileID() ?? activeProfileID
        if authoritativeID == id && chatGPTIsRunning {
            throw ProfileManagerError.activeProfileRunning
        }
        let expected = paths.profilesRoot.appendingPathComponent(id.rawValue, isDirectory: true)
            .standardizedFileURL
        let actual = paths.profile(id).root.standardizedFileURL
        do { try paths.validatePrivatePath(actual) }
        catch { throw ProfileManagerError.unsafePath }
        guard actual == expected,
              actual.deletingLastPathComponent() == paths.profilesRoot.standardizedFileURL else {
            throw ProfileManagerError.unsafePath
        }

        for protectedPath in [paths.applicationSupportRoot, paths.profilesRoot, actual] {
            if (try? protectedPath.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ProfileManagerError.unsafePath
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: actual.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue else { throw ProfileManagerError.unsafePath }
        try FileManager.default.removeItem(at: actual)
    }
}
