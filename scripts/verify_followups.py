#!/usr/bin/env python3
"""Three real Codex turns in one isolated session, with outbound Internet denied."""
import json
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--transport', choices=['bluetooth', 'usb'], default='bluetooth')
args = parser.parse_args()
expected_transport = {'bluetooth': 'bluetooth-l2cap', 'usb': 'usb-usbmux'}[args.transport]
config = json.loads((Path.home() / '.codex-3/bridge.json').read_text())
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with opener.open('http://127.0.0.1:%s/health' % config['port'], timeout=3) as response:
    health = json.load(response)
if not health['ready'] or health['transport'] != expected_transport:
    raise SystemExit('指定通道尚未连接，测试未执行。')
with tempfile.TemporaryDirectory(prefix='codex3-followups-') as tmp:
    root = Path(tmp); profile = root / 'profile'; profile.mkdir(mode=0o700)
    auth = profile / 'auth.json'
    auth.write_text(json.dumps({'OPENAI_API_KEY': config['localToken']})); auth.chmod(0o600)
    (profile / 'config.toml').write_text('''model_provider = "iphone_bluetooth"
model = %s
model_reasoning_effort = "high"
web_search = "disabled"
[model_providers.iphone_bluetooth]
name = "iPhone Bluetooth Relay"
base_url = "http://127.0.0.1:%s"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 180000
''' % (json.dumps(config['model']), config['port']))
    sandbox = root / 'local-only.sb'
    sandbox.write_text('(version 1)\n(allow default)\n(deny network-outbound)\n(allow network-outbound (remote ip "localhost:*"))\n')
    prefix = ['/usr/bin/sandbox-exec', '-f', str(sandbox), '/Applications/ChatGPT.app/Contents/Resources/codex', 'exec']
    env = dict(os.environ, CODEX_HOME=str(profile))
    session_id = None
    prompts = [('Remember the marker BLUE_7421. Reply exactly BLUE_7421. Do not call tools.', 'BLUE_7421'),
               ('What marker did I ask you to remember? Reply only that marker. Do not call tools.', 'BLUE_7421'),
               ('Append _DONE to the remembered marker. Reply only the result. Do not call tools.', 'BLUE_7421_DONE')]
    for i, (prompt, expected) in enumerate(prompts):
        answer = root / ('answer%d.txt' % i)
        command = prefix + (['resume', session_id] if session_id else ['-s', 'read-only', '-C', str(root)])
        command += ['--skip-git-repo-check', '--json', '-o', str(answer), prompt]
        start = time.monotonic()
        with opener.open('http://127.0.0.1:%s/health' % config['port'], timeout=3) as response:
            if json.load(response)['transport'] != expected_transport:
                raise SystemExit('测试前通道已切换，请重试。')
        result = subprocess.run(command, env=env, capture_output=True, timeout=180)
        with opener.open('http://127.0.0.1:%s/health' % config['port'], timeout=3) as response:
            if json.load(response)['transport'] != expected_transport:
                raise SystemExit('测试中通道已切换，本轮不能算作指定通道的验收。')
        events = []
        for line in result.stdout.splitlines():
            try: events.append(json.loads(line))
            except ValueError: pass
        for event in events:
            if event.get('type') == 'thread.started': session_id = event['thread_id']
        value = answer.read_text().strip() if answer.exists() else ''
        if result.returncode or value != expected or not any(e.get('type') == 'turn.completed' for e in events):
            detail = result.stderr.decode(errors='replace')[-1600:]
            for key in ('apiKey', 'localToken', 'pairingToken'):
                detail = detail.replace(config[key], '[REDACTED]')
            print(detail, flush=True)
            for event in events:
                if event.get('type') in ('error', 'turn.failed'):
                    detail = json.dumps(event, ensure_ascii=False)
                    for key in ('apiKey', 'localToken', 'pairingToken'):
                        detail = detail.replace(config[key], '[REDACTED]')
                    print(detail[:1600], flush=True)
            raise SystemExit('FAIL: turn %d did not finish with the expected marker (exit %d).' % (i+1, result.returncode))
        print('PASS: turn %d, %.2fs, explicit turn.completed, reply=%s' % (i+1, time.monotonic()-start, value), flush=True)
    print('PASS: three %s Codex turns retained context; all Codex Internet connections denied.' % expected_transport)
