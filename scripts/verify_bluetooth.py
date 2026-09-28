#!/usr/bin/env python3
"""Actual hardware acceptance: only proceeds when the production BLE link is authenticated."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request

profile = Path.home() / '.codex-3'
config = json.loads((profile / 'bridge.json').read_text())
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(f'http://127.0.0.1:{config["port"]}/health', timeout=3) as response:
        health = json.load(response)
except OSError:
    raise SystemExit('请先打开 Codex 3，扫描二维码并在 iPhone 开始转发。')
if health.get('transport') != 'bluetooth-l2cap' or not health.get('ready'):
    raise SystemExit('尚未建立真实蓝牙连接。测试未执行；不会回退到 Mac 互联网或测试通道。')
with tempfile.TemporaryDirectory(prefix='codex3-bluetooth-') as tmp:
    directory = Path(tmp)
    sandbox = directory / 'local-only.sb'
    sandbox.write_text('(version 1)\n(allow default)\n(deny network-outbound)\n(allow network-outbound (remote ip "localhost:*"))\n')
    answer = directory / 'answer.txt'
    env = dict(os.environ, CODEX_HOME=str(profile))
    command = ['/usr/bin/sandbox-exec', '-f', str(sandbox), '/Applications/ChatGPT.app/Contents/Resources/codex',
               'exec', '--ephemeral', '--skip-git-repo-check', '-s', 'read-only', '-C', str(directory),
               '-o', str(answer), 'Reply exactly BLUETOOTH_OK. Do not call tools.']
    try:
        result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
    except subprocess.TimeoutExpired:
        raise SystemExit('真实蓝牙请求超时，请检查手机前台状态、蜂窝网络和 API 可达性。')
    if result.returncode != 0 or not answer.exists():
        print(result.stderr.decode(errors='replace')[-2500:])
        raise SystemExit('真实蓝牙请求失败。')
    value = answer.read_text().strip()
    if value != 'BLUETOOTH_OK':
        raise SystemExit('模型未返回预期验收标记，请检查 Codex 输出。')
    print('PASS: Codex → 本机代理 → 加密蓝牙 → iPhone → API → 蓝牙回复。')
    print('Codex 外部网络连接已被沙箱禁止。模型回复：BLUETOOTH_OK')
