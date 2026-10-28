# v1.0.5 权限引导发布补充

状态：用户于 2026-10-28 确认补充后合并、推送 main、创建 tag 并发布 Release。

## 范围

在已完成的四项权限引导末尾加入第五项“本地网络 / Local Network”。其余首启版本规则、设置入口、退出与服务行为沿用已审查实现。正式版本为 `1.0.5`，tag 为 `v1.0.5`。

## 行为与文案

- 在 `PermissionSettingsTarget` 追加 `localNetwork`；设置链接为 `x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork`，仍按现有逻辑回退到隐私主页。
- 中英文说明本地网络权限用于访问或发现局域网设备与服务，macOS 15 起提供该隐私控制。系统实际列出的申请程序应由用户核对；不能承诺 DSH Bar 的授权覆盖 Node、终端或其他程序。
- 手动路径为“系统设置 → 隐私与安全性 → 本地网络 / System Settings → Privacy & Security → Local Network”。旧系统或链接未定位时保留手动查找和回退提示。
- 窗口仍为初始 `620 × 560`、最小 `520 × 460`，五项内容可滚动到达，底部关闭操作可用；所有文案中英文完整。
- 不增加网络探测、权限请求、TCC 读取、usage-description 键、授权状态判断或服务生命周期调用。`guideVersion = 1` 与 `DSH_PermissionsGuideVersion` 保持不变，因为这是权限引导首次公开发布。

## 发布与验收

更新默认版本和 Markdown/HTML 发布说明。说明五项引导、首次展示可跳过、设置可重开、设置链接失败回退及权限限制；不声称关机延迟已修复。保留现有签名、Sparkle 公钥、更新源和 GitHub Actions 发布方式。

已有实际源码 fixture 覆盖第五项链接的成功、回退、完全失败，以及中英文内容和滚动布局；继续验证首次展示、手动重开及无服务副作用。本机通过隔离的权限与本地化检查、独立审查后合并 main；完整检查和双架构构建由对应提交的现有 CI 在临时 runner 执行，其成功后才推送 tag。本机不运行完整套件中会暂时修改用户钥匙串搜索列表的签名测试。由现有 Release 工作流生成正式包和 appcast。随后下载正式资产核对版本、架构、SHA256、代码签名与 Sparkle 签名，并确认 latest 更新源。

依据：[Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)；[Apple 本地网络设置说明](https://support.apple.com/guide/mac-help/control-access-to-your-local-network-on-mac-mchla4f49138/mac)。此补充不把平台资料当作本机实测。
