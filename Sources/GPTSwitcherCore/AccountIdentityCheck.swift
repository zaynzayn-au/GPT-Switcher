import Foundation

/// Contains slot names only. Raw account identifiers and credential fields never leave the check.
public struct AccountIdentityCheckResult: Equatable, Sendable {
    public let verifiedSlots: [ProfileID]
    public let duplicateGroups: [[ProfileID]]
    public let unverifiableSlots: [ProfileID]

    public var configuredCount: Int { verifiedSlots.count + unverifiableSlots.count }
    public var allDistinct: Bool {
        verifiedSlots.count >= 2 && duplicateGroups.isEmpty && unverifiableSlots.isEmpty
    }
}

public enum AccountIdentityCheckError: LocalizedError {
    case configurationUnavailable
    case accountStateUnavailable
    case loginInProgress

    public var errorDescription: String? {
        switch self {
        case .configurationUnavailable: return "无法安全读取账号配置，未完成账号差异检查。"
        case .accountStateUnavailable: return "无法确认当前账号状态，未完成账号差异检查。"
        case .loginInProgress: return "账号登录尚未完成，请完成或取消登录后再检查。"
        }
    }
}

/// A read-only comparison of local tokens.account_id values. This does not verify
/// account ownership, login validity, or Pro status; official usage queries verify the plan separately.
public enum AccountIdentityCheck {
    public static func checkConfiguredAccounts(paths: GPTSwitcherPaths = .live) throws -> AccountIdentityCheckResult {
        let operation = try OperationLock.acquire(paths: paths)
        defer { operation.release() }
        let config: SwitcherConfig
        do {
            try paths.validatePrivatePath(paths.configURL)
            if try PrivateFileIO.exists(paths.configURL) {
                config = try JSONDecoder().decode(SwitcherConfig.self, from: readPrivateFile(paths.configURL, maximumSize: 1_000_000))
                guard (1...SwitcherConfig.currentSchemaVersion).contains(config.schemaVersion) else {
                    throw AccountIdentityCheckError.configurationUnavailable
                }
            } else {
                config = SwitcherConfig()
            }
        } catch {
            // Decoder errors may carry input fragments. Never expose them in diagnostics.
            throw AccountIdentityCheckError.configurationUnavailable
        }
        let active: ProfileID?
        do {
            if try LoginSessionStore(paths: paths).load() != nil {
                throw AccountIdentityCheckError.loginInProgress
            }
            active = try AccountAuthStore(paths: paths).readActiveProfileID()
        } catch AccountIdentityCheckError.loginInProgress {
            throw AccountIdentityCheckError.loginInProgress
        } catch {
            throw AccountIdentityCheckError.accountStateUnavailable
        }

        var seenSlots = Set<ProfileID>()
        let slots = config.accounts.filter { $0.isConfigured && seenSlots.insert($0.id).inserted }.map(\.id)
        var verified: [ProfileID] = []
        var unverifiable: [ProfileID] = []
        var identityGroups: [String: [ProfileID]] = [:]
        for slot in slots {
            // An active slot's snapshot may be stale. A missing/invalid shared credential
            // must be reported as unverifiable, never replaced with that old snapshot.
            let authURL = slot == active ? paths.sharedAuthURL : paths.profile(slot).authSnapshot
            do {
                try paths.validatePrivatePath(authURL)
                let data = try readPrivateFile(authURL)
                let identity = try JSONDecoder().decode(IdentityFields.self, from: data).tokens.account_id
                guard !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      identity.utf8.count <= 1_024 else {
                    throw PrivateFileError.unsafeFile
                }
                identityGroups[identity, default: []].append(slot)
                verified.append(slot)
            } catch {
                unverifiable.append(slot)
            }
        }
        // Preserve configuration order without returning the identifiers used as dictionary keys.
        let duplicateGroups = verified.compactMap { slot in
            identityGroups.values.first { $0.count > 1 && $0.first == slot }
        }
        return AccountIdentityCheckResult(
            verifiedSlots: verified, duplicateGroups: duplicateGroups, unverifiableSlots: unverifiable
        )
    }

    private struct IdentityFields: Decodable {
        struct Tokens: Decodable { let account_id: String }
        let tokens: Tokens
    }

    private static func readPrivateFile(_ url: URL, maximumSize: Int = 5_000_000) throws -> Data {
        // PrivateFileIO also verifies owner/type/size and opens with O_NOFOLLOW.
        try requirePrivatePermissions(url)
        let data = try PrivateFileIO.read(url, maximumSize: maximumSize)
        try requirePrivatePermissions(url)
        return data
    }

    private static func requirePrivatePermissions(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o7777 == 0o600 else {
            throw PrivateFileError.unsafeFile
        }
    }
}
