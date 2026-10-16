# DeepSeek Harness Bar (macOS) 🐳

<p align="center">
  <img src="Resources/icon.png" width="128" height="128" alt="DeepSeek Harness Bar Icon">
</p>

<p align="center">
  <b>A native macOS menu bar companion for DeepSeek Harness.</b><br>
  DeepSeek Harness 的 macOS 菜单栏工具：查看服务状态、启动或停止服务、打开 Web 界面。
</p>

---

## 为什么用它？ / Why DeepSeek Harness Bar?

平时用 `dsh web` 启动 DeepSeek Harness，查看服务是否还在运行、结束后台进程、换端口后重启，通常都要回到终端，用到 `lsof`、`kill` 等命令。DSH Bar 把这些操作放进菜单栏。

- **原生 Swift / AppKit 界面**：自动更新使用 Sparkle。发布包支持 Apple Silicon 和 Intel，不占用 Dock 位置。
- **查看状态**：菜单栏状态灯区分检查中、启动中、运行中、端口冲突与错误，还会显示 PID、运行时长和 DSH 版本。
- **修改设置**：可以设置端口、打开 Web 的全局热键和开机自启动。启动或重启应用、服务时，都不会自动打开网页。
- **只停自己的服务**：停止时只结束本应用启动的 `dsh` 进程，不会结束占用同一端口的浏览器或其他程序。

---

## 前置条件 / Prerequisites

本应用需要官方 `dsh` 命令行。

DSH Bar 通过 `which dsh` 检测安装路径并读取版本。找不到时，设置界面会显示 **Install…**，复制官方 npm 安装命令并打开终端，供你安装：

```bash
npm install -g @deepseek-ai/dsh
```

- **操作系统**：macOS 13.0 (Ventura) 及以上，支持 Apple Silicon 与 Intel。

---

## 提示“应用已损坏，无法打开”？ / Troubleshooting

发布包是否经过 Apple 签名和公证，取决于构建时的配置，具体看对应 Release 的说明。对于明确标注未公证的版本，下载后可能看到 Gatekeeper 提示：

> **“DeepSeek Harness Bar 已损坏，无法打开。你应该将它移到废纸篓”** 或 **“无法打开，因为无法验证开发者”**

这类未公证版本可以在终端里解除隔离属性：

```bash
xattr -cr "/Applications/DeepSeek Harness Bar.app"
```

解除隔离后即可正常启动。只有提示权限不足时，才在命令前加上 `sudo`。

> **从旧版升级时，先删除旧应用**：0.1.0 起，应用改名为 **DeepSeek Harness Bar**。旧版 `DSH Bar.app` 与新版共用同一个 bundle identifier；两者同时存在时，macOS 可能打开错的那个。

> 也可以打开「系统设置」→「隐私与安全性」，找到“已阻止使用 DeepSeek Harness Bar”，点击 **“仍要打开”**。

---

## 核心特性 / Features

- **菜单栏常驻**：使用系统原生 `🐳` Emoji，自适应深浅色，不占用 Dock 栏位。
- **服务状态**：菜单栏和设置页显示检查中、启动中、运行中、停止中、重启中、端口冲突与错误，以及 PID、运行时长和已安装的 DSH 版本。
- **自定义端口**：默认 3080。运行中修改端口会保留旧监听；重启前先检查新端口，避免误停或遗留服务。
- **后台启停和重启**：始终使用 `dsh web --no-open` 在后台启动，Start 和 Restart 不会打开浏览器。
- **只管理自己的服务**：启动时把 `{PID, 端口, 启动时间}` 写入 `~/.dsh/dsh-bar-service.json`。停止前核对进程启动时间，PID 被复用时拒绝操作。
- **停止或接管终端启动的服务**：服务由你在终端中用 `dsh web` 启动时，面板会显示 **Stop External…** 和 **Adopt & Restart**。点击后，弹窗会列出 PID、端口和完整命令行，确认后才结束进程。`Adopt & Restart` 会改由 DSH Bar 接管，之后可直接使用 Stop/Restart。非 Harness 监听者、多进程监听和非当前用户的进程都会被拒绝。
- **重启前检查**：先确认目标端口空闲、DSH CLI 仍然存在。有一项不通过，就保持旧服务原样运行并说明原因。此前，卸载 `dsh` 或切换 Node 版本导致 shim 失效时，可能会先停止旧服务，再启动失败。
- **退出时保留服务**：`⌘Q` 退出菜单栏应用，保留后台服务，下次打开时自动重新接管。要同时停止服务，使用 `⌘⌥Q` **Quit & Stop Service…**。外部启动的服务在任何退出路径下都不会被停止。
- **异常退出通知和自动恢复**：DSH Bar 启动的服务意外退出时，会发系统通知并尝试重启。10 分钟内最多 3 次，退避间隔为 1s/4s/16s；超过后停止尝试并告知，不会无限重启。手动停止的服务不会自动恢复；外部启动的服务只报告、不重启。
- **通知不可用时的提示**：ad-hoc 签名的应用每次重建都可能丢失通知授权。面板会用橙色显示通知状态和原因，并提供 **Fix…**。崩溃和恢复提示也会保留在面板和菜单栏中，不依赖通知送达。
- **界面语言**：偏好设置中可选择 **自动 / English / 简体中文**。切换立即生效，无需重启；面板、菜单栏和日志窗口会一起切换。
- **手动打开 Web**：只有点击 Open Web 或使用它的全局热键时，才会打开浏览器。使用本次启动捕获的认证 URL，token 只保留在内存中。
- **实时日志**：在应用中查看 `~/.dsh/logs/dsh-web.log`，支持暂停、搜索、清空当前视图和在 Finder 中定位。只显示完整换行、已隐藏 URL 查询凭证的日志；行首边界不明的首行、未完成行和超长行会保守隐藏。
- **日志轮转**：Bar 新启动的服务使用独立后台写入进程轮转日志。当前文件最多 **10 MiB**，另保留 `.1`、`.2` 两份历史，合计最多 **30 MiB**。退出 Bar、保留 Web 后仍会轮转；停止 Web 后，写入进程会排空日志再退出。升级前已运行的旧服务，需要停止并由新版重新启动，才能启用限额。不要直接删除或截断仍有旧进程写入的大日志。
- **DSH 检测**：通过 `which dsh` 检测路径和版本，未安装时提供 npm 安装引导。
- **偏好设置（`⌘,`）**：
  - **端口**：修改端口或恢复默认值。服务启动、停止、重启期间会锁定，避免端口错配。
  - **全局热键**：录制自定义热键，录完立即生效。
  - **开机自启动**（Launch at login）。
  - 查看 DSH CLI 路径和版本，未安装时提供安装引导。
  - **安装通道**：从 `latest` / `next` / `alpha` 等 npm dist-tag 中选择要安装的 dsh 版本，已安装的通道会标注 `(installed)`。确认后执行 `npm install -g @deepseek-ai/dsh@<tag>`。服务运行中也可安装，会提示“重启后生效”，但不会自动重启。安装失败时显示 npm 原始报错，不回滚。选择的通道只会被记住，不会自动安装。
  - 复制本地 Web 地址、打开实时日志。
  - 启动或重启 DSH Bar、启动或重启服务时，都不会自动打开 Web 界面。

---

## 快捷键 / Shortcuts

### 全局热键（任何软件处于前台时都有效）
| 快捷键 | 动作 | 说明 |
| :--- | :--- | :--- |
| **`⇧ + ⌘ + D`**<br>*(可在设置中修改)* | 打开 DSH Web | 服务未启动则先在后台启动，再打开浏览器；已在运行则直接打开 |

### 菜单栏 / 面板内快捷键
| 快捷键 | 动作 |
| :--- | :--- |
| **`⌘ + ,`** | 打开偏好设置面板 |
| **`⌘ + O`** | 在默认浏览器中打开 Web 控制台 |
| **`⌘ + S`** | 启动 / 停止后台服务 |
| **`⌘ + R`** | 重启服务 |
| **`⇧ + ⌘ + C`** | 复制 Web 地址 (`http://127.0.0.1:<port>`) |
| **`⌘ + L`** | 查看实时运行日志 |
| **`Esc` / `⌘ + W`** | 关闭面板（应用仍在菜单栏常驻） |
| **`⌘ + Q`** | 退出 DSH Bar（保留后台服务） |
| **`⌘ + ⌥ + Q`** | 退出并停止 DSH Bar 启动的服务 |

界面语言在 **偏好设置 → 语言** 中切换，立即生效。

---

## 安装与构建 / Installation & Build

### 方式一：下载 GitHub Release（推荐）

每个 `v*` 标签都会触发 GitHub Actions，构建支持 Apple Silicon 和 Intel 的通用应用。Release 中包含以下文件；`0.x` 版本标记为 Pre-release：

- `DSH-Bar-<version>-universal.zip`
- 对应的 `.sha256` 校验文件

发布包的签名和公证取决于仓库配置：

| 配置 | 结果 |
| :--- | :--- |
| 已配置 `APPLE_CERT_P12_BASE64`（内含 Developer ID 证书）、`APPLE_CERT_PASSWORD`、`APPLE_KEYCHAIN_PASSWORD`、`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD` | 完成 Developer ID 签名、硬化运行时、公证和 stapler 后发布，Gatekeeper 可直接打开 |
| 已配置 `APPLE_CERT_P12_BASE64`（内含自签名证书 `DSH Bar Self-Signing`）、`APPLE_CERT_PASSWORD`、`APPLE_KEYCHAIN_PASSWORD`，且未配置公证凭据 | 用自签名证书发布，应用身份跨版本稳定，系统授权不因更新失效；不做公证，Release 说明会提示需要手动执行 `xattr -cr` |
| 未配置任何证书 Secrets | 仅 ad-hoc 签名，应用身份每次构建都会变化，系统授权在每次更新后失效；Release 说明会提示需要手动执行 `xattr -cr` |

#### 自动更新（Sparkle）

应用使用 Sparkle 2，每天在后台检查一次更新（`SUScheduledCheckInterval` = 86400）。发现新版后，由用户确认安装，不静默更新。也可以从菜单栏 **Check for Updates…** 或偏好设置 → **软件更新** 手动检查。

发布自动更新还需要以下配置：

| 配置 | 用途 |
| :--- | :--- |
| Secret `SPARKLE_PRIVATE_ED_KEY` | EdDSA 私钥，用于生成带下载包签名的 appcast.xml。公钥在 `Info.plist` 的 `SUPublicEDKey` 中；缺少私钥时，release 工作流会在生成 appcast 这一步失败 |

`SUFeedURL` 指向 [最新正式版的 appcast](https://github.com/donald-trump86/dsh-bar-macos/releases/latest/download/appcast.xml)，通过 GitHub 的 HTTPS 重定向读取 Release 附件，不经过 Pages 自定义域名或 Cloudflare 人机验证。每个正式版 Release 都必须带有 `appcast.xml`；下载包的 URL 使用固定版本标签。

release 工作流完成最终打包后，使用 `Vendor/Sparkle/bin/generate_appcast` 生成 appcast，写入下载包的 EdDSA 签名。配置了 Developer ID 和公证凭据时，会先完成公证和 staple；未配置 Developer ID 时，安装包为自签名或 ad-hoc 签名。**EdDSA 校验不等于 Apple 公证。**

**1.0.0 用户需要手动下载安装 1.0.1 一次。** 1.0.0 的 Pages 更新源受到自定义域名重定向影响，1.0.1 起改用上述 Releases 更新源。

发布前可以在本地编译。下面第二条命令只做 Developer ID 签名，不包含公证和 staple：

```bash
VERSION=1.0.2 ./build.sh          # 通用二进制；未设置 SIGNING_IDENTITY 时自动检测自签名身份，否则 ad-hoc
VERSION=1.0.2 SIGNING_IDENTITY="Developer ID Application: …" ./build.sh
```

#### 稳定权限与自签名证书 / Stable permissions via self-signed certificate

未配置证书时，所有构建都是 ad-hoc 签名，macOS 会把每次更新后的应用当作新身份，辅助功能、自动化、屏幕录制、通知等系统授权随之失效。仓库维护者可以做一次性配置，用一个长期自签名证书固定应用身份，让授权在更新后保留。

维护者设置（只需一次）：

```bash
./Packaging/create-signing-identity.sh --password '<p12 密码>'
base64 -i dsh-bar-self-signing.p12
```

脚本会在登录钥匙串中创建 `DSH Bar Self-Signing` 证书（RSA 2048，有效期 3650 天），并导出 `dsh-bar-self-signing.p12`（已被 `.gitignore` 排除，请勿提交或分享）。将 base64 输出与两个密码配置为 GitHub Secrets：

| Secret | 内容 |
| :--- | :--- |
| `APPLE_CERT_P12_BASE64` | 上面 base64 命令的输出 |
| `APPLE_CERT_PASSWORD` | p12 的密码 |
| `APPLE_KEYCHAIN_PASSWORD` | CI 导入证书时创建的临时钥匙串密码 |

从下一个 `v*` 标签开始，release 工作流会导入证书并优先使用 Developer ID；没有 Developer ID 时改用自签名身份发布。自签名发布不做公证（notarization），Release 说明会保留 `xattr -cr` 提示。本地 `./build.sh` 在未设置 `SIGNING_IDENTITY` 时也会自动检测登录钥匙串中的 `DSH Bar Self-Signing`。

**从旧 ad-hoc 版本升级到第一个自签名版本时，macOS 会因应用身份变化再询问一次授权；之后更新不再重复询问。**证书有效期为 10 年，到期重新生成后同样只会再经历一次授权询问。

没有该证书的贡献者不受影响：未配置上述 Secrets 时 CI 回退到 ad-hoc 签名，本地开发流程不变。

### 方式二：从源码编译并安装

```bash
git clone https://github.com/donald-trump86/dsh-bar-macos.git
cd dsh-bar-macos
make install
open -a "DeepSeek Harness Bar"
```

### 方式三：只编译，不安装

```bash
make
open "build/DeepSeek Harness Bar.app"
```

---

## 提交前检查 / Before You Commit

```bash
make check
```

这会检查中英文案的 key 是否一致、`build.sh` 与 `Info.plist` 中的应用名是否一致，以及 README 中的路径是否有效。CI 运行同一份检查脚本。

---

## 项目结构 / Project Structure

```text
dsh-bar-macos/
├── Sources/
│   ├── main.swift              # 程序入口
│   ├── AppDelegate.swift       # 菜单栏图标（🐳 + 状态点）、菜单与状态控制
│   ├── ServiceManager.swift    # 详细状态、身份检测、安静启停、PID 与 DSH 检测
│   ├── RotatingLogWriter.swift # 独立后台日志写入、10 MiB 限额与两份历史
│   ├── HotKeyManager.swift     # “打开 Web”可配置全局热键
│   ├── SettingsManager.swift   # 端口、开机启动 (SMAppService)、热键持久化
│   ├── UpdateManager.swift     # Sparkle 自动更新（检查更新、自动检查开关）
│   ├── DashboardWindow.swift   # 毛玻璃偏好设置面板
│   ├── LogWindow.swift         # 内置实时日志窗口
│   ├── LogTextBuffer.swift      # 跨读取完整行脱敏、残片隐藏与字节限额
│   ├── DshInstallAssistant.swift # DSH/npm 安装引导
│   ├── DshVersionController.swift # npm dist-tag 探测与按 tag 安装 dsh
│   ├── ExternalServicePrompt.swift # 结束外部启动服务的确认弹窗
│   ├── ServiceNotifier.swift   # 系统通知与不可用时的降级
│   └── Localization.swift      # 中英双语文案表（枚举键 + 缺失回退英文）
├── Resources/
│   ├── AppIcon.icns            # 应用图标 (1024x1024)
│   └── icon.png                # README 与面板使用的图标
├── Packaging/
│   └── DSHBar.entitlements     # Developer ID 签名使用的 hardened runtime 配置
├── Vendor/
│   ├── Sparkle.framework       # 预编译 Sparkle 2.10.0（build.sh 内翻新签名嵌套组件）
│   └── Sparkle/bin/            # generate_appcast / sign_update / generate_keys
├── Info.plist                  # Bundle 配置（LSUIElement，仅菜单栏）
├── .github/workflows/release.yml # 标签触发构建、公证、appcast 签署与 Pages 部署
├── build.sh                    # macOS 13+ 通用二进制编译、签名与打包脚本
├── Makefile                    # make build / install / run / clean
├── LICENSE                     # MIT
└── README.md                   # 项目说明
```

---

## 开源许可证 / License

本项目使用 [MIT License](LICENSE) 开源。
欢迎提 Issue 或 PR。
