#!/usr/bin/env python3
"""Append each real output_text.delta immediately to a UTF-8 file via the local phone relay."""
import argparse
import http.client
import json
from pathlib import Path
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('prompt', help='本次请求内容；这是独立 API 请求，不读取 Codex 会话')
parser.add_argument('--output', type=Path, required=True, help='追加写入的 UTF-8 文本文件')
args = parser.parse_args()
config = json.loads((Path.home()/'.codex-3/bridge.json').read_text())
connection = http.client.HTTPConnection('127.0.0.1', config['port'], timeout=180)
body = json.dumps({'model': config['model'], 'input': args.prompt, 'stream': True, 'store': False}).encode()
start = time.monotonic()
connection.request('POST', '/responses', body, {'Authorization': 'Bearer '+config['localToken'], 'Content-Type': 'application/json'})
response = connection.getresponse()
if response.status != 200:
    connection.close(); raise SystemExit('请求失败：HTTP %d；输出文件未修改。' % response.status)
if not (response.getheader('Content-Type') or '').lower().startswith('text/event-stream'):
    connection.close(); raise SystemExit('上游没有返回 SSE；输出文件未修改。')
events, deltas, terminal, first_delta = [], 0, None, None
args.output.parent.mkdir(parents=True, exist_ok=True)
try:
    with args.output.open('a', encoding='utf-8') as target:
        while True:
            line = response.readline()
            if not line:
                break
            if line.strip(b'\r\n') == b'':
                if not events: continue
                payload = b'\n'.join(events); events = []
                try: event = json.loads(payload)
                except ValueError: continue
                if event.get('type') == 'response.output_text.delta':
                    delta = event.get('delta', '')
                    if not isinstance(delta, str): continue
                    if first_delta is None: first_delta = time.monotonic()-start
                    target.write(delta); target.flush()
                    sys.stdout.write(delta); sys.stdout.flush(); deltas += 1
                if event.get('type') in ('response.completed', 'response.failed', 'response.incomplete', 'error'):
                    terminal = event['type']; break
            elif line.startswith(b'data:'):
                events.append(line[5:].lstrip(b' ').rstrip(b'\r\n'))
finally:
    connection.close()
print('\n' + json.dumps({'deltas_appended': deltas, 'first_delta_seconds': round(first_delta, 3) if first_delta is not None else None,
                         'elapsed_seconds': round(time.monotonic()-start, 3), 'terminal_event': terminal}), file=sys.stderr)
if terminal != 'response.completed':
    raise SystemExit('流式请求未成功结束；已返回的部分仍保存在文件中，未伪造完成状态。')
