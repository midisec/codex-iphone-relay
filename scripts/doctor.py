#!/usr/bin/env python3
"""Read-only deployment diagnostics. No secret values or device identifiers are printed."""
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.request
from ios import resolve_xcode

def run(*args, env=None):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    return result.returncode, result.stdout.strip()

profile = Path.home() / '.codex-3'
print('Codex 3:', '已安装' if Path('/Applications/Codex 3.app').exists() else '未安装')
print('Mac 蓝牙代理:', '已安装' if Path('/Applications/Bluetooth Codex.app').exists() else '未安装')
code, developer = run('xcode-select', '-p')
print('开发工具:', developer)
try:
    xcode_developer = resolve_xcode()
    xcode_env = dict(os.environ, DEVELOPER_DIR=str(xcode_developer))
    code, xcode = run('xcodebuild', '-version', env=xcode_env)
    print('完整 Xcode:', xcode if code == 0 else '已找到，但暂时无法运行')
    print('本项目使用:', xcode_developer)
    code, _ = run('xcodebuild', '-checkFirstLaunchStatus', env=xcode_env)
    print('Xcode 首次设置:', '已完成' if code == 0 else '尚未完成，请打开 Xcode 确认许可并安装组件')
except RuntimeError:
    print('完整 Xcode: 未安装；请按 iOS/INSTALL.md 安装')
code, identities = run('security', 'find-identity', '-v', '-p', 'codesigning')
match = re.search(r'(\d+) valid identities found', identities)
print('可用签名证书数量:', match.group(1) if match else '未知')
path = profile / 'bridge.json'
if path.exists():
    config = json.loads(path.read_text())
    print('模型:', config['model'])
    print('API 密钥:', '已读取' if config.get('apiKey') else '缺失')
    print('配置权限:', oct(path.stat().st_mode & 0o777))
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(f'http://127.0.0.1:{config["port"]}/health', timeout=2) as response:
            health = json.load(response)
        print('本地服务:', health['transport'])
        if 'usb_status' in health:
            print('USB 连接状态:', health['usb_status'])
        print('iPhone 已就绪:', health['ready'])
        if 'background_wake_ready' in health:
            print('蓝牙后台唤醒通道:', '已就绪' if health['background_wake_ready'] else '尚未就绪')
            if health.get('background_wake_error'):
                print('蓝牙唤醒错误码:', health['background_wake_error'])
        print('状态:', health['status'])
        print('已完成请求:', health['completed_requests'])
        print('协议版本:', health.get('protocol_version', 1))
        active = health.get('active_requests', [])
        print('正在转发的请求:', len(active))
        for item in active:
            print('  已用时 %.1f 秒，空闲 %.1f 秒，最后事件 %s' % (item['elapsed_ms']/1000, item['idle_ms']/1000, item.get('last_event', '等待响应')))
        for item in health.get('recent_requests', [])[-3:]:
            print('最近请求:', item['outcome'], 'HTTP %s' % item.get('http_status', '尚未响应'),
                  '%.1f 秒' % (item['elapsed_ms']/1000), item.get('terminal_event', '非 SSE 或无结束事件'))
        print('说明: 已就绪表示手机传输连接可用；API 是否成功以 HTTP 状态和响应结束事件为准。')
    except OSError:
        print('本地服务未启动，请打开 Bluetooth Codex.app')
else:
    print('缺少配置，请先运行 scripts/install.py')
