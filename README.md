# DSH Bar (macOS) 🐳

<p align="center">
  <img src="Resources/icon.png" width="128" height="128" alt="DSH Bar Icon">
</p>

<p align="center">
  <b>A native macOS menu bar companion for DeepSeek Harness.</b><br>
  专为 DeepSeek Harness 打造的原生 macOS 菜单栏助手：查看运行状态、一键启停、直达 Web 界面。
</p>

---

## 💡 为什么用 DSH Bar？ / Why DSH Bar?

如果你平时用 `dsh web` 启动 DeepSeek Harness，那么“服务在不在跑”“怎么停掉后台进程”“换端口后怎么重启”这些事，通常都得回到终端敲 `lsof`、`kill`。DSH Bar 把这些操作放进菜单栏，随手一点即可。

- **纯原生 Swift**：无第三方依赖，二进制约 200 KB，不占用 Dock 位置。
- **状态一眼可见**：菜单栏 `🐳` 旁边的圆点，绿色 = 运行中，灰色 = 已停止。
- **可自定义**：端口、全局热键、开机自启动、启动时自动打开网页。
- **只停自己的服务**：停止时只结束由本应用启动的 `dsh` 进程，不会误杀占用同一端口的浏览器或其他程序。

---

## ⚡️ 前置条件 / Prerequisites

> **本应用是 DeepSeek Harness 的伴侣工具，使用前请确认系统里已经装好官方 `dsh` 命令行。**

```bash
# 验证 dsh 是否已安装
dsh --version

# 如未安装，可通过 npm 全局安装：
npm install -g @deepseek-ai/dsh
```

- **操作系统**：macOS 13.0 (Ventura) 及以上，支持 Apple Silicon 与 Intel。

---

## 🚨 常见问题：提示“应用已损坏，无法打开”？ / Troubleshooting

本项目没有使用 Apple Developer Program 的签名与公证证书，所以从 GitHub 下载后，macOS 的 Gatekeeper 可能提示：

> **“DSH Bar 已损坏，无法打开。你应该将它移到废纸篓”** 或 **“无法打开，因为无法验证开发者”**

**解决方法**：在终端里解除隔离属性。

```bash
sudo xattr -rd com.apple.quarantine "/Applications/DSH Bar.app"
```
*（输入密码时不会显示字符，直接回车即可）*

或者：

```bash
xattr -cr "/Applications/DSH Bar.app"
```

执行后即可正常启动。

> 💡 **图形界面方法**：打开「系统设置」→「隐私与安全性」，滑到底部会看到“已阻止使用 DSH Bar”，点击 **“仍要打开”**。

---

## ✨ 核心特性 / Features

- 🐳 **菜单栏常驻**：系统原生 `🐳` Emoji，自适应深浅色，不占用 Dock。
- 🟢 **状态点**：菜单栏与菜单内都有状态指示（绿 = 运行中，灰 = 已停止），每 2 秒轮询一次端口。只有在端口确实返回 DeepSeek Harness 时才判定为运行中，避免把占用同一端口的其他程序误认成 Harness。
- 🔌 **自定义端口**：默认 3080，可改成任意端口，启停与打开的网址会自动跟着变。
- 🚀 **一键启停 / 重启**：在后台拉起 `dsh web`，日志写入 `~/.dsh/logs/dsh-web.log`；停止时只结束本应用启动的那个进程。
- 🌐 **打开 Web 界面**：点击菜单或按全局热键，用默认浏览器打开（已在运行时则前置浏览器）。
- 🪟 **偏好设置面板（`⌘,`）**：
  - **端口**：修改并一键恢复默认。
  - **全局热键**：录制自定义全局热键，录完立即生效。
  - **开机自启动**（Launch at login）。
  - **启动时自动打开网页**。
  - 复制本地 Web 地址、查看运行日志。

---

## ⌨️ 快捷键速查 / Shortcuts

### 全局热键（任何软件处于前台时都有效）
| 快捷键 | 动作 | 说明 |
| :--- | :--- | :--- |
| **`⌥ + ⇧ + D`**<br>*(可在设置中修改)* | 打开 DSH Web | 服务未启动则先在后台拉起，再打开浏览器；已在运行则直接前置浏览器 |
| **`⌥ + ⇧ + H`** | 打开偏好设置面板 | |

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
| **`⌘ + Q`** | 退出 DSH Bar |

---

## 🛠 安装与构建 / Installation & Build

### 方式一：编译并安装（推荐）

```bash
git clone https://github.com/donald-trump86/dsh-bar-macos.git
cd dsh-bar-macos
make install
open -a "DSH Bar"
```

### 方式二：只编译，不安装

```bash
make
open "build/DSH Bar.app"
```

---

## 📂 项目结构 / Project Structure

```text
dsh-bar-macos/
├── Sources/
│   ├── main.swift              # 程序入口
│   ├── AppDelegate.swift       # 菜单栏图标（🐳 + 状态点）、菜单与状态控制
│   ├── ServiceManager.swift    # 状态检测（校验服务身份）、启停、日志与 PID 记录
│   ├── HotKeyManager.swift     # 基于 Carbon 的全局热键
│   ├── SettingsManager.swift   # 端口、开机启动 (SMAppService)、热键持久化
│   └── DashboardWindow.swift   # 毛玻璃偏好设置面板
├── Resources/
│   ├── AppIcon.icns            # 应用图标 (1024x1024)
│   └── icon.png                # README 与面板使用的图标
├── Info.plist                  # Bundle 配置（LSUIElement，仅菜单栏）
├── build.sh                    # 编译、签名与打包脚本
├── Makefile                    # make build / install / run / clean
├── LICENSE                     # MIT
└── README.md                   # 项目说明
```

---

## 📄 开源许可证 / License

本项目基于 [MIT License](LICENSE) 开源。
欢迎提 Issue 或 PR。
