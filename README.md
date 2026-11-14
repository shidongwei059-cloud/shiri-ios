# 拾日（Shiri）

拾日是一款原生 iOS 应用，用于记录待办、日程和生活回忆。应用采用 SwiftUI 和 Core Data，最低支持 iOS 16.0。

- 支持中文文字录入和设备端语音识别，可创建重复日程、生日提醒与地点提醒。
- 包含桌面和锁屏小组件、实时活动、快捷指令及系统分享扩展。部分系统能力取决于系统版本。
- 支持照片回忆、周期回顾、备份与恢复。CloudKit 同步与共享需要配置相应的 Apple 开发者能力。

## 构建与测试

1. 在 Xcode 中打开 `Shiri.xcodeproj`。
2. 选择 **Shiri** scheme 和本机的 iPhone 模拟器，点击 Run。建议使用 Xcode 26.5 或更新版本，以编译使用新版 SDK 的功能。
3. 在仓库根目录运行 `swift test`，执行 `ShiriCore` 的测试。`ShiriAppTests` scheme 包含原生服务测试，`Shiri` scheme 包含 UI 测试。

默认配置将 CloudKit 设为关闭。需要为真机签名或配置云能力时，复制 `Configuration/Local.example.xcconfig` 为 `Configuration/Local.xcconfig`，填入自己的开发团队、应用标识、App Group 和 CloudKit 容器。Apple 开发者账户中的能力配置完成后，再启用云功能。

## 工程结构

| 路径 | 内容 |
| --- | --- |
| `Shiri/` | 主应用、页面、设计系统和资源 |
| `ShiriCore/` | 数据模型、日程规则、持久化、备份与共享 |
| `ShiriSystem/` | 快捷指令、语音、闹钟和实时活动 |
| `ShiriWidgets/`、`ShiriShareExtension/` | 小组件和系统分享扩展 |
| `ShiriTests/`、`ShiriAppTests/`、`ShiriUITests/` | 核心、原生服务和界面测试 |

应用内的 Noto Serif SC 字体随附 [SIL Open Font License 1.1](Shiri/Resources/Fonts/OFL.txt)。
