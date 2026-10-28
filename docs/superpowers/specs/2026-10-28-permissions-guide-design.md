# 权限与访问引导设计

日期：2026-10-28
状态：用户已于 2026-10-28 审阅通过，进入实施。

## 目标与范围

用户希望减少从 DSH 使用其他 App 数据时遇到的授权困扰，并明确提到相册、媒体资料库、完全磁盘访问和自动化。采用原生 AppKit 引导窗口：第一次运行新增版本时自动显示一次，之后可从主窗口的设置区域重新打开。

该窗口帮助用户找到系统设置、理解授权对象和后续操作。当前阶段不增加照片、音乐或其他 App 的数据读取功能。macOS 的授权仍由用户在系统对话框或系统设置中完成。

关机变慢的调查结论保存在 [调查记录](../../research/permissions-and-shutdown-investigation.md)。本设计不改变服务退出逻辑；那部分目前有代码层面的疑点，尚未确认实际关机时的根因。

## 方案选择

采用“首次启动引导 + 设置常驻入口”。这满足用户提出的安装后授权需求，改动集中在菜单栏 App 内，保留现有服务启动方式。

另外两个方案暂不采用：

- 在 DSH 运行中读取权限失败并给出修复建议。这需要 DSH 提供可识别的错误和调用方信息，适合作为后续增强。
- 引入原生辅助进程，代替 DSH 访问照片、音乐并控制其他 App。它会增加新的数据访问接口、签名和进程管理工作，超出本轮需要。

## 进入与关闭

- 新增持久化字段 `DSH_PermissionsGuideVersion`，初始值为 0；本版引导版本为 1。
- 主窗口和现有服务监控初始化完成后，异步检查是否需要显示引导。应用已进入退出流程时跳过。
- 第一次实际显示引导后写入版本 1。关闭窗口、点“稍后设置”或未完成系统授权，均不导致下次启动自动再弹出。
- 普通版本升级不重置标记。只有将来明确需要重新展示新版说明时才提升引导版本。
- 设置区增加“权限与访问”一行和“打开引导”按钮。手动打开始终可用，也不触发服务启停或额外授权请求。
- 重复点击只激活已有窗口；引导为非模态窗口，可以直接关闭，不阻塞使用 DSH。

## 窗口内容

使用系统窗口、文本、按钮和滚动视图，沿用现有字体、颜色、间距与本地化方式。初始内容区约 620 × 560，允许缩小至约 520 × 460；长文案通过滚动显示。窗口保持在系统设置之外，方便返回查看操作说明。

开头说明：“按需要设置权限。授权通常授予实际发起请求的程序；从不同位置启动 DSH，系统显示的程序名称可能不同。”

| 项目 | 说明与操作 |
| --- | --- |
| 完全磁盘访问 | 用于读取 macOS 保护的文件位置。提示按系统显示的程序名称添加 DSH Bar、终端或实际运行程序；提供“打开系统设置”和“在访达显示本应用”。展示本应用只定位当前运行的 App，不声称它一定是所有请求的授权主体。 |
| 自动化 | 用于通过 Apple Events / AppleScript 控制其他 App。说明权限按“申请程序 → 被控制的 App”分别记录，通常在首次执行相应操作时出现；提供设置入口，用户按系统显示的目标 App 启用。 |
| 相册 | 说明通过 PhotoKit 访问照片资料库有独立授权，完全磁盘访问不能作为照片 API 已获授权的证明；提供“照片”设置入口。 |
| 媒体与 Apple Music | 说明媒体资料库 API 可能需要独立授权，操作“音乐”App 也可能使用自动化；提供媒体权限设置入口。系统版本没有对应页面时，按窗口给出的路径在隐私设置中查找。 |

底部保留“稍后设置”按钮，关闭窗口。关闭不代表用户已经授权。

本轮不增加通知、摄像头、麦克风、屏幕录制和辅助功能的请求；现有通知设置继续使用原有入口。

## 设置链接与授权状态

使用 `NSWorkspace` 打开以下设置链接：

- 完全磁盘访问：`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
- 自动化：`x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`
- 照片：`x-apple.systempreferences:com.apple.preference.security?Privacy_Photos`
- 媒体：`x-apple.systempreferences:com.apple.preference.security?Privacy_Media`

这些定位链接可能随 macOS 版本变化。每一项始终显示“系统设置 → 隐私与安全性 → 对应项目”的手动路径。若打开链接返回失败，再尝试隐私设置主页；仍失败则在窗口内提示按手动路径操作。打开调用返回成功也不能证明系统定位到了子页面。

不读取 TCC 数据库，不扫描受保护的文件来探测权限，不写系统授权，不重置权限。当前没有可依赖的统一公开 API 来验证这些项目，界面不显示“全部已授权”、绿色完成标记或授权百分比。

此引导不主动调用照片、音乐或自动化授权 API。由 DSH 实际功能发起的请求仍以系统确认的调用方为准。给菜单栏 App 授权不保证它管理的所有进程、终端会话或其他 App 自动获得权限。

## 代码位置与数据流

新增一个独立的权限窗口 `Sources/PermissionsWindow.swift`，包含权限项目、设置链接处理和 `PermissionsWindowController`，避免继续扩大主窗口的布局代码。实施时该文件才会创建。

- [应用代理](../../../Sources/AppDelegate.swift)：在启动尾部调用一次首次显示检查，并避开正在退出的状态。
- [设置存储](../../../Sources/SettingsManager.swift)：保存引导版本。
- [主窗口](../../../Sources/DashboardWindow.swift)：增加重开引导的设置行。
- [本地化](../../../Sources/Localization.swift)：补齐所有新增中英文文案；切换语言后窗口文案更新，已读标记不变。
- [构建脚本](../../../build.sh)：把新增 Swift 文件纳入显式源文件列表。

首次显示检查只读取本地设置、展示窗口、写入已读版本。打开权限设置、定位本应用分别由用户点击触发。以上路径均不调用服务启动、停止、安装或重启方法。

## 验证与验收

沿用仓库的 Python + Swift / AppKit fixture，测试实际方法，替换系统设置打开器和与服务有关的依赖。测试不改变本机权限或用户偏好。

必须验证：首次显示一次、关闭后不重复、手动可重开、退出阶段不弹窗；设置链接失败时的主页回退和错误提示；中英文完整、长文案无裁切；窗口操作不调用服务生命周期方法。

新增检查接入 [统一检查入口](../../../Tests/run-checks.sh)。完成后运行新增检查、`make check` 和双架构构建。系统设置子页面、真实授权弹窗和实际关机耗时需要用户在安装包中手动核实；交付时明确区分自动测试结果与这些待验证项。

## 依据

- [Apple：控制 App 对文件和文件夹的访问](https://support.apple.com/guide/mac-help/control-access-to-files-and-folders-on-mac-mchld5a35146/mac)
- [Apple：允许 App 控制其他 App](https://support.apple.com/guide/mac-help/allow-apps-to-control-other-apps-mchl108e1718/mac)
- [Apple：照片资料库用途说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription)
- [Apple：媒体资料库用途说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapplemusicusagedescription)

前两项与实际启动方式的核查过程见调查记录。后两项已读取 Apple 开发者文档；媒体用途说明对链接 macOS 15 SDK 或更新 SDK 的 macOS App 有明确要求，不据此承诺所有旧系统都有相同设置页面。
