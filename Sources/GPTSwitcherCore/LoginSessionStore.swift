import Foundation

public struct LoginSession: Codable, Equatable, Sendable {
    public let profileID: ProfileID
    public let previousProfileID: ProfileID?
    public let enrollmentID: UUID

    public init(profileID: ProfileID, previousProfileID: ProfileID?, enrollmentID: UUID = UUID()) {
        self.profileID = profileID
        self.previousProfileID = previousProfileID
        self.enrollmentID = enrollmentID
    }

    /// Each enrollment gets fresh directories. Existing saved account slots are
    /// only updated after the caller completes the login successfully.
    public func enrollmentPaths(in paths: GPTSwitcherPaths) throws -> ProfilePaths {
        let root = paths.applicationSupportRoot
            .appendingPathComponent("login-enrollment", isDirectory: true)
            .appendingPathComponent(enrollmentID.uuidString.lowercased(), isDirectory: true)
        let result = ProfilePaths(
            root: root,
            chatGPT: root.appendingPathComponent("chatgpt", isDirectory: true),
            codex: root.appendingPathComponent("codex", isDirectory: true)
        )
        try paths.createPrivateDirectory(result.chatGPT)
        try paths.createPrivateDirectory(result.codex)
        return result
    }
}

/// The caller holds OperationLock while modifying this state.
public struct LoginSessionStore: Sendable {
    public let paths: GPTSwitcherPaths

    public init(paths: GPTSwitcherPaths = .live) { self.paths = paths }

    public func load() throws -> LoginSession? {
        try paths.validatePrivatePath(paths.loginSessionURL)
        guard try PrivateFileIO.exists(paths.loginSessionURL) else { return nil }
        return try JSONDecoder().decode(LoginSession.self, from: PrivateFileIO.read(paths.loginSessionURL, maximumSize: 4096))
    }

    public func save(_ session: LoginSession) throws {
        try paths.createSupportDirectories()
        try paths.validatePrivatePath(paths.loginSessionURL)
        try PrivateFileIO.atomicWrite(JSONEncoder().encode(session), to: paths.loginSessionURL)
    }

    public func clear() throws {
        try paths.validatePrivatePath(paths.loginSessionURL)
        guard try PrivateFileIO.exists(paths.loginSessionURL) else { return }
        try FileManager.default.removeItem(at: paths.loginSessionURL)
    }
}
