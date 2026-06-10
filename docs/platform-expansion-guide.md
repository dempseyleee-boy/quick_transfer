# Quick Transfer 跨平台扩展实施指南

本文说明如何在保留 Flutter 技术栈的前提下，将 Quick Transfer 从当前的
Linux + Android 扩展到 Windows、NVIDIA Jetson、macOS 和 iOS。

推荐实施顺序：

1. Windows
2. Jetson
3. macOS
4. iOS

采用渐进式方案：保留现有桌面端和移动端项目，先抽取共享核心，再逐个平台
接入。不要为每个平台复制一份网络协议和传输逻辑。

## 1. 当前项目状态

当前仓库由两个 Flutter 项目组成：

- 仓库根目录：桌面端，已有 Linux 和 Windows 工程。
- `mobile/`：移动端，目前只有 Android 工程。

当前主要逻辑集中在：

- `lib/main.dart`
- `mobile/lib/main.dart`
- `lib/transfer_queue.dart`

两个 `main.dart` 同时包含界面、HTTP 服务、设备发现、连接管理、文件处理、
剪贴板和本地存储。继续直接增加平台会导致重复代码和行为不一致，因此跨平台
开发前必须先拆分共享核心。

## 2. 目标架构

建议调整为以下结构：

```text
quick_transfer/
├── lib/                         # 桌面端界面和桌面适配
├── mobile/lib/                  # 移动端界面和移动适配
├── packages/
│   └── quick_transfer_core/
│       ├── lib/src/model/       # 设备、消息、文件元数据
│       ├── lib/src/protocol/    # API 路径、JSON 编解码、协议版本
│       ├── lib/src/network/     # HTTP 客户端、服务端、发现
│       ├── lib/src/transfer/    # 队列、重试、文件传输
│       └── test/                # 不依赖平台的单元测试
├── linux/
├── windows/
├── macos/                       # 后续生成
└── mobile/
    ├── android/
    └── ios/                     # 后续生成
```

共享核心只能依赖 Dart 和跨平台 package，不应直接依赖 Widget、页面状态或某个
操作系统的原生 API。

平台相关功能通过接口注入：

```dart
abstract interface class ClipboardAdapter {
  Future<String?> readText();
  Future<void> writeText(String text);
}

abstract interface class FileStorageAdapter {
  Future<String> saveReceivedFile(String name, Stream<List<int>> content);
}
```

桌面端和移动端分别实现这些接口。这样 Windows、Jetson、macOS 可以复用桌面
界面，Android、iOS 可以复用移动界面。

## 3. 开始扩展前必须完成的工作

### 3.1 固定开发环境

- 在 CI 和开发机使用同一个 Flutter stable 版本。
- 当前项目使用 Flutter 3.24.x；先确保现有 Linux 和 Android 在该版本下有完整
  基线，再单独升级 Flutter。
- 升级 Flutter 时单独提交，不要与平台迁移混在同一次提交中。
- 提交 `.metadata`、各平台工程文件和 lock 文件。
- 执行 `flutter doctor -v` 并记录每个平台缺少的工具链。

### 3.2 抽取共享数据模型

至少建立以下模型：

- `DeviceInfo`：设备 ID、名称、IP、端口、平台和最后在线时间。
- `TransferMessage`：消息 ID、类型、发送方、时间和内容。
- `FileMetadata`：文件名、大小、校验值和 MIME 类型。
- `ProtocolError`：错误代码、可读信息和是否允许重试。

所有 JSON 编解码集中在共享核心，UI 不再直接操作未校验的
`Map<String, dynamic>`。

### 3.3 固化协议

为当前 HTTP 协议增加版本，例如：

```text
GET  /api/v1/status
POST /api/v1/connect
POST /api/v1/send
GET  /api/v1/messages
```

每个响应至少包含：

```json
{
  "protocolVersion": 1,
  "requestId": "uuid",
  "status": "ok"
}
```

还需要完成：

- 统一超时、重试次数和错误码。
- 限制 JSON 请求体大小。
- 对文件名执行清理，禁止 `../` 等路径穿越。
- 接收文件后校验大小和 SHA-256。
- 给首次配对增加一次性验证码或二维码。
- 配对后保存设备令牌，拒绝未授权设备发送内容。

当前局域网 HTTP 没有身份认证。扩展到更多设备前必须解决，否则同一网络中的
其他主机可以向应用发送剪贴板或文件。

### 3.4 改造文件传输

当前文件以 Base64 放入 JSON，会增加约三分之一的数据量，并要求发送端和
接收端把整个文件放入内存。

建议分两步处理：

1. 第一阶段设置明确的文件大小上限，保留现有协议以完成平台移植。
2. 第二阶段改为 multipart 或二进制流，支持分块、进度、取消、断点续传和
   SHA-256 校验。

大文件流式传输完成前，不应宣传“大文件传输”能力。

### 3.5 改造设备发现

当前移动端通过扫描局域网 IP 查找设备，速度慢，也容易触发平台权限限制。

推荐：

- 使用 mDNS/Bonjour 广播 `_quicktransfer._tcp` 服务。
- 保留手动输入 IP 作为回退方式。
- 设备发现结果按稳定设备 ID 去重，不按 IP 作为唯一身份。
- 在双网卡、VPN、IPv6 和 Wi-Fi 隔离环境中测试。

### 3.6 建立测试基线

共享核心至少需要：

- 模型 JSON 编解码测试。
- 协议版本兼容和错误响应测试。
- HTTP 客户端与本地测试服务器集成测试。
- 队列入队、出队、过期和重试测试。
- 文件名清理、大小限制和校验失败测试。
- 未配对设备访问被拒绝的安全测试。

每个平台都要通过同一套互操作测试：

- 发现设备。
- 手动连接。
- 双向发送文字。
- 双向同步剪贴板。
- 双向发送小文件。
- 断网后恢复。
- 应用重启后重新连接。
- 拒绝未授权设备。

## 4. Windows

Windows 工程已经存在，CI 也已经执行 `flutter build windows --release`，但这
只能证明可以编译，不能证明应用可用。

### 需要完成

1. 在 Windows 10 和 Windows 11 安装 Visual Studio，并启用
   `Desktop development with C++` 工作负载。
2. 运行：

   ```powershell
   flutter doctor -v
   flutter pub get
   flutter test
   flutter analyze
   flutter build windows --release
   ```

3. 验证 `file_picker`、`path_provider`、剪贴板和 HTTP 服务在 Windows 上正常。
4. 首次启动时正确处理 Windows Defender 防火墙提示。
5. 分别测试专用网络和公用网络配置。
6. 将界面中的“Ubuntu 端”等平台硬编码改为动态平台名称。
7. 配置应用名称、公司名、版本、图标和可执行文件元数据。
8. 生成正式安装包，推荐 MSIX；同时可保留 zip 便携包。
9. 对安装包和可执行文件进行代码签名，减少 SmartScreen 警告。
10. 在 GitHub Actions 的 Windows runner 上上传完整安装包，而不只是 `.exe`。

### Windows 验收

- Windows 与 Android 可双向传输文字、剪贴板和文件。
- Windows 重启应用后仍能读取已配对设备。
- 防火墙规则不会开放不必要的公网访问。
- 安装、升级和卸载不会删除用户接收的文件。
- 安装包在干净的 Windows 10、Windows 11 虚拟机上可运行。

## 5. NVIDIA Jetson

Jetson 运行 ARM64 Linux。当前 Linux 构建和 `.deb` 只面向 x64，不能直接复制
到 Jetson 使用。

### 需要先确认

- Jetson 型号：Nano、Xavier、Orin 等。
- JetPack 版本及其对应的 Ubuntu 版本。
- 设备是否有桌面环境、显示器和 GPU 图形栈。
- 产品需要桌面 GUI，还是更适合后台接收服务。

对于无屏 Jetson，建议增加无界面的 Dart 服务模式，而不是强制运行 Flutter
桌面窗口。

### GUI 版本需要完成

1. 在目标 Jetson 或同版本 ARM64 Ubuntu 环境安装 Flutter 和 Linux 构建依赖。
2. 确认 Flutter、Dart SDK 和所有 native plugin 支持 Linux ARM64。
3. 在 ARM64 主机原生构建，避免一开始就引入复杂的交叉编译。
4. 运行：

   ```bash
   flutter doctor -v
   flutter pub get
   flutter test
   flutter analyze
   flutter build linux --release
   ```

5. 检查产物架构：

   ```bash
   file build/linux/arm64/release/bundle/quick_transfer_desktop
   ```

6. 在 Wayland 和 X11 环境分别验证窗口、文件选择器和剪贴板。
7. 生成 `Architecture: arm64` 的 `.deb`，不要复用当前 amd64 包。
8. 检查 GTK、GLIBC、libstdc++ 和其他动态库依赖。
9. 可选：提供 systemd user service，实现登录后自动启动。

### 无界面服务版本

共享核心完成后，可新增一个纯 Dart 入口：

```text
bin/quick_transfer_service.dart
```

服务模式负责：

- 启动局域网 API。
- mDNS 广播。
- 接收文件到指定目录。
- 输出结构化日志。
- 通过配置文件控制端口、保存目录和配对策略。

服务模式不得依赖 Flutter Widget、系统剪贴板或文件选择器。

### Jetson CI 与验收

- 使用自托管 Jetson runner，或 ARM64 Linux runner 构建。
- 在目标 JetPack 版本的真机上运行，不以 x64 模拟结果代替。
- Jetson 与 Android、Windows 互相传输。
- 连续运行 24 小时，检查内存、句柄和端口占用。
- 断开并恢复 Wi-Fi/以太网后可重新发现。
- `.deb` 可安装、升级、卸载，架构标记为 arm64。

## 6. macOS

macOS 必须在 Mac 上开发、构建和签名。建议使用 Apple Silicon Mac，同时验证
Apple Silicon 和 Intel 产物需求。

### 工程创建

在仓库根目录执行：

```bash
flutter create --platforms=macos .
flutter pub get
flutter build macos
```

提交生成的 `macos/` 工程，但不要覆盖已有 Dart 业务代码。

### 需要完成

1. 安装当前 Flutter 版本支持的 Xcode 和 CocoaPods。
2. 设置唯一 Bundle ID、显示名称、版本、图标和最低 macOS 版本。
3. 在 macOS App Sandbox 中启用：
   - 出站网络连接。
   - 入站网络连接，因为应用要监听端口 `8765`。
   - 用户选择文件的读权限。
   - 接收目录所需的写权限。
4. 验证局域网明文 HTTP 的 App Transport Security 配置；只添加局域网所需的
   最小例外，不允许任意公网明文请求。
5. 接入 Bonjour/mDNS，并配置需要声明的服务类型。
6. 验证文件选择器、下载目录、剪贴板和多网卡行为。
7. 决定发布方式：
   - 官网分发：Developer ID 签名、Hardened Runtime、公证和 stapling。
   - Mac App Store：App Sandbox、商店签名和 App Store Connect。
8. 构建通用包，或分别发布 arm64 与 x64 包。
9. 生成 `.dmg` 或 `.pkg`，并验证升级流程。

### macOS 验收

- macOS 与 Android、Windows 双向互通。
- Apple Silicon 真机通过测试。
- 如支持 Intel，Intel 真机或可靠环境通过测试。
- 签名、公证和 Gatekeeper 检查通过。
- 应用沙盒下可以选择、发送和保存文件。
- 退出应用后端口正确释放。

## 7. iOS

iOS 工程应加入 `mobile/` 项目，以复用移动端界面。iOS 的权限、后台执行和文件
访问限制比 Android 严格，不能简单复制 Android 配置。

### 工程创建

在 `mobile/` 目录执行：

```bash
flutter create --platforms=ios .
flutter pub get
open ios/Runner.xcworkspace
```

构建和发布必须使用 macOS、Xcode 和 Apple 开发者账号。

### 需要完成

1. 设置唯一 Bundle ID、开发团队、签名证书和 provisioning profile。
2. 设置 App Store Connect 应用记录、版本和构建号。
3. 在 `Info.plist` 添加面向用户的本地网络权限说明。
4. 如使用 Bonjour/mDNS，声明应用浏览和广播的服务类型。
5. 为局域网 HTTP 配置最小范围的 ATS 本地网络例外。
6. 检查所有 Flutter package 是否明确支持 iOS。
7. 通过系统文件选择器选择待发送文件。
8. 接收文件先保存到应用沙盒，再通过系统分享或文件导出功能交给用户。
9. 在真机测试 Wi-Fi、本地网络授权被拒绝、重新授权和网络切换。
10. 配置应用图标、启动画面、隐私清单和 App Store 隐私信息。

### iOS 后台限制

iOS 应用进入后台后可能很快被挂起，因此不能保证 HTTP 服务持续监听，也不能
保证定时轮询持续执行。

第一版 iOS 应明确采用以下产品行为：

- 应用在前台时支持完整收发。
- 应用在后台时不承诺实时接收。
- 回到前台后重新启动服务、恢复连接并拉取待处理消息。
- 不使用伪造后台音频、持续定位等方式绕过系统限制。

如果以后必须实现后台可靠接收，需要单独设计 APNs 通知、中继服务或用户主动
触发的传输流程。这将改变当前“纯局域网、无云服务”的产品边界。

### iOS 验收

- iPhone 与 Windows、Linux、macOS 双向互通。
- 首次本地网络授权流程清晰。
- 用户拒绝权限时有可理解的错误提示和设置入口。
- 前后台切换后应用不会重复启动服务器或占用端口。
- 文件导入、接收、分享和删除符合 iOS 沙盒规则。
- TestFlight 安装包通过真实设备测试。
- App Store 提交材料和隐私声明与实际行为一致。

## 8. CI/CD 调整

建议将当前工作流拆成以下任务：

| 任务 | Runner | 输出 |
| --- | --- | --- |
| Core tests | Ubuntu | 共享核心测试报告 |
| Linux x64 | Ubuntu x64 | tar.gz、amd64 deb |
| Windows | Windows | MSIX、zip |
| Jetson | ARM64/self-hosted | arm64 deb |
| Android | Ubuntu | APK、AAB |
| macOS | macOS | signed app、dmg/pkg |
| iOS | macOS | unsigned test build 或 signed IPA |

要求：

- PR 执行 analyze、单元测试和可行的平台编译。
- Release tag 才执行签名、公证和商店上传。
- 证书、私钥和 provisioning profile 放在 GitHub Secrets，不提交到仓库。
- 每个平台的产物名称包含版本和架构。
- 发布任务从 `pubspec.yaml` 读取版本，禁止在 workflow 中硬编码版本号。
- 正式发布前生成 SHA-256 校验文件。

## 9. 跨平台测试矩阵

每个平台完成后，至少测试下列组合：

| 发送端 | 接收端 |
| --- | --- |
| Windows | Android |
| Windows | Linux |
| Jetson | Android |
| Jetson | Windows |
| macOS | Android |
| macOS | Windows |
| iOS | Windows |
| iOS | Linux/macOS |

每个组合测试：

- 发现与手动连接。
- 中英文和多行文字。
- 空剪贴板及大段剪贴板。
- 0 字节、小文件、接近大小上限的文件。
- 同名文件。
- 非 ASCII 文件名。
- 传输中断、超时和重试。
- 对方应用关闭、后台或网络切换。
- 未配对设备和无效协议请求。

## 10. 推荐里程碑

### 里程碑 A：共享核心

- 完成模型、协议、网络服务、队列和存储接口拆分。
- Linux 与 Android 功能不回退。
- 核心测试可在无界面的 CI 中运行。

### 里程碑 B：Windows

- 完成实机互操作、防火墙处理、MSIX 和 Windows CI。
- 发布第一个正式 Windows 安装包。

### 里程碑 C：Jetson

- 完成 ARM64 构建、arm64 deb 和 Jetson 真机测试。
- 根据产品场景决定是否交付无界面服务模式。

### 里程碑 D：macOS

- 完成 macOS 工程、沙盒权限、签名、公证和安装包。
- 与已有平台完成互操作测试。

### 里程碑 E：iOS

- 完成本地网络权限、Bonjour、沙盒文件处理和前后台恢复。
- 通过 TestFlight 验证后再准备 App Store 发布。

### 里程碑 F：协议与大文件增强

- 完成设备认证。
- 完成流式文件传输、进度、取消、校验和断点续传。
- 建立协议兼容策略，确保旧客户端得到明确的升级提示。

## 11. 每个平台完成的定义

某个平台只有同时满足以下条件才算完成：

- Debug 和 Release 均可构建。
- 核心测试、analyze 和平台集成测试通过。
- 至少与两个其他平台完成真机互操作。
- 权限拒绝、断网、超时和磁盘写入失败有明确处理。
- 安装包可安装、升级和卸载。
- 版本、图标、应用名称和架构正确。
- 正式包完成该平台要求的签名。
- CI 能重复生成同类产物。
- README 包含该平台的安装说明。
- 发布记录明确列出已知限制。

## 12. 官方参考

- [Flutter 支持的平台和架构](https://docs.flutter.dev/reference/supported-platforms)
- [Flutter 桌面支持](https://docs.flutter.dev/platform-integration/desktop)
- [Flutter Windows 发布](https://docs.flutter.dev/deployment/windows)
- [Flutter Linux 发布](https://docs.flutter.dev/deployment/linux)
- [Flutter macOS 发布](https://docs.flutter.dev/deployment/macos)
- [Flutter iOS 环境配置](https://docs.flutter.dev/platform-integration/ios/setup)
- [Flutter iOS 发布](https://docs.flutter.dev/deployment/ios)
- [Apple 本地网络权限说明](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription)
- [Apple 本地网络 ATS 配置](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
- [Apple macOS 入站网络权限](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server)
- [NVIDIA Jetson Linux Developer Guide](https://docs.nvidia.com/jetson/)
