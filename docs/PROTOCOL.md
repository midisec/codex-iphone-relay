# 转发协议 v3

协议实现位于 [Wire.swift](../Sources/BridgeCore/Wire.swift)，手机 HTTP 引擎位于 [RelayEngine.swift](../Sources/BridgeCore/RelayEngine.swift)。Mac 与 iPhone 需使用相同协议版本。

## 传输

| 通道 | 连接 |
| --- | --- |
| 蓝牙 | 手机发布加密 LE L2CAP 通道，Mac 读取 GATT 中的 PSM 后连接 |
| Type-C | Mac 经系统 usbmuxd 连接手机 loopback 的 TCP 48765 端口 |
| 测试 | 显式启用的 localhost TCP，不用于生产连接 |

蓝牙 UUID：

```text
Service  E291E591-985B-46CC-B32B-7C93BD69D40A
PSM      E291E592-985B-46CC-B32B-7C93BD69D40A
Control  E291E593-985B-46CC-B32B-7C93BD69D40A
```

控制特征 `1` 请求唤醒，`2` 请求恢复 USB 监听。纯 Type-C 模式不启用蓝牙控制连接。

## 帧

每帧以 4 字节大端头部开始：bit 31 为压缩标记，bit 30 为二进制标记，低 30 位为后续负载长度。

控制消息使用 UTF-8 JSON。`body`、`data` 使用二进制负载，省去 Base64：1 字节类型（1=body、2=data）、1 字节 ID 长度、UTF-8 ID（1–64 字节）、原始正文（最多 32 KiB）。

压缩负载包含 4 字节大端解压后长度及 Apple `COMPRESSION_ZLIB` 数据。跨平台实现必须验证压缩格式互通，不能只依据同名 API 判断兼容。压缩作用于整个负载，解压后再按二进制标记解析。小型流式片段立即发送，不为凑块等待。

| 上限 | 值 |
| --- | --- |
| 帧及解压后负载 | 128 KiB |
| 请求体 | 16 MiB |
| 单次传输块 | 32 KiB |
| 未确认传输块 | 最多 4 块 |
| 发送队列 | 24 MiB |
| 并发请求 | 4 |
| 测速体 | 4 MiB |

## 配对认证

1. Mac 发送 `hello`：协议版本、客户端 nonce。
2. 手机发送 `challenge`：服务端 nonce 和 HMAC-SHA256 证明。
3. Mac 发送 `authenticate`：API base URL、证明、上传窗口及配置快照。
4. 手机验证并保存合并配置后发送 `ready`，附带配置快照。

证明以配对密钥的 UTF-8 字节作为 HMAC key，输出 Base64：

```text
server|clientNonce|serverNonce
client|clientNonce|serverNonce|baseURL
```

HMAC 用于握手认证，不对每帧提供应用层加密。蓝牙使用系统加密 L2CAP；USB 使用物理设备通道。手机到上游使用 HTTPS。

## API 配置同步

两端分别保存 `computer`、`phone` 配置及全局 `selection`（`automatic` / `computer` / `phone`）。每份配置和来源选择独立携带版本：毫秒时间戳、逻辑计数器、UUID，按此顺序比较。连接后观察到对端版本，再次保存必定生成更大的版本；未连接设备之间的先后以保存时间戳判断。

认证后通过 `settings` 交换快照，合并较新版本，持久化成功后才发送 `settingsAck`。确认摘要是配置对象按 Swift `JSONEncoder` 的 `sortedKeys` 编码后的 SHA-256（小写十六进制）；跨语言实现需对 JSON 字符串转义和省略空字段建立互通样例。收到较旧快照时回送合并结果。保存失败发送 `settingsError`，心跳重试未确认快照。

Mac 收到配置确认前对新的 API 请求返回 503，测速不依赖配置确认。手机通过 Keychain 保存两份配置，更换配对时清除旧电脑的副本，保留手机自己的配置。Mac 配置文件权限为 0600。

## 请求生命周期

```text
Mac → iPhone: request → body… → requestEnd
iPhone → Mac: response → data… → end / error
```

每个 `request` 保存当时生效的 `baseURL` 与凭证，后续配置变化不改动已开始的请求。

消息通过 `id` 关联并发请求；`bodyAck` 和 `ack` 控制上下行窗口，`cancel` 取消请求，`ping` / `pong` 检测连接。

本地代理验证 localhost 请求令牌，然后替换成上游 API 凭证。手机使用无持久缓存的 URLSession，拒绝跟随重定向转发凭证。只允许 `/responses`、`/responses/compact` 和 `/models`。

SSE 增量到达后立即转发。`response.completed`、`response.failed`、`response.incomplete` 为终止事件；文字片段结束不是整轮结束。缺少终止事件的断流报错，断线请求不自动重放。
