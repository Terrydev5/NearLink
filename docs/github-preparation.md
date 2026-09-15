# NearLink GitHub 仓库准备说明

## 当前目录

将 `NearLink/` 作为独立 GitHub 仓库根目录：

```text
NearLink/                         # GitHub 仓库根目录
├── apps/
│   ├── apple/                    # iOS + macOS Xcode 工程
│   ├── android/                  # Android Studio / Kotlin 工程
│   └── (future platforms)/       # 后续平台按需加入
├── docs/
├── README.md
├── SECURITY.md
├── .gitignore
└── LICENSE
```

Apple 工程已经从 `NearLink/NearLink/` 移动到 `apps/apple/`。工程文件和源码目录整体移动，保持了它们之间的相对路径。

`NearLink技术文档和Goal相关指令.rtf` 不应直接公开提交：它同时包含技术内容和内部 Goal 指令。日后请只将经过整理、适合公开的技术说明写入 `docs/`。

## 当前及后续目录

当前 Apple 和 Android 客户端统一放在 `apps/` 下：

```text
NearLink/
├── apps/
│   ├── apple/                    # iOS + macOS Xcode 工程
│   └── android/                  # Android Studio / Kotlin 工程
├── shared/
│   ├── protocol/                 # 跨端协议定义、版本规范
│   └── test-vectors/             # SHA-256、消息编码等跨端测试样本
├── docs/
│   ├── architecture.md           # 架构与模块边界
│   ├── protocol.md               # Bonjour/发现、控制消息、文件流协议
│   ├── privacy.md                # 本地传输、数据存放与权限说明
│   ├── development.md            # 各平台开发与构建说明
│   └── screenshots/
├── tools/                        # 协议校验或发布辅助脚本（以后再加）
├── README.md
├── LICENSE
└── .gitignore
```

`shared/` 首先存放“协议规范和测试样本”，不要急于强行共享业务源码。Swift 和 Kotlin 技术栈不同；先保证两端都按同一份协议实现和通过同一批测试样本，维护成本更低。

## 适合提交到 GitHub 的内容

- Swift、Kotlin 客户端的源码与资源。
- `.xcodeproj/project.pbxproj`、Gradle 配置、解决方案文件等工程定义。
- `Package.resolved`、`Podfile.lock`、Gradle Wrapper 等可复现构建所需的锁定文件。
- 公开 README、协议文档、隐私说明、截图和开源许可证。
- 不含真实密钥的 `.env.example` 或配置示例文件。

## 不应提交的内容

- Xcode/Gradle/Visual Studio 构建产物与个人 IDE 状态。
- 证书、私钥、provisioning profile、签名文件。
- 真实 `.env`、Firebase 或其他第三方服务的真实配置。
- 用户接收的文件、测试照片/视频、日志和崩溃报告。
- 含内部指令的原始 RTF 文档。

## 发布仓库前的最小文件集

第一版建议补齐：

1. `README.md`：项目介绍、支持平台、功能、截图、构建步骤、局域网权限说明。
2. `LICENSE`：若希望其他人可以复用代码，MIT 是简单常见的选择；若要限制商业复用，需要另行选择许可证。
3. `docs/protocol.md`：先稳定消息格式、协议版本、发现服务名、文件校验方式；这会是 Apple/Android 实现的共同依据。
4. `SECURITY.md`：说明当前安全边界与私下报告漏洞的方式。
5. `CONTRIBUTING.md`：有人准备参与贡献时再增加即可，不是首发阻塞项。

## 初始化时的检查顺序

```text
1. 在 NearLink/ 初始化 Git 仓库。
2. 确认 .gitignore 生效，没有 .DS_Store、DerivedData、证书或私密配置进入暂存区。
3. 添加 README 和 LICENSE。
4. 使用 GitHub 的 Secret Scanning / push protection，避免未来误提交密钥。
5. 创建 GitHub 的空仓库并推送首个提交。
```

在完成上述检查前，不要用 `git add .` 后直接推送；先查看待提交文件列表，确认没有私人资料或构建缓存。首个公开版本应标明为实验性版本，并说明当前没有 TLS 或设备配对，不适合敏感数据。
