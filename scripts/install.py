#!/usr/bin/env python3
"""Create an isolated Codex 3 profile. Never print or put real credentials in the repository."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import shutil
import subprocess
import sys
import time
import uuid

try:
    import tomllib
except ImportError:
    bundled = Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3'
    if bundled.exists() and Path(sys.executable).resolve() != bundled.resolve():
        os.execv(str(bundled), [str(bundled), __file__, *sys.argv[1:]])
    sys.exit('安装脚本需要 Python 3.11+。请使用 python3.11 scripts/install.py。')

ROOT = Path(sys._MEIPASS) if getattr(sys, 'frozen', False) else Path(__file__).resolve().parents[1]
MARKER = 'Managed by BluetoothCodex'


def resolve_codex_app(requested=None):
    candidates = [requested] if requested else [
        Path('/Applications/ChatGPT.app'), Path('/Applications/Codex.app'),
        Path.home() / 'Applications/Codex.app', Path.home() / 'Applications/ChatGPT.app',
    ]
    for candidate in candidates:
        app = Path(candidate).expanduser().resolve()
        if (app / 'Contents/Resources/codex').is_file():
            return app
    raise ValueError('未找到包含 Codex 程序的 App，请用 --codex-app 指定安装路径')


def private_write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + '.new')
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as stream:
        stream.write(value)
    temp.chmod(0o600)
    temp.replace(path)


def imported_settings(previous, base, key, model):
    """An explicit re-import counts as a new computer save, including clock skew."""
    state = dict(previous.get('apiSettings') or {})
    revisions = [state.get('selectionRevision', {})]
    revisions += [(state.get(side) or {}).get('revision', {}) for side in ('computer', 'phone')]
    last = max(revisions, key=lambda r: (r.get('milliseconds', 0), r.get('logical', 0)))
    physical = max(int(time.time() * 1000), last.get('milliseconds', 0))
    logical = last.get('logical', 0) + 1 if physical == last.get('milliseconds', 0) else 0
    state['computer'] = dict(credentials=dict(baseURL=base, apiKey=key, model=model),
                             revision=dict(milliseconds=physical, logical=logical, id=str(uuid.uuid4())))
    state['selection'] = 'automatic'
    state['selectionRevision'] = dict(milliseconds=physical, logical=logical+1, id=str(uuid.uuid4()))
    return state


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=Path.home() / '.codex-2')
    parser.add_argument('--destination', type=Path, default=Path.home() / '.codex-3')
    parser.add_argument('--apps', type=Path, default=Path('/Applications'))
    parser.add_argument('--codex-app', type=Path, help='包含 Contents/Resources/codex 的桌面 App')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--cli-path', type=Path, help='codex3 命令安装路径，默认 ~/.local/bin/codex3')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('当前安装器仅支持 macOS；Windows 适配状态见 docs/WINDOWS.md')
    args.apps = args.apps.expanduser().resolve()
    if not 1 <= args.port <= 65535:
        parser.error('Invalid port')
    source = args.source.expanduser().resolve()
    destination = args.destination.expanduser().resolve()
    if destination == source:
        parser.error('Source and destination must differ')
    if destination.exists() and not (destination / '.bluetooth-codex-managed').exists():
        parser.error('目标配置目录已存在且不属于本项目，拒绝覆盖')
    with (source / 'config.toml').open('rb') as stream:
        config = tomllib.load(stream)
    provider = config.get('model_providers', {}).get(config.get('model_provider'), {})
    base = provider.get('base_url')
    model = config.get('model')
    if not base or not model or provider.get('wire_api', 'responses') != 'responses':
        parser.error('源配置必须包含自定义 Responses provider、base_url 和 model')
    from urllib.parse import urlsplit
    parts = urlsplit(base)
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        parser.error('源 API 地址必须是 HTTPS base URL')
    auth = json.loads((source / 'auth.json').read_text()) if (source / 'auth.json').exists() else {}
    key = os.environ.get(provider.get('env_key', '')) or provider.get('experimental_bearer_token') or auth.get('OPENAI_API_KEY')
    if not isinstance(key, str) or not key or '\n' in key or '\r' in key:
        parser.error('未找到源 API 密钥；不会读取或复用 ChatGPT 会话令牌')
    if provider.get('http_headers') or provider.get('env_http_headers') or provider.get('auth'):
        parser.error('源 provider 使用了额外认证/请求头，需先为本项目添加显式支持')
    try:
        codex_app = resolve_codex_app(args.codex_app)
    except ValueError as error:
        parser.error(str(error))
    codex_cli = codex_app / 'Contents/Resources/codex'
    for name in ['Bluetooth Codex.app', 'Codex 3.app']:
        bundle = args.apps / name
        if bundle.exists() and not (bundle / 'Contents/Resources/managed.txt').exists():
            parser.error(f'{bundle} 已存在且不属于本项目，拒绝覆盖')
    launcher = (args.cli_path or Path.home() / '.local/bin/codex3').expanduser().resolve()
    if launcher.exists() and MARKER not in launcher.read_text():
        parser.error('现有 codex3 命令不属于本项目，拒绝覆盖')
    if not args.skip_build and not getattr(sys, 'frozen', False):
        subprocess.run(['bash', str(ROOT / 'scripts/build_mac.sh')], check=True)
    build = ROOT / '.build/manual'
    if not (build / 'BluetoothCodex').exists():
        parser.error('请先运行 bash scripts/build_mac.sh')
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination.chmod(0o700)
    previous = json.loads((destination / 'bridge.json').read_text()) if (destination / 'bridge.json').exists() else {}
    bridge = dict(upstreamBase=base.rstrip('/'), apiKey=key, model=model, port=args.port,
                  localToken=previous.get('localToken', secrets.token_hex(32)),
                  pairingToken=previous.get('pairingToken', secrets.token_hex(32)))
    bridge['apiSettings'] = imported_settings(previous, bridge['upstreamBase'], key, model)
    private_write(destination / 'bridge.json', json.dumps(bridge, indent=2) + '\n')
    # Only the local proxy token is installed in Codex 3. The real upstream key stays in bridge.json.
    private_write(destination / 'auth.json', json.dumps({'OPENAI_API_KEY': bridge['localToken']}) + '\n')
    toml = lambda value: json.dumps(value, ensure_ascii=False)
    content = f'''# {MARKER}. Re-run installer to refresh Codex 2 API settings.
model_provider = "iphone_bluetooth"
model = {toml(model)}
review_model = {toml(config.get('review_model', model))}
model_reasoning_effort = {toml(config.get('model_reasoning_effort', 'medium'))}
web_search = "disabled"

[model_providers.iphone_bluetooth]
name = "iPhone Bluetooth Relay"
base_url = "http://127.0.0.1:{args.port}"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 180000

[analytics]
enabled = false

[feedback]
enabled = false
'''
    private_write(destination / 'config.toml', content)
    private_write(destination / '.bluetooth-codex-managed', MARKER + '\n')
    bridge_app = args.apps / 'Bluetooth Codex.app'
    desktop_app = args.apps / 'Codex 3.app'
    version = plistlib.loads((ROOT / 'iOS/BluetoothRelay/Info.plist').read_bytes())
    for bundle, identifier, executable, name in [
        (bridge_app, 'local.wanmidi.codex.bluetooth', 'BluetoothCodex', 'Bluetooth Codex'),
        (desktop_app, 'local.wanmidi.codex.third', 'Codex3Launcher', 'Codex 3'),
    ]:
        macos = bundle / 'Contents/MacOS'; resources = bundle / 'Contents/Resources'
        macos.mkdir(parents=True, exist_ok=True); resources.mkdir(parents=True, exist_ok=True)
        (resources / 'managed.txt').write_text(MARKER + '\n')
        info = dict(CFBundleIdentifier=identifier, CFBundleExecutable=executable,
                    CFBundleName=name, CFBundleDisplayName=name, CFBundlePackageType='APPL',
                    CFBundleShortVersionString=version['CFBundleShortVersionString'],
                    CFBundleVersion=version['CFBundleVersion'], LSMinimumSystemVersion='13.0',
                    NSBluetoothAlwaysUsageDescription='通过蓝牙连接 iPhone，转发 Codex API 请求。')
        if bundle == desktop_app:
            info['LSUIElement'] = True
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    for binary in ['BluetoothCodex', 'libBridgeCore.dylib']:
        shutil.copy2(build / binary, bridge_app / 'Contents/MacOS' / binary)
        (bridge_app / 'Contents/MacOS' / binary).chmod(0o755)
    q = shlex.quote
    user_data = Path.home() / 'Library/Application Support/Codex-3'
    launch_script = f'''#!/bin/bash
# {MARKER}
set -euo pipefail
mkdir -p {q(str(user_data))}
/usr/bin/open {q(str(bridge_app))} --args --config {q(str(destination / 'bridge.json'))}
/usr/bin/open -n --env {q('CODEX_HOME=' + str(destination))} {q(str(codex_app))} --args {q('--user-data-dir=' + str(user_data))}
'''
    (desktop_app / 'Contents/MacOS/Codex3Launcher').write_text(launch_script)
    (desktop_app / 'Contents/MacOS/Codex3Launcher').chmod(0o755)
    cli_script = f'''#!/bin/bash
# {MARKER}
set -euo pipefail
if [[ "${{1:-}}" != "--help" && "${{1:-}}" != "--version" && "${{1:-}}" != "-h" && "${{1:-}}" != "-V" ]]; then
  /usr/bin/open {q(str(bridge_app))} --args --config {q(str(destination / 'bridge.json'))}
  READY=0
  for attempt in {{1..5}}; do
    codex_health=$(/usr/bin/curl --noproxy '*' --silent --max-time 1 http://127.0.0.1:{args.port}/health || true)
    codex_ready=$(printf '%s' "$codex_health" | /usr/bin/plutil -extract ready raw -o - - 2>/dev/null || true)
    codex_transport=$(printf '%s' "$codex_health" | /usr/bin/plutil -extract transport raw -o - - 2>/dev/null || true)
    if [[ "$codex_ready" == true && ( "$codex_transport" == bluetooth-l2cap || "$codex_transport" == usb-usbmux ) ]]; then READY=1; break; fi
    sleep 1
  done
  if [[ "$READY" != 1 ]]; then
    echo '尚未连接 iPhone。请在 Bluetooth Relay 中扫描 Mac 二维码并开始转发，然后重新运行 codex3。' >&2
    exit 1
  fi
fi
exec /usr/bin/env {q('CODEX_HOME=' + str(destination))} {q(str(codex_cli))} "$@"
'''
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text(cli_script); launcher.chmod(0o755)
    # Ad-hoc signatures let macOS associate the Bluetooth consent prompt with a stable bundle ID.
    subprocess.run(['codesign', '--force', '--sign', '-', str(bridge_app / 'Contents/MacOS/libBridgeCore.dylib')], check=True)
    for bundle in [bridge_app, desktop_app]:
        subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
    print('Installed:', desktop_app)
    print('Bluetooth proxy:', bridge_app)
    print('CLI:', launcher)
    print('Private profile:', destination)
    print('Source model preserved:', model)
    print('API key loaded securely; value not printed. Codex 2 was not changed.')


if __name__ == '__main__':
    main()
