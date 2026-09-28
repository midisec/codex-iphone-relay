# Codex iPhone Relay v1.5.1 安装

**简体中文** | [English](BINARY_INSTALL.en.md)

## Mac

支持 Apple Silicon（M1 及更新芯片）、macOS 13+。需预先安装 Codex 桌面 App，并备好 Responses API 配置。

1. 解压 `codex-relay-v1.5.1-macos-arm64.zip`。
2. 双击 `Install.command`，输入已有配置目录，例如 `~/.codex-2` 或 `~/.codex`。
3. 打开安装后的 **Codex 3**。

无需 Python 或 Xcode。默认安装到 `~/Applications`；检测到 `/Applications` 中的旧版时原位更新。源码配置保持不变。

此包未经过 Apple 公证。如果 macOS 拦截，先尝试打开 `CodexRelaySetup`，再到 **系统设置 → 隐私与安全性 → 仍要打开** 中允许该程序，然后重试安装。

## iPhone

下载 `codex-relay-v1.5.1-ios-unsigned.ipa`，支持 iOS 16+。IPA 已编译，需要使用自己的 Apple Account 签名安装。

**没有开发证书：** 按 [AltStore Classic 官方教程](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) 安装 AltStore，保持 AltServer 运行、手机连接 Mac，在手机 **AltStore → My Apps → ＋** 中选择 IPA。按系统提示开启开发者模式、信任开发者。普通账号需定期刷新签名，通常为 7 天。

**已有开发证书：** 将证书及私钥导入钥匙串，双击 `Sign-iPhone.command`，填写 IPA 和 `.mobileprovision` 的完整路径（不要加引号）。描述文件必须包含目标 iPhone。生成的签名 IPA 可用 Apple Configurator 安装。

也可在终端签名：

```bash
./CodexRelaySetup iphone \
  --ipa ../codex-relay-v1.5.1-ios-unsigned.ipa \
  --profile /path/to/your.mobileprovision \
  --output ~/Desktop/BluetoothRelay-signed.ipa
```

添加 `--device '设备名称或标识'` 可签名后直接安装，此选项需要完整 Xcode。以上流程均无需编译源码。首次安装、签名及后续续签需要联网；日常转发可关闭 Mac 外网。

## 配对与使用

1. Mac 转发窗口点击 **配对 iPhone**；手机 **配对 Mac → 扫描二维码**，保存。
2. 两端选择 **Type-C / 蓝牙 / Type-C + 蓝牙**，手机点击 **开始转发**。
3. 显示 **已连接**、API **已同步** 后，在 Codex 3 中提问。

两端齿轮可修改 API，默认最近保存的一端生效。手机必须能访问 API。无需个人热点，项目仅转发 API。更新前退出 Mac 转发 App，更新后手机重新点击 **开始转发**。

后台运行受 iOS 限制；Windows、Intel Mac 安装包尚未提供。
