# Windows 适配

当前没有 Windows 客户端。现有 macOS 程序依赖 AppKit、CoreBluetooth、Network.framework、CryptoKit 和 Compression，不能直接在 Windows 编译运行。

## 建议顺序

| 阶段 | 工作 | iPhone 改动 |
| --- | --- | --- |
| 1. Type-C | Windows 本地代理、USB 设备连接、协议 v3、Codex 配置与安装器 | 前台转发可复用现有服务 |
| 2. Type-C + 蓝牙 | 通过 Windows GATT 写入控制特征，验证后台唤醒 | 先验证现有控制特征兼容性 |
| 3. 纯蓝牙 | 验证 LE L2CAP CoC 接口；必要时新增 GATT 数据传输 | GATT 方案需新增分片、确认及流控 |

### Type-C

[libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) 支持 Windows 和 iOS 设备端口连接，其 Windows 运行依赖 Apple Mobile Device Support。可用它连接手机的 `127.0.0.1:48765` 服务，复用现有帧格式、配对认证和 HTTP 流式语义。这是可行的移植路线，尚未完成本项目的 Windows 真机验证。

Windows 客户端可使用 .NET 实现本地 HTTP 服务与桌面界面，将 USB 连接封装为字节流，再接入协议层。若引入 libusbmuxd 或 iproxy，需保留各自的第三方许可证；它们不随本仓库分发。

### 蓝牙

Microsoft 提供 [Windows GATT API](https://learn.microsoft.com/en-us/windows/apps/develop/devices-sensors/bluetooth-low-energy-overview)，可用于设备发现和特征读写。本项目的主要数据通道是 **LE L2CAP CoC**，不能仅凭 Windows 支持 GATT 就认为可以直接兼容。

Microsoft 的 [L2CAP 连接文档](https://learn.microsoft.com/en-us/windows-hardware/drivers/bluetooth/creating-a-l2cap-client-connection-to-a-remote-device)面向驱动层，也不能作为现有 iPhone 通道已支持 Windows 用户态客户端的证明。需要先做接口和设备验证，再决定复用 CoC 还是增加 GATT 传输。

## 验收目标

- Windows 不经手机热点或系统默认路由访问 API。
- 仅监听 localhost，保留配对、本地令牌、取消及超时处理。
- 连续流式追问正常结束，断线后明确报错。
- Type-C 随机数据往返达到 1 MiB/s 目标并通过 SHA-256 校验。
- 单独验证锁屏、后台、拔插和重连。

Mac 已有测速不能代表 Windows 性能。Windows 版的首个性能目标应放在 Type-C；纯蓝牙不承诺 1 MB/s。
