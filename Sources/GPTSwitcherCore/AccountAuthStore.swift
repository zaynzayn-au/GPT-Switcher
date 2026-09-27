import Foundation

public enum AccountAuthStoreError: LocalizedError {
    case missingCredential(ProfileID)
    case unsafeCredentialFile

    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "这个账号还没有保存登录状态，请先完成账号登录。"
        case .unsafeCredentialFile:
            return "登录状态文件不安全或格式异常，已停止切换。"
        }
    }
}

private struct ActiveAuthMarker: Codable {
    let profileID: ProfileID
}

/// An opaque, in-memory rollback checkpoint. Credential bytes are never decoded.
public struct AccountAuthState: Sendable {
    fileprivate let authData: Data?
    public let profileID: ProfileID?
}

/// Moves opaque, official Codex auth files between private account slots.
/// The contents are never decoded, inspected, or logged by GPT Switcher.
public final class AccountAuthStore: @unchecked Sendable {
    public let paths: GPTSwitcherPaths
    private let fileManager: FileManager

    public init(paths: GPTSwitcherPaths = .live, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func hasCredential(for id: ProfileID) -> Bool {
        isSafeCredentialFile(paths.profile(id).authSnapshot)
    }

    public func activeProfileID() -> ProfileID? {
        try? readActiveProfileID()
    }

    public func readActiveProfileID() throws -> ProfileID? {
        try paths.validatePrivatePath(paths.activeAuthMarkerURL)
        guard try PrivateFileIO.exists(paths.activeAuthMarkerURL) else { return nil }
        let data = try PrivateFileIO.read(paths.activeAuthMarkerURL, maximumSize: 4096)
        return try JSONDecoder().decode(ActiveAuthMarker.self, from: data).profileID
    }

    public func preserveCurrentCredentialIfManaged() throws {
        guard let current = try readActiveProfileID() else { return }
        try saveCurrentCredential(for: current)
    }

    public func saveCurrentCredential(for id: ProfileID) throws {
        _ = try paths.createProfileDirectories(for: id)
        try atomicOpaqueCopy(from: paths.sharedAuthURL, to: paths.profile(id).authSnapshot)
    }

    /// Explicitly adopts the current official login without replacing its file
    /// or stopping the application. The caller authorizes the slot and holds
    /// OperationLock; no credential contents are inspected.
    public func adoptCurrentCredential(as id: ProfileID) throws {
        try backupOriginalSharedCredentialIfNeeded()
        try saveCurrentCredential(for: id)
        try saveMarker(id)
    }

    /// Imports a newly enrolled credential from a private managed staging
    /// directory. It never changes shared auth. The caller holds OperationLock
    /// and must stop the official client before importing an active account.
    public func saveCredential(from source: URL, for id: ProfileID) throws {
        let candidate = source.standardizedFileURL
        guard candidate.path.hasPrefix(paths.applicationSupportRoot.path + "/") else {
            throw AccountAuthStoreError.unsafeCredentialFile
        }
        try paths.validatePrivatePath(candidate, includeSharedHome: false)
        _ = try paths.createProfileDirectories(for: id)
        try atomicOpaqueCopy(from: candidate, to: paths.profile(id).authSnapshot)
    }

    public func activate(_ id: ProfileID) throws {
        let source = paths.profile(id).authSnapshot
        guard isSafeCredentialFile(source) else {
            throw AccountAuthStoreError.missingCredential(id)
        }
        try paths.createSupportDirectories()
        try paths.createSharedCodexDirectory()
        try backupOriginalSharedCredentialIfNeeded()
        // A crash between replacing auth and writing the marker must never
        // associate the new credential with the previously active account.
        try clearActiveMarker()
        try atomicOpaqueCopy(from: source, to: paths.sharedAuthURL)
        try saveMarker(id)
    }

    public func removeMarkerIfActive(_ id: ProfileID) {
        guard activeProfileID() == id else { return }
        try? clearActiveMarker()
    }

    public func clearActiveMarker() throws {
        try paths.validatePrivatePath(paths.activeAuthMarkerURL)
        guard try PrivateFileIO.exists(paths.activeAuthMarkerURL) else { return }
        try fileManager.removeItem(at: paths.activeAuthMarkerURL)
    }

    public func backupOriginalSharedCredentialIfNeeded() throws {
        try paths.createSupportDirectories()
        try paths.validatePrivatePath(paths.originalSharedAuthBackupURL)
        try paths.validatePrivatePath(paths.sharedAuthURL)
        if try PrivateFileIO.exists(paths.originalSharedAuthBackupURL) {
            guard isSafeCredentialFile(paths.originalSharedAuthBackupURL) else {
                throw AccountAuthStoreError.unsafeCredentialFile
            }
            return
        }
        guard try PrivateFileIO.exists(paths.sharedAuthURL) else { return }
        try atomicOpaqueCopy(from: paths.sharedAuthURL, to: paths.originalSharedAuthBackupURL)
    }

    public func captureCurrentState() throws -> AccountAuthState {
        try paths.validatePrivatePath(paths.sharedAuthURL)
        let data = try PrivateFileIO.exists(paths.sharedAuthURL) ? PrivateFileIO.read(paths.sharedAuthURL) : nil
        return AccountAuthState(authData: data, profileID: try readActiveProfileID())
    }

    /// Call only while the official client is stopped and OperationLock is held.
    public func restoreCurrentState(_ state: AccountAuthState) throws {
        try paths.createSupportDirectories()
        try paths.createSharedCodexDirectory()
        try paths.validatePrivatePath(paths.sharedAuthURL)
        try clearActiveMarker()
        if let data = state.authData {
            try PrivateFileIO.atomicWrite(data, to: paths.sharedAuthURL)
        } else if try PrivateFileIO.exists(paths.sharedAuthURL) {
            try fileManager.removeItem(at: paths.sharedAuthURL)
        }
        if let id = state.profileID { try saveMarker(id) }
    }

    /// Explicit recovery only. For failed operations, restoreCurrentState is the
    /// exact checkpoint; the first-use original backup may be much older.
    public func restorePreviousCredential(_ id: ProfileID?) throws {
        if let id { try activate(id); return }
        try paths.createSharedCodexDirectory()
        guard isSafeCredentialFile(paths.originalSharedAuthBackupURL) else {
            throw AccountAuthStoreError.unsafeCredentialFile
        }
        try clearActiveMarker()
        try atomicOpaqueCopy(from: paths.originalSharedAuthBackupURL, to: paths.sharedAuthURL)
    }

    private func saveMarker(_ id: ProfileID) throws {
        let data = try JSONEncoder().encode(ActiveAuthMarker(profileID: id))
        try paths.validatePrivatePath(paths.activeAuthMarkerURL)
        try PrivateFileIO.atomicWrite(data, to: paths.activeAuthMarkerURL)
    }

    public func isSafeCredentialFile(_ url: URL) -> Bool {
        do { try paths.validatePrivatePath(url) } catch { return false }
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]) else { return false }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= 5_000_000 else { return false }
        return true
    }

    private func atomicOpaqueCopy(from source: URL, to destination: URL) throws {
        guard isSafeCredentialFile(source) else {
            throw AccountAuthStoreError.unsafeCredentialFile
        }
        try paths.validatePrivatePath(source)
        try paths.validatePrivatePath(destination)
        if destination.deletingLastPathComponent().path == paths.sharedCodexHome.path {
            try paths.createSharedCodexDirectory()
        } else {
            try paths.createPrivateDirectory(destination.deletingLastPathComponent())
        }
        let data = try PrivateFileIO.read(source)
        try PrivateFileIO.atomicWrite(data, to: destination)
    }
}
