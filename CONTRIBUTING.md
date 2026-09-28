# 贡献指南

## 开发环境

macOS 13+、Swift 5.9+、Python 3.11+。iPhone 构建还需要完整 Xcode。

```bash
make check
make ios-build
```

`make check` 构建 Mac 程序并运行协议、USB 恢复、安装器及本地集成测试，不读取真实 API 凭证，也不调用模型 API。GitHub Actions 执行相同检查和 iOS 未签名构建；蓝牙、USB 及后台行为需要真机验证。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `Sources/BridgeCore` | 消息协议、配对认证、传输、本地代理、手机 HTTP 引擎 |
| `Sources/BridgeMac` | macOS 界面与连接管理 |
| `Sources/BridgeRelay` | 本地集成测试用转发进程 |
| `iOS/BluetoothRelay` | iPhone 界面、扫码与后台生命周期 |
| `Tests` | 核心、恢复及安装器测试 |
| `scripts` | 构建、安装、诊断与验收脚本 |
| `docs` | 安装、协议、测试和平台说明 |

## 提交变更

- 一次 PR 聚焦一个问题，说明行为变化及验证结果。
- 协议修改同时更新两端、测试及 `docs/PROTOCOL.md`。
- UI 修改附真实截图，不包含配对二维码、API key 或私人会话。
- 真机测试注明系统版本、连接方式和前后台状态。

App 版本在 `iOS/BluetoothRelay/Info.plist` 中维护，Mac 安装器读取同一版本。Xcode 工程可通过 `python3 scripts/generate_ios_project.py` 重新生成；签名团队仅在本机配置。

## 私有文件

API 配置位于用户目录，仓库不接收 `auth.json`、`bridge.json`、签名证书、描述文件和真实请求日志。日志、构建产物及本机工具环境由 `.gitignore` 排除。

提交的贡献按 [MIT 许可](LICENSE) 分发。
