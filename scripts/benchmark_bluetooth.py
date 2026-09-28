#!/usr/bin/env python3
"""Measure authenticated Mac↔phone echo throughput without any API or Internet request."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kind', choices=['random', 'text', 'source', 'both'], default='both')
parser.add_argument('--rounds', type=int, default=3)
parser.add_argument('--output', type=Path)
parser.add_argument('--transport', choices=['bluetooth', 'usb'], default='bluetooth')
parser.add_argument('--size-kib', type=int, default=256)
args = parser.parse_args()
if not 1 <= args.size_kib <= 4096 or not 1 <= args.rounds <= 30:
    parser.error('size-kib must be 1–4096 and rounds must be 1–30')
config = json.loads((Path.home() / '.codex-3/bridge.json').read_text())
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def health():
    with opener.open('http://127.0.0.1:%s/health' % config['port'], timeout=3) as response:
        return json.load(response)

initial = health()
expected_transport = {'bluetooth': 'bluetooth-l2cap', 'usb': 'usb-usbmux'}[args.transport]
if initial.get('protocol_version') not in (2, 3) or not initial['ready'] or initial['transport'] != expected_transport:
    raise SystemExit('请先连接指定的 Mac 与 iPhone 转发通道。')
if initial.get('active_requests'):
    raise SystemExit('请等当前 API 请求完成后测速，以免影响正常对话。')
results = []
for kind in (('random', 'text') if args.kind == 'both' else (args.kind,)):
    for round_number in range(args.rounds):
        size = args.size_kib * 1024
        payload = os.urandom(size) if kind == 'random' else (b'data: {"type":"response.output_text.delta","delta":"hello world"}\n\n' * (size//32+1))[:size]
        if kind == 'source':
            source = b'\n'.join(path.read_bytes() for path in sorted((Path(__file__).resolve().parents[1] / 'Sources/BridgeCore').glob('*.swift')))
            payload = (source * (size // len(source) + 1))[:size]
        before = health()
        connection = http.client.HTTPConnection('127.0.0.1', config['port'], timeout=120)
        start = time.monotonic()
        connection.request('POST', '/bridge/benchmark', body=payload,
                           headers={'Authorization': 'Bearer ' + config['localToken'], 'Content-Type': 'application/octet-stream'})
        response = connection.getresponse()
        headers_at = time.monotonic()
        data = response.read(); finished = time.monotonic(); connection.close()
        if response.status != 200 or hashlib.sha256(data).digest() != hashlib.sha256(payload).digest():
            raise SystemExit('测速失败：回传数据校验不一致。')
        after = health()
        sent = after['wire_sent_bytes'] - before['wire_sent_bytes']
        received = after['wire_received_bytes'] - before['wire_received_bytes']
        if after['transport'] != expected_transport or not after['ready']:
            raise SystemExit('测速期间通道发生变化，此结果无效。')
        result = dict(protocol_version=initial['protocol_version'], transport=expected_transport, kind=kind, round=round_number + 1, bytes_each_direction=len(payload),
                      upload_seconds=round(headers_at-start, 3), download_seconds=round(finished-headers_at, 3),
                      total_seconds=round(finished-start, 3),
                      upload_kib_per_second=round(len(payload)/max(headers_at-start, 0.000001)/1024, 1),
                      download_kib_per_second=round(len(payload)/max(finished-headers_at, 0.000001)/1024, 1), wire_bytes=sent+received,
                      transport_diagnostics=after.get('transport_diagnostics', {}),
                      wire_kib_per_second=round((sent+received)/(finished-start)/1024, 1),
                      effective_kib_per_second=round(2*len(payload)/(finished-start)/1024, 1), sha256_match=True)
        results.append(result)
        if args.output: args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(result, ensure_ascii=False), flush=True)
if args.output:
    args.output.write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
print('PASS: all echoes matched SHA-256. Rates include framing, acknowledgements and scheduling; they are not PHY rates.')
