# GPT Switcher

> 加固版 1.2.2：修复登录中误切、跨进程竞争和额度凭据覆盖，新增 OpenAI 签名验证、独立登录暂存、后台额度刷新（默认 5 分钟，可设 1/15 分钟或关闭）。安全边界以 [SECURITY.md](SECURITY.md) 为准，验证结果见 [HARDENING.md](HARDENING.md)。

当前账号可用 `gpt-switcher adopt-current account-a` 保存为 A，不退出 Codex；另一个账号可用 `gpt-switcher login account-b` 走官方浏览器登录和 MFA，保存后再手动切换。不要在正在执行重要任务时切换，切换会退出并重启 Codex。

GPT Switcher 是一个完全本地运行的 macOS 菜单栏工具，用于在多个本人拥有的 ChatGPT/Codex 账号之间切换模型登录身份，同时让所有账号共享同一套 Codex 本地项目、对话与历史任务。

> 1.2 的原则：账号可切换，工作区不切换；每个账号的真实额度独立显示。仅支持单个 ChatGPT 实例，不支持多账号同时运行。

1.2.1 已兼容新版 ChatGPT 安装包中 Codex 组件的路径变化。若额度刷新失败，菜单会显示错误原因，不会继续把旧额度当作最新数据。

## 主要功能

- 从 macOS 菜单栏一键切换 Account A、B、C、D 或更多账号。
- 始终使用官方默认本地工作区，切换后保留原项目、对话和历史任务。
- 显示每个账号实际返回的套餐、剩余额度、限制窗口和重置时间。
- 支持全局快捷键、开机启动、动态添加账号与本地 CLI。
- 不上传账号文件，不复制 Cookie、Keychain、项目数据库或对话数据库。

> [!IMPORTANT]
> GPT Switcher 是个人本地工具，不是 OpenAI 官方产品。它仅用于切换你本人拥有且有权使用的账号。

## 安装

要求：macOS 14 或更高版本，以及官方 `/Applications/Codex.app` 或兼容的 `/Applications/ChatGPT.app`。兼容性检查会验证 OpenAI 开发者签名及所需接口。

仓库中的安装包为 Apple Silicon（arm64）构建；Intel Mac 需在目标机从源码构建。临时签名未经过 Apple 公证。

1. 双击 [dist/GPT Switcher.dmg](dist/GPT%20Switcher.dmg)。
2. 将 `GPT Switcher.app` 拖到“应用程序”。旧版本可以直接覆盖。
3. 第一次运行若提示来自未识别开发者，请在 Finder 中右键应用并选择“打开”。

本项目使用本机临时签名，没有 Apple Developer ID 公证。也可以使用 [dist/GPT Switcher.app.zip](dist/GPT%20Switcher.app.zip)。

## 从 1.0 / 1.1 升级

1.2 会自动读取旧版已配置的 Account A、Account B 及其现有登录状态，不复制或导入旧版隔离目录中的项目数据库。

第一次点击 A 或 B 时，GPT Switcher 会：

1. 正常退出当前 ChatGPT。
2. 对系统默认登录文件做一次私有安全备份。
3. 原子切换到目标账号已保存的官方 `auth.json`。
4. 使用系统默认数据目录重新启动 ChatGPT。

此时左侧会回到升级前一直使用的本地项目、对话和任务。旧版 A/B 隔离目录仍保留，不会自动删除。

## 共享工作区

日常启动不再设置账号独立的 `CODEX_HOME` 或 Chromium 用户数据目录，而是始终显式使用官方默认位置：

```text
~/.codex
~/Library/Application Support/Codex
```

因此：

- 用 Account A 创建的本地项目和任务，切换到 B、C、D 后仍在同一位置。
- 切换账号后可以继续当前任务，不需要复制数据库。
- 从 Dock、Finder 或“应用程序”直接重新打开 ChatGPT，也会看到同一套本地工作区。
- ChatGPT 云端内容仍受当前账号本身的权限控制；GPT Switcher 不会跨账号复制云端数据。

OpenAI 对 Codex 项目与聊天的说明见[官方文档](https://learn.chatgpt.com/zh-Hans/docs/projects)。

## 账号登录与切换

现有 A/B 账号可直接从菜单栏切换：

- Account A：默认 `⌥⌘1`
- Account B：默认 `⌥⌘2`

切换时会先请求 ChatGPT 正常退出，保存当前账号可能刷新的登录状态，再切换目标账号并重新启动。若退出超时，工具会停止并要求显式确认强制退出。

### 添加 C、D 或更多账号

1. 从菜单栏或“账号管理与设置”点击“添加账号”。
2. GPT Switcher 打开一个仅用于首次登录的官方 ChatGPT 窗口。
3. 手动完成目标账号登录。
4. 回到菜单栏点击“完成登录”。
5. 工具会立即返回共享工作区；新账号默认依次分配 `⌥⌘3`、`⌥⌘4` 等快捷键。

账号数量不再固定为两个。显示名称和快捷键都可以修改。

## 账号额度与重置时间

菜单会为每个已登录账号读取并显示：

- 后台实际返回的套餐类型，例如 Plus、Pro 或 Business。
- 每个实际存在的限制窗口，例如 5 小时、1 周或其他窗口。
- 每个窗口的剩余百分比。
- 按 Mac 当前时区显示的准确重置日期与时间。

工具不会按套餐名称猜测窗口。某个 Pro 账号如果只返回周窗口，界面就只显示周窗口；如果返回多个独立额度桶，也会逐项显示。后台默认每 5 分钟刷新，设置可选关闭、1、5 或 15 分钟；唤醒时刷新，也可点击“刷新账号额度”。登录或切换占用期间会延后查询。

查询使用当前 ChatGPT 安装包自带的 Codex App Server `account/rateLimits/read` 只读接口。每个账号在私有临时目录中查询，不需要切换当前 Codex，也不读取对话。接口返回的后台账号 ID 不会保存或显示。

## 数据与安全

```text
~/Library/Application Support/GPT Switcher/
├── config.json                         # 名称、快捷键、当前账号等非敏感配置
├── active-auth-profile.json            # 当前账号 ID，不含凭据
├── migration-backup/original-auth.json # 升级时的一次性原登录文件备份
└── profiles/
    ├── account-a/codex/auth.json        # 官方应用生成的 A 登录快照
    ├── account-b/codex/auth.json        # 官方应用生成的 B 登录快照
    └── account-c/codex/auth.json        # 后续账号

~/Library/Logs/GPT Switcher/YYYY-MM-DD.log
```

为实现“共享工作区、只换账号”，1.2 必须在这些私有目录与官方 `~/.codex/auth.json` 之间复制完整的官方登录文件。实现只做不透明的文件级原子复制：切换时不解析、不显示、不记录其中的 Token（当前账号额度查询会在内存读取 access token 和 account ID，通过标准输入交给验签后的官方组件，不传 refresh token），也不接触密码、Cookie、Keychain 或任何项目/对话数据库。目录权限为 `0700`，文件权限为 `0600`。

删除账号只删除 GPT Switcher 管理的账号快照和旧隔离目录，不删除共享工作区或云端账号。详细边界见 [SECURITY.md](SECURITY.md)。

## CLI

执行 `bash scripts/build_release.sh` 后，CLI 构建产物位于 `dist/gpt-switcher`：

```bash
./dist/gpt-switcher status
./dist/gpt-switcher diagnose
./dist/gpt-switcher usage
./dist/gpt-switcher usage account-a
./dist/gpt-switcher adopt-current account-a
./dist/gpt-switcher login account-b
./dist/gpt-switcher login account-c
./dist/gpt-switcher login account-d
./dist/gpt-switcher verify-accounts
./dist/gpt-switcher switch account-a
./dist/gpt-switcher switch account-c
```

`adopt-current` 只用于保存当前登录到空槽位。`login` 在官方浏览器中完成新账号登录及 MFA，不关闭正在运行的 Codex，且拒绝覆盖已有槽位。首次登录与新增账号也可使用菜单栏应用；菜单栏的首次登录流程会重启官方客户端。`verify-accounts` 仅比较本地账号 ID 是否重复，不输出 ID 或 Token，不等于服务端身份验证。

在另一台 Mac 安装相同代码不会自动携带账号。登录快照不在仓库内；另一台机器须独立登录，或单独处理经过加密传输的登录状态迁移。不要通过 GitHub、邮件或聊天发送 `auth.json`，也不要把整个 `~/.codex` 当作账号配置包复制。

两台 Mac 都要长期使用时，请在每台机器各登录一次，以获得独立会话。复制同一份登录缓存并在两端运行（包括后台额度查询）可能引起自动续期冲突，需要重新登录；本工具不提供跨设备凭据同步。详见 [SECURITY.md](SECURITY.md)。

## 卸载

仅卸载应用：退出 GPT Switcher，将“应用程序”中的 `GPT Switcher.app` 移到废纸篓。账号快照与共享工作区都会保留。

若要删除 GPT Switcher 自身数据，请先退出 GPT Switcher 与 ChatGPT，再把以下目录移到废纸篓：

```text
~/Library/Application Support/GPT Switcher
~/Library/Logs/GPT Switcher
```

不要删除官方共享工作区 `~/.codex` 或 `~/Library/Application Support/Codex`。

## 构建与验证

```bash
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
bash scripts/build_release.sh
```

无第三方运行时依赖。详细验证见 [TECHNICAL_VALIDATION.md](TECHNICAL_VALIDATION.md)。

## 项目结构

```text
Sources/GPTSwitcherApp/   # SwiftUI 菜单栏应用与设置
Sources/GPTSwitcherCore/  # 账号切换、共享工作区、额度查询
Sources/GPTSwitcherCLI/   # 命令行工具
Tests/                    # Swift Testing 自动化测试
scripts/                  # Release 打包与图标生成
Resources/                # App Info.plist
dist/                     # 已构建的 DMG/ZIP 安装包
```

## 当前限制

- 账号切换及额度查询依赖当前 ChatGPT/Codex 版本的官方 `auth.json` 与 App Server 协议，应用升级后应重新运行兼容性测试。
- 如果在 ChatGPT 内部手动退出并登录成另一个账号，GPT Switcher 无法读取页面来自动识别身份；请使用对应账号的“重新登录 → 完成登录”更新快照。
- 1.2 不支持同时运行多个账号。
