# 财神记薪安装包

- [下载 iPhone + Apple Watch 开发签名 IPA](CaishenPay-1.0.0-red-jar-development.ipa)
- [SHA-256 校验文件](CaishenPay-1.0.0-red-jar-development.ipa.sha256)
- 版本：1.0.0（构建 1），含江南水彩风红钱罐与五枚铜钱的新图标。
- 对应源码提交：`9befd721876b972da32ee4520e05fe6e18816a16`。
- 验证：44 项核心测试通过；iPhone 与内嵌 Watch 构建、签名校验通过；IPA 内全部文件与已签名构建产物一致。

此包为开发签名版本，仅适用于描述文件已登记的设备；不是 App Store 或 TestFlight 分发包。开发签名过期后，需要使用自己的开发者签名重新构建安装。

下载后可使用 Xcode 的 Devices and Simulators 安装到符合签名条件的 iPhone。为保留本地记薪数据，请直接覆盖安装，不要先卸载旧版本。

在下载目录校验完整性：

```sh
shasum -a 256 -c CaishenPay-1.0.0-red-jar-development.ipa.sha256
```
