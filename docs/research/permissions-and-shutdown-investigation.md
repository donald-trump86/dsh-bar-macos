# DSH Bar 权限与关机延迟调查

范围：本仓库 v1.0.4、现有隔离测试、本机已安装 DSH 的退出控制器，以及 Apple 权限文档。本次记录调查结果；未操作真实 DSH 服务，未修改系统权限或执行关机。

## 结论

退出路径存在等待和自动恢复竞争的风险，但尚未证明它就是本机关机变慢的原因。**服务稳定、生命周期空闲且没有安装任务时，代码没有固定的长时间退出等待。** 发现 `.terminateLater` 本身不足以判断每次关机都会多等十几秒。

权限引导可以在安装后的首次启动显示，并在设置中保留入口。macOS 的权限分别管理，不能真实提供“一键允许所有 App”。尤其需要区分“访问其他 App 的数据”与“控制某个 App”；Apple 将它们定义为不同机制。

## 退出调查

| 场景 | 已确认行为 | 对延迟的含义 |
| --- | --- | --- |
| 稳定、空闲、无安装 | 无安装时异步完成取消回调，随后在主线程排入空闲动作 | 没有固定长等待；若此场景仍然慢，需要日志或实测补证 |
| 安装正在进行 | 先取消并等安装清理，再等待服务生命周期空闲 | 清理进入退出关键路径；等待链没有整体截止时间 |
| 启动、停止、重启或恢复中 | 等待 `!snapshot.phase.isBusy` | 操作耗时进入退出时间；30 × 0.5 秒只是启动流程的一部分，不是硬上限 |
| 等待退出时服务异常退出 | 停止监控、取消恢复发生得晚；恢复逻辑没有退出状态门禁 | 可能排入新恢复任务，延长已有等待 |
| 普通退出菜单 | 默认保留后台服务 | 必须区分普通退出、退出并停止、系统注销/关机和更新重启 |

直接证据：

- [Sources/AppDelegate.swift:85](../../Sources/AppDelegate.swift#L85)：`applicationShouldTerminate` 依次等待 `cancelInstallForTermination`、`performWhenLifecycleIdle`，之后才 `prepareForTermination` 并回复系统。
- [Sources/DshVersionController.swift:255](../../Sources/DshVersionController.swift#L255)：安装任务完成后才调用退出等待者；[Sources/DshVersionController.swift:271](../../Sources/DshVersionController.swift#L271) 无安装时异步完成，有安装时登记等待者并取消。
- [Sources/ServiceManager.swift:213](../../Sources/ServiceManager.swift#L213)：空闲队列仅检查 busy 状态，没有退出总截止时间。
- [Sources/ServiceManager.swift:1174](../../Sources/ServiceManager.swift#L1174)：启动还包含路径查找、探测、启动、日志准备及版本检查。
- [Sources/ServiceManager.swift:1605](../../Sources/ServiceManager.swift#L1605)：自动恢复排程和执行时没有退出状态检查；[Sources/ServiceManager.swift:1674](../../Sources/ServiceManager.swift#L1674) 才停止监控和取消恢复。
- [Sources/ServiceManager.swift:1681](../../Sources/ServiceManager.swift#L1681)：退出并停止仅处理本应用管理的服务，保护外部启动的服务。

### 超时与版本关系

服务停止脚本给 SIGTERM 后约 3 秒宽限；本机已安装 DSH 的退出控制器允许最多 5 秒销毁应用树，然后强制退出。时限不一致可能导致 Bar 提前升级信号，但不能单独证明普通退出或系统关机变慢。

安装取消采用独立机制：[Sources/InstallProcess.swift:85](../../Sources/InstallProcess.swift#L85) 向本次创建并持有的进程组发送 SIGTERM，0.6 秒后 SIGKILL，观察退出后短暂排空。之后还有回收及安装任务清理，不能把这段时间当作整个应用退出的硬上限。

日志助手未故意忽略 SIGTERM：[Sources/main.swift:7](../../Sources/main.swift#L7) 直接运行日志写入器，不创建 NSApplication；[Sources/RotatingLogWriter.swift:177](../../Sources/RotatingLogWriter.swift#L177) 忽略的是 SIGHUP 和 SIGPIPE。

v1.0.3 与 v1.0.4 的服务管理、主入口和日志助手相关代码没有变化。v1.0.4 新增退出前的安装取消等待，使停止监控和恢复更晚；这是待验证的回归方向，不能认定全部关机延迟均由此次更新引入。

### 修正候选，尚未实施

1. 退出一开始就标记正在退出，停止监控、唤醒响应及自动恢复；保留在途任务必要的所有权记录与清理。
2. 启动入口、恢复排程、延迟回调以及后台完成回调都检查退出状态，防止取消后重新排程。
3. 区分普通退出、退出并停止服务、系统注销/关机、更新重启，保留普通退出留服和外部服务保护。
4. 给等待链设计整体截止时间，同时保证进程所有权与记录一致；不能仅加定时回复，让残留回调继续启动服务。
5. 核对服务停止宽限与 DSH 清理期限，结合隔离实测确定数值。

## 权限调查

现有通知权限请求、查询和设置跳转可以复用：[Sources/ServiceNotifier.swift:89](../../Sources/ServiceNotifier.swift#L89)。当前设置页已有通知入口：[Sources/DashboardWindow.swift:585](../../Sources/DashboardWindow.swift#L585)，没有统一权限引导。

Apple 的 [NSAppDataUsageDescription 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappdatausagedescription) 明确：macOS 14 起，打开其他 App 沙箱容器中的文件会触发 Other Application Data 提示。该键解释用途，缺失时使用系统默认文案；不能按不同目标容器提供不同文案。实际读取了 Apple 的[文档 JSON](https://developer.apple.com/tutorials/data/documentation/bundleresources/information-property-list/nsappdatausagedescription.json)。它不是预授权开关。

[Info.plist:1](../../Info.plist#L1) 当前既没有 `NSAppDataUsageDescription`，也没有 `NSAppleEventsUsageDescription`。是否需要补充应以真实请求方和实际功能为依据；仅添加说明键不能保证消除提示。

| 权限或访问 | 可实现内容 | 限制 |
| --- | --- | --- |
| Other Application Data / 受保护文件 | 解释用途、识别请求方，按实际情况引导完全磁盘访问等设置 | 不预设它等于自动化；完全磁盘访问没有可靠通用的公开查询 API，不能任意探读后宣称全部授权 |
| 辅助功能 | 查询本应用权限，用户操作后请求或打开设置 | Bar 状态不能代表 node；Carbon 快捷键本身无需因此申请辅助功能 |
| 屏幕录制 | 针对实际捕获程序查询或请求 | Bar 结果不能代表浏览器或其他捕获者；不为引导自动截屏 |
| 控制其他 App / Apple Events | 按目标 App 说明授权和设置入口 | 没有预授权全部目标的总开关；不执行无关控制操作制造授权项 |
| 通知 | 复用现有真实状态与请求入口 | 系统决定结果，拒绝后仍可继续使用 |

“安装后提示”应落实为首次启动：把应用复制到 Applications 不会执行应用代码。引导应可跳过、可重开，避免每次启动连续弹出系统授权框。

### 请求身份

[Info.plist:11](../../Info.plist#L11) 标识固定为 `ai.deepseek.dsh-bar`，发布流程已有稳定签名。但实际 DSH/Node 在应用包外运行；权限归属仍须验证，不能保证授权 Bar 覆盖所有启动方式。终端启动、Bar 启动及升级后应分别检查。

### 结合本轮补充后的范围

用户补充了相册、媒体资料库、完全磁盘访问和自动化。已据此形成[首次启动引导与设置入口设计](../superpowers/specs/2026-10-28-permissions-guide-design.md)，设计与实施计划已获批准，现按任务实施。具体弹窗文字和申请程序仍未核实，界面会按实际请求方说明授权，不假定全部请求都归属于 Bar。

- 本轮方案：首次启动引导，加设置中的常驻入口，提供上述四类说明和系统设置入口。复用 AppKit 与现有签名，保留服务启动架构。
- 后续可选增强：设计稳定签名的执行组件，调整 DSH 启动和敏感操作路径，尽量固定可管理操作的身份。这需要单独的服务架构与升级设计，仍不能预授权全部 App。

## 验证及剩余未知

- `python3 Tests/service-termination-check.py` 通过，覆盖现有退出委托、重复退出、安装与生命周期等待、外部服务保护、更新延迟恢复。它不测真实系统关机耗时，不能反证上述竞态。
- 尝试只读 loginwindow / runningboardd 中与本应用相关的统一日志，系统返回 `log: Cannot run while sandboxed`，退出码 64。未绕过，未取得真实关机时序。
- 未执行真实安装、服务操作或关机，未修改 TCC 数据库、重置授权或读取浏览器登录数据。
- 尚需最常见弹窗的准确文字与请求方；真实首次授权、拒绝、撤销、升级后的权限归属及关机时间仍待验证。
