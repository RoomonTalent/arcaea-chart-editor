# Arcaea 谱面编辑器与本地曲库管理器

这是一个面向 Windows 和 Android 的独立 Flutter 工具。它可读写你选择的 Arc4 或 ArcExt 曲库，也可打开独立 AFF 文件。安装包使用独立的程序标识，能与原曲库管理器共存。

## 下载与使用

三个附件都可从 [v1.3.9 Release](https://github.com/RoomonTalent/arcaea-chart-editor/releases/tag/v1.3.9) 下载。

| 平台 | Release 附件 | 使用方式 |
| --- | --- | --- |
| Windows x64 | `ArcaeaChartEditor-1.3.9-windows-x64.zip` | 解压整个目录，再运行 `arcaea_chart_editor.exe`。 |
| Android ARM64 | `ArcaeaChartEditor-1.3.9-android-arm64.apk` | 安装 APK，包名为 `com.example.arcaea_chart_editor`，最低 API 24。 |
| 源码 | `ArcaeaChartEditor-1.3.9-source.zip` | 与 `v1.3.9` 标签的 Git 内容一致。 |

打开软件，在「设置」添加本地曲库。选择 Arc4、ArcExt 或包含它们的上级目录，可同时访问歌曲、曲包和人物资源。Android 用系统文件选择器授权目录。仅编辑独立谱面时，可从编辑器打开 AFF 并自行选配音乐。

## 功能

- **曲库管理**。按 Past、Present、Future、Beyond、Eternal 筛选或按名称、难度、默认顺序排序。歌曲、曲包和人物支持批量管理与可移植目录包导入导出。导出复制资源，导入按包内容同步相应的库清单。
- **AFF 编辑**。2D 时间轴与 3D 视图可编辑点键、长按、弧线、蛇和关键点。支持节拍吸附、变速、场景事件、4K／6K 切轨、备份浏览与恢复。Arc4 和 ArcExt 兼容检查会列出建议的转换及移除项。
- **预览与试玩**。两种视图均支持音乐、素材加载、可调流速和偏移。暂停时可在物量图上拖动 A/B 标记进行段落练习。可调整 3D 视角、键型判定区域、反馈布局和判定时间窗。
- **判定与延迟**。试玩暂停后进入「延迟校准 → 判定时间窗」，可按 2D／3D 和键型分别保存提前与延后边界。电脑地键可用 `D/F/J/K`，6K 外侧轨道可用 `S/L`。鼠标可在画面内操作空键与蛇，Android 可多指触控。

## 构建与测试

当前版本使用 Flutter 3.44.6 和 Dart 3.12.2。Windows 需要 Visual Studio 的「使用 C++ 的桌面开发」工作负载。Android 构建使用 JDK 21 和 Android SDK 36。使用 `flutter doctor` 检查各平台工具链。

```powershell
flutter pub get
flutter analyze
flutter test
```

Windows 构建命令为 `flutter build windows --release`，产物目录为 `build/windows/x64/runner/Release`。Android ARM64 构建命令如下。

```powershell
flutter build apk --release --split-per-abi --target-platform android-arm64
```

APK 位于 `build/app/outputs/flutter-apk/`。当前 Release APK 使用项目的调试签名配置，以兼容此前同签名的安装包。自行构建时，Android 工具链会使用本机签名配置。Android Gradle Wrapper、Dart 依赖锁文件和 Windows 原生音频源码随项目提供。

| 目录 | 内容 |
| --- | --- |
| `lib/chart/` | AFF 解析、编辑、渲染、判定和练习 |
| `lib/services/` | 曲库索引、存储、备份和导入导出 |
| `android/` | Android 工程、目录授权、音频和显示性能适配 |
| `windows/` | Windows 工程与音频桥接 |
| `test/` | 编辑、判定、曲库与资源测试 |

## 本地数据和素材

应用使用你自行提供的曲库和音乐。此仓库及源码附件仅包含构建和测试所需的项目文件。曲库、个人谱面、缓存、备份、导出、设备 SDK 路径和签名文件均由 `.gitignore` 排除。将资料放入曲库目录或仓库之外有助于保持提交清单清晰。

人物立绘和游戏译文可通过对应曲库管理。人物技能和离线可用性记录在管理器档案里。Windows 音频依赖的来源与授权说明见 [第三方音频组件](windows/runner/third_party/NOTICE.txt)。
