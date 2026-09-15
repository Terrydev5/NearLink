# 多平台客户端骨架

## Android

`android/` 是 Kotlin + Jetpack Compose 工程。当前已包含：

- `_nearlink._tcp` 的 Android NSD 发布与发现。
- WebSocket 控制通道客户端和服务端。
- 与 Apple 端一致的 `hello`、`text_message`、`ack` JSON 消息外形。
- 附近设备、消息、传输区域的基础界面。

## 当前边界

当前已实现 Apple 与 Android 之间“发现设备 + 建立 WebSocket + 发送文字”的核心链路，也实现了双方通过 TCP 文件流发送和接收文件、SHA-256 完整性校验及一次性数据流令牌。断点续传、完整的取消流程和中断后的恢复仍需后续完善。

Android 端需要 Android Studio、Android SDK 35 和允许局域网附近设备权限。Apple 和 Android 都应在真实设备/局域网环境测试，模拟器不能代替 mDNS 实机验证。
