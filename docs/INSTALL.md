# Mac 安装

免编译安装见 [安装包教程](BINARY_INSTALL.md)。以下为源码构建及高级选项。

需要 macOS 13+、Swift 5.9+、Python 3.11+，以及包内含 `Contents/Resources/codex` 的 Codex 桌面 App。

```bash
bash scripts/build_mac.sh
python3 scripts/install.py --source ~/.codex-2 --skip-build
```

源目录可替换为 `~/.codex` 等现有配置目录。安装器保留 API 地址及模型，使用独立的 `~/.codex-3`，不会修改源配置。源 API 必须使用 HTTPS，且手机能够访问。

## 选项

| 参数 | 默认值 | 用途 |
| --- | --- | --- |
| `--source` | `~/.codex-2` | 源 Codex 配置目录 |
| `--codex-app` | 自动查找 | 指定包含 Codex 可执行文件的 `.app` |
| `--apps` | `/Applications` | 安装目录 |
| `--port` | `8765` | 本地代理端口 |
| `--skip-build` | 关闭 | 使用已有构建产物 |
| `--cli-path` | `~/.local/bin/codex3` | 自定义命令安装位置 |

```bash
python3 scripts/install.py \
  --source ~/.codex \
  --codex-app /Applications/Codex.app \
  --apps ~/Applications
```

将 `~/.local/bin` 加入 shell 的 `PATH` 后，可直接运行 `codex3`。

## 更新

退出 **Bluetooth Codex**，更新仓库后重新构建并安装。安装器保留本地令牌和配对密钥，拒绝覆盖不属于本项目的目录或 App。

协议变更时需同时更新两端，见 [iPhone 安装](../iOS/INSTALL.md)。

## 修改 API

Mac 窗口右上角齿轮打开 **API 配置**。支持 HTTPS API 地址、密钥及模型；密钥留空保留现有值。

保存后连接中的两端自动同步。显示 **已同步** 后，新请求使用生效配置，正在进行的回复继续传完。默认模型写入 Codex 3 的 `config.toml`；修改模型后请新建会话或重启 Codex 3。来源规则见 [使用教程](USAGE.md#3-设置-api)。

配置保存在当前转发配置目录，文件权限为 `0600`，不会修改源 Codex 配置。再次运行安装器会重新导入 `--source` 的 API 信息。

## 状态与诊断

```bash
python3 scripts/doctor.py
curl --noproxy '*' http://127.0.0.1:8765/health
```

`/health` 提供连接方式、活动请求、HTTP 状态和传输统计，不包含正文或 API key。诊断、测速和追问脚本默认读取 `~/.codex-3`。

| 现象 | 处理 |
| --- | --- |
| 找不到 Codex App | 用 `--codex-app` 指定安装路径 |
| 手机已连线，Mac 仍等待 | 手机点击“开始转发”，确认设备信任及两端模式一致 |
| 其他应用也通过手机联网 | 检查系统个人热点、Wi-Fi 热点及“iPhone USB”网络服务 |
| 回复停住或连接中断 | 检查 `/health`，回到手机 App 前台后重试 |

USB 设备转发与 USB 网络共享独立。本项目不会为系统设置默认路由，也不会自动开关个人热点。
