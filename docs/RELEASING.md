# 打包 Release

需要 Apple Silicon Mac、完整 Xcode、Python 3.11+。先完成两端 Release 构建和测试：

```bash
make check
make ios-build
python3 -m venv .local/release-tools
.local/release-tools/bin/python -m pip install pyinstaller==6.22.0
.local/release-tools/bin/python scripts/package_release.py
.local/release-tools/bin/python Tests/release_smoke.py
```

若 iPhone 产物不在默认目录，用 `--ios-app /path/to/BluetoothRelay.app` 指定。包版本读取 `iOS/BluetoothRelay/Info.plist`。

`dist/` 输出 Mac 安装 ZIP、未签名 IPA、源码 ZIP 和 `SHA256SUMS`。Mac 包内置 Python、预编译 App、安装器、签名工具及第三方许可；不包含 Codex 桌面 App。

iPhone 包会移除签名及描述文件。源码从 Git 跟踪文件与未忽略文件中按白名单打包，排除构建、配置、日志和证书。发布前仍需核对文件内容。

验证后，在 GitHub 创建 `v1.5.1` Release，使用 [版本说明](releases/v1.5.1.md)，上传三个包和 `SHA256SUMS`。仓库未配置 remote 时仅生成本地文件。

仓库名称、双语简介与 Topics 见 [GitHub 项目信息](GITHUB.md)。
