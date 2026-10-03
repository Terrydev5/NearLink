# 多平台客户端

阅读代码可从[代码阅读指南](../docs/code-reading-guide.md)开始，按应用入口、业务状态、设备发现、文字收发、文件传输和历史保存逐步跟踪。协议行为差异和仍有限制见[协议说明](../docs/protocol.md#implementation-limitations)。

## iOS / macOS

`apple/` 是共用的 SwiftUI 工程，通过条件编译处理权限、保存目录、Photos 和文件预览差异。工程最低目标为 iOS 16、macOS 13。使用 Xcode 打开 `NearLink.xcodeproj`；脚本测试位于 `apple/scripts/`。

## Android

`android/` 是 Kotlin + Jetpack Compose 工程。当前已包含：

- `_nearlink._tcp` 的 Android NSD 发布与发现。
- WebSocket 控制通道客户端和服务端。
- 与 Apple 端一致的 `hello`、`text_message`、`ack` JSON 消息外形。
- 附近设备、消息、传输区域的基础界面。

## Windows

`windows/` 是 .NET 10 + WinUI x64 工程。`Core/` 提供 DNS-SD、WebSocket、TCP 文件收发及 JSON 历史，`Tests/` 包含可在 macOS/Linux 运行的核心测试和跨端样本测试。

Windows 与 Android 发送端等待接收方完成回执，60 秒内未收到时显示未确认；它还实现了传输超时、活动连接取消和实际接收路径持久化。WinUI 的原生构建、启动、防火墙与实机互传仍需在 Windows 上验证。构建、发布和目录说明见 [Windows README](windows/README.md)。

## 当前边界

当前已实现 Apple 与 Android 之间“发现设备 + 建立 WebSocket + 发送文字”的核心链路，也实现了双方通过 TCP 文件流发送和接收文件、SHA-256 完整性校验及一次性数据流令牌。断点续传、完整的取消流程和中断后的恢复仍需后续完善。

Apple、Android 与 Windows 都会自动检查文件邀请，符合条件时自动接收，没有逐文件确认弹窗。接收方的低存储空间提示只是提醒，不是授权确认；发现列表和当前选中的会话也不是接收白名单。

单文件接收上限为 2 GiB，同时最多接收 10 个文件；接收前为并发任务计算存储预算，至少预留 512 MiB 可用空间，预计剩余空间低于 2 GiB 时提醒接收方，不足时拒收。iOS 会为可能发生的相册副本预留额外空间。这里检查的是磁盘存储，不是运行内存。

接收过程中检查实际字节数和剩余空间，文件大小及 SHA-256 校验通过后才发布文件；能够正常进入异常处理的失败会清理临时文件或待发布媒体。强制终止进程后的恢复仍未完善。

Android 发送端目前仍可能在对端确认前显示完成；Apple/Android 的取消操作和令牌过期也不代表所有数据连接已释放。Android 重连地址更新、Apple 历史文件实际路径持久化仍待完善。仓库已有 Windows 和 Apple 协议契约 CI 定义，Android CI 与系统性的四平台实机验证记录仍待补齐。具体边界见 [协议说明](../docs/protocol.md#implementation-limitations)。

2026-10-03 检查中，iOS/macOS 构建、Android APK/单元测试、Windows 核心测试通过；Android Lint 仍有两项 error。详细环境与未验证范围以复查报告为准。

Android 端需要 Android Studio、Android SDK 35 和允许局域网附近设备权限。Apple 和 Android 都应在真实设备/局域网环境测试，模拟器不能代替 mDNS 实机验证。
