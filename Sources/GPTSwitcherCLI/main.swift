import Foundation
import GPTSwitcherCore

@main
enum GPTSwitcherCLI {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let force = arguments.contains("--force")
        let command = arguments.first(where: { !$0.hasPrefix("--") }) ?? "help"
        let paths = GPTSwitcherPaths.live
        let store = ConfigStore(paths: paths)
        let logger = SafeLogger(paths: paths)
        let controller = ChatGPTController(paths: paths, logger: logger)

        do {
            if command == "verify-accounts" {
                let result = try AccountIdentityCheck.checkConfiguredAccounts(paths: paths)
                printIdentityCheck(result)
                if !result.allDistinct { Foundation.exit(2) }
                return
            }
            var config = try store.load()
            switch command {
            case "account-a":
                try await switchTo(.accountA, config: &config, store: store, controller: controller, force: force)
            case "account-b":
                try await switchTo(.accountB, config: &config, store: store, controller: controller, force: force)
            case "switch":
                guard let rawID = arguments.drop(while: { $0 != "switch" }).dropFirst().first,
                      let id = ProfileID(rawValue: rawID),
                      config.accounts.contains(where: { $0.id == id }) else {
                    throw CLIError.usage("用法：gpt-switcher switch <账号 ID> [--force]")
                }
                try await switchTo(id, config: &config, store: store, controller: controller, force: force)
            case "adopt-current":
                let raw = arguments.dropFirst().first ?? "account-a"
                guard let id = ProfileID(rawValue: raw) else { throw CLIError.usage("无效账号 ID") }
                let operation = try OperationLock.acquire(paths: paths)
                defer { operation.release() }
                guard try LoginSessionStore(paths: paths).load() == nil else {
                    throw ChatGPTControllerError.loginInProgress
                }
                config = try store.load()
                guard !config.account(id).isConfigured, !controller.authStore.hasCredential(for: id) else {
                    throw CLIError.usage("目标账号槽位已有登录；为避免覆盖，已停止导入。")
                }
                let installation = try controller.installation(preferredPath: config.preferredChatGPTPath)
                try ChatGPTInspector().verifyTrustedInstallation(installation)
                try controller.authStore.adoptCurrentCredential(as: id)
                var account = config.account(id)
                account.isConfigured = true
                config.updateAccount(account)
                config.activeProfileID = id
                try store.save(config)
                print("已保存当前账号为 \(account.displayName)；没有退出 Codex 或更改当前登录。")
            case "login":
                guard let raw = arguments.dropFirst().first, let id = ProfileID(rawValue: raw) else {
                    throw CLIError.usage("用法：gpt-switcher login <账号 ID>")
                }
                try await controller.enrollUsingBrowser(for: id, preferredPath: config.preferredChatGPTPath)
                print("已保存 \(id.defaultDisplayName)；当前 Codex 仍保持原账号，可稍后从菜单切换。")
            case "cancel-login":
                try await controller.cancelLoginSetup(preferredPath: config.preferredChatGPTPath, force: force)
                print("已取消登录并恢复共享工作区。")
            case "init":
                let operation = try OperationLock.acquire(paths: paths)
                defer { operation.release() }
                config = try store.load()
                try paths.createSupportDirectories()
                for account in config.accounts { _ = try paths.createProfileDirectories(for: account.id) }
                try store.save(config)
                print("已创建 GPT Switcher 配置与账号登录目录。")
            case "list", "status":
                printStatus(config: config, controller: controller, paths: paths)
            case "diagnose":
                try diagnose(config: config, controller: controller)
            case "usage":
                let requestedID = arguments.drop(while: { $0 != "usage" }).dropFirst().first
                try await printUsage(
                    config: config,
                    requestedID: requestedID,
                    controller: controller,
                    paths: paths
                )
            case "help", "--help", "-h":
                printHelp()
            default:
                throw CLIError.usage("未知命令：\(command)")
            }
        } catch {
            fputs("错误：\(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    @MainActor
    private static func switchTo(
        _ id: ProfileID,
        config: inout SwitcherConfig,
        store: ConfigStore,
        controller: ChatGPTController,
        force: Bool
    ) async throws {
        let profile = config.account(id)
        guard profile.isConfigured else {
            throw CLIError.usage("账号尚未完成登录，请先在 GPT Switcher 菜单栏应用中配置。")
        }
        print("正在切换到 \(profile.displayName)…")
        let result = try await controller.switchProfile(
            to: profile,
            currentProfileID: config.activeProfileID,
            preferredPath: config.preferredChatGPTPath,
            launchAfterSwitch: config.automaticallyLaunchChatGPT,
            force: force
        )
        config = try store.load()
        config.activeProfileID = controller.authStore.activeProfileID()
        switch result {
        case .alreadyActive: print("\(profile.displayName) 已在运行。")
        case .launched: print("已切换到 \(profile.displayName)；本地工作区保持共享。")
        case .stopped: print("已选择 \(profile.displayName)，但设置为不自动启动 ChatGPT。")
        }
    }

    @MainActor
    private static func printStatus(
        config: SwitcherConfig,
        controller: ChatGPTController,
        paths: GPTSwitcherPaths
    ) {
        print("ChatGPT：\(controller.isRunning ? "运行中" : "未运行")")
        print("当前 Profile：\(controller.authStore.activeProfileID()?.rawValue ?? "未设置")")
        if let pending = try? LoginSessionStore(paths: paths).load() {
            print("尚未完成的登录：\(pending.profileID.rawValue)")
        }
        print("共享 Codex 工作区：\(paths.sharedCodexHome.path)")
        for profile in config.accounts {
            print("- \(profile.id.rawValue): \(profile.displayName) [\(profile.isConfigured ? "已配置" : "未配置")]")
            print("  \(paths.profile(profile.id).root.path)")
        }
    }

    @MainActor
    private static func diagnose(
        config: SwitcherConfig,
        controller: ChatGPTController
    ) throws {
        let app = try controller.installation(preferredPath: config.preferredChatGPTPath)
        print("路径：\(app.appURL.path)")
        print("Bundle ID：\(app.bundleIdentifier)")
        print("版本：\(app.version) (\(app.build))")
        print("Chromium：\(app.chromiumVersion ?? "未知")")
        print("CODEX_ELECTRON_USER_DATA_PATH：\(app.supportsExplicitUserDataPath ? "支持" : "未检测到")")
        print("CODEX_HOME：\(app.supportsCodexHome ? "支持" : "未检测到")")
        print("结论：\(app.isSupported ? "可使用独立登录快照并共享本地工作区" : "不兼容，切换将被阻止")")
    }

    @MainActor
    private static func printUsage(
        config: SwitcherConfig,
        requestedID: String?,
        controller: ChatGPTController,
        paths: GPTSwitcherPaths
    ) async throws {
        let accounts: [AccountProfile]
        if let requestedID {
            guard let id = ProfileID(rawValue: requestedID),
                  let account = config.accounts.first(where: { $0.id == id }) else {
                throw CLIError.usage("没有找到账号：\(requestedID)")
            }
            accounts = [account]
        } else {
            accounts = config.accounts.filter(\.isConfigured)
        }
        let installation = try controller.installation(preferredPath: config.preferredChatGPTPath)
        let service = AccountUsageService()
        for account in accounts {
            let usage = try await service.fetch(
                profilePaths: paths.profile(account.id),
                installation: installation,
                paths: paths
            )
            print("\(account.displayName) [\(usage.planDisplayName ?? "套餐未知")]")
            for bucket in usage.buckets {
                for window in bucket.windows {
                    let duration = window.windowDurationMinutes.map(String.init) ?? "未知"
                    let reset = window.resetsAt.map { Self.usageDateFormatter.string(from: $0) } ?? "未知"
                    print("  \(bucket.name ?? bucket.id): \(duration) 分钟窗口，剩余 \(window.remainingPercent)%，\(reset) 重置")
                }
            }
        }
    }

    private static func printIdentityCheck(_ result: AccountIdentityCheckResult) {
        func names(_ slots: [ProfileID]) -> String {
            // Use controlled slot labels, not user-supplied display names that could contain emails.
            slots.map { "\($0.defaultDisplayName) [\($0.rawValue)]" }.joined(separator: "、")
        }
        for group in result.duplicateGroups { print("重复：\(names(group))") }
        if !result.unverifiableSlots.isEmpty {
            print("不可验证：\(names(result.unverifiableSlots))")
        }
        if result.allDistinct {
            print("已配置的 \(result.configuredCount) 个槽位均可验证，本地 account_id 全部不同。")
        } else if result.configuredCount < 2 {
            print("已配置槽位少于 2 个，无法完成多账号差异检查。")
        } else {
            print("检查未通过：存在重复或无法验证的槽位。")
        }
        print("此检查只比较本地 account_id，不验证 Pro 套餐或账号所有权。")
    }

    private static let usageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func printHelp() {
        print("""
        GPT Switcher CLI

        用法：
          gpt-switcher account-a [--force]       切换到 Account A
          gpt-switcher account-b [--force]       切换到 Account B
          gpt-switcher switch <账号 ID>          切换到指定账号
          gpt-switcher adopt-current <账号 ID>   保存当前登录（不退出 Codex）
          gpt-switcher login <账号 ID>           在官方浏览器中登录另一个账号（不退出 Codex）
          gpt-switcher cancel-login              取消待完成的桌面登录
          gpt-switcher init                      创建账号登录目录
          gpt-switcher status                    查看状态
          gpt-switcher diagnose                  检查 ChatGPT 兼容性
          gpt-switcher usage [账号 ID]            查询真实剩余额度与重置时间
          gpt-switcher verify-accounts           只读检查已配置槽位是否重复（无法确认时退出码 2）

        --force  仅在 ChatGPT 无法正常退出时强制退出。共享项目与历史不会被替换。
        """)
    }
}

private enum CLIError: LocalizedError {
    case usage(String)
    var errorDescription: String? {
        switch self { case .usage(let message): return message }
    }
}
