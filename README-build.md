# 财神记薪：原生工程构建

工程包含 iPhone 应用 `CaishenPay` 和单目标 watchOS 应用 `CaishenWatch`。最低系统版本为 iOS 17 / watchOS 10；Swift 5 语言模式。两个应用都链接本地 `Packages/WorkPayCore`，不下载第三方依赖。

## 生成与打开

在 `CaishenPay` 目录执行：

```sh
python3 Scripts/generate_project.py
open CaishenPay.xcodeproj
```

生成器仅依赖 Python 3 标准库，会扫描 `Apps/iOS`、`Apps/Watch`、`Apps/Shared` 下的 Swift 文件和 `Resources` 下的资源。新增、删除或移动这些文件后重新运行；仅修改文件内容不需要重新生成。生成的 PBX 对象 ID 稳定，两个 Scheme 已共享。请通过生成器维护工程结构，通过 `Config` 下的 plist 维护应用元数据。

`Apps/Shared` 和 `Resources` 自动加入两个目标。iPhone 目标依赖 Watch 目标，并通过 Embed Watch Content 把 Watch 应用打包到 iPhone 应用中。Watch 的 `WKCompanionAppBundleIdentifier` 与 iPhone bundle ID 一致。

## 命令行验证

下面的命令只为当前进程选择 Xcode，不会修改全局 `xcode-select`。如果 Xcode 不在 `/Applications/Xcode.app`，替换相应路径。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -list -project CaishenPay.xcodeproj

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CaishenPay.xcodeproj -scheme CaishenPay \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build-xcode CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CaishenPay.xcodeproj -scheme CaishenWatch \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath .build-xcode CODE_SIGNING_ALLOWED=NO build

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --package-path Packages/WorkPayCore
```

`CaishenPay` 和 `CaishenWatch` 的 Scheme 用于运行应用；计算逻辑的测试位于 Swift package，使用最后一条命令执行。两个 build 命令应顺序运行，避免共用 DerivedData 时产生数据库锁冲突。模拟器构建不需要开发团队或签名证书。Xcode 仍需要访问系统中的 SDK、SwiftPM 缓存和 CoreSimulator 服务；受限执行环境需要允许这些访问。

构建产物：

- iPhone：`.build-xcode/Build/Products/Debug-iphonesimulator/CaishenPay.app`
- Watch：`.build-xcode/Build/Products/Debug-watchsimulator/CaishenWatch.app`
- iPhone 内嵌 Watch：`.build-xcode/Build/Products/Debug-iphonesimulator/CaishenPay.app/Watch/CaishenWatch.app`

## 真机签名

用 Xcode 打开工程，在两个应用目标的 Signing & Capabilities 中选择自己的 Team，并按需替换 bundle ID：

- iPhone：`com.caishen.jixin`
- Watch：`com.caishen.jixin.watchkitapp`

如替换 bundle ID，同时更新 `Scripts/generate_project.py` 中的两处目标配置，以及 `Config/Watch-Info.plist` 的 `WKCompanionAppBundleIdentifier`，然后重新生成工程。Team 未写死；可在 Xcode 中选择，或命令行传入 `DEVELOPMENT_TEAM`。重新生成工程会重建 build settings，因此个人签名设置建议使用命令行覆盖，或在生成器中保存自己的本地配置。

工程没有 App Groups、iCloud、推送等额外 entitlement。WatchConnectivity 使用配对设备通信，不依赖 App Group。Watch 缓存同步数据，离线录入会在设备重新通信后合并；完整配对同步仍需在实际配对的 iPhone 与 Apple Watch 上验证。

`WKRunsIndependentlyOfCompanionApp` 为 `false`：产品需要 iPhone 设置工资与班次，Watch 作为伴随应用安装。离线计时不依赖进程持续后台运行。
