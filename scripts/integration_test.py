#!/usr/bin/env python3
"""Exercise the exact proxy and phone HTTP engine over an explicitly labelled test transport.

Default: local fixtures only. --real-api: also one minimal paid Responses request using
Codex 2's imported provider, with its credentials confined to private temp files.
This does NOT constitute a Bluetooth/iPhone hardware test.
"""
import argparse
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / '.build/manual'
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def private_json(path, value):
    fd = os.open(path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(value, f)


def wait_for(test, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = test()
            if result:
                return result
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(.1)
    raise AssertionError('Timed out waiting for test service')


def health(port):
    with OPENER.open(f'http://127.0.0.1:{port}/health', timeout=1) as response:
        return json.load(response)


def call(config, body=None, path='/responses', method='POST', token=True, headers=None):
    connection = http.client.HTTPConnection('127.0.0.1', config['port'], timeout=120)
    values = {'Content-Type': 'application/json'}
    if token:
        values['Authorization'] = 'Bearer ' + config['localToken']
    values.update(headers or {})
    connection.request(method, path, body=body, headers=values)
    return connection, connection.getresponse()


@contextlib.contextmanager
def running(config, directory, allow_loopback=True, mismatch=False):
    relay_config = dict(config)
    if mismatch:
        relay_config['pairingToken'] = secrets.token_hex(32)
    relay_file = directory / 'relay.json'
    config_file = directory / 'bridge.json'
    private_json(relay_file, relay_config); private_json(config_file, config)
    relay_port = free_port()
    with (directory / 'relay.log').open('w') as relay_log, (directory / 'mac.log').open('w') as mac_log:
        relay_args = [str(BIN / 'RelayHarness'), '--config', str(relay_file), '--port', str(relay_port)]
        if allow_loopback:
            relay_args += ['--allow-loopback-upstream']
        relay = subprocess.Popen(relay_args, stdout=relay_log, stderr=relay_log)
        mac = None
        try:
            wait_for(lambda: 'ready' in (directory / 'relay.log').read_text())
            mac = subprocess.Popen([str(BIN / 'BluetoothCodex'), '--headless', '--config', str(config_file), '--test-relay-port', str(relay_port)], stdout=mac_log, stderr=mac_log)
            wait_for(lambda: health(config['port']))
            if not mismatch:
                wait_for(lambda: health(config['port'])['ready'])
            yield relay, mac, config_file
        finally:
            for process in [mac, relay]:
                if process and process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()


class Fixture(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    received = []
    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass
    def log_message(self, *args):
        pass
    def reply(self, status, body, headers=None):
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        try:
            self.wfile.write(body); self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_GET(self):
        self.received.append((self.path, dict(self.headers), b''))
        self.reply(200, b'{"data":[]}', {'Content-Type': 'application/json'})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.received.append((self.path, dict(self.headers), body))
        try:
            mode = json.loads(body).get('mode', 'stream')
        except (ValueError, UnicodeError):
            mode = 'echo'
        if mode == 'error':
            self.reply(429, b'{"error":{"message":"rate limited"}}', {'Content-Type': 'application/json', 'Retry-After': '7'})
        elif mode == 'redirect':
            self.reply(302, b'redirect rejected', {'Location': f'http://127.0.0.1:{self.server.server_port}/leak'})
        elif mode == 'echo':
            self.reply(200, body, {'Content-Type': 'application/octet-stream'})
        elif mode == 'burst':
            self.reply(200, b'x' * (2 * 1024 * 1024), {'Content-Type': 'application/octet-stream'})
        elif mode in ('terminal-open', 'failed-open', 'incomplete-open', 'truncated'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            event = {'terminal-open': 'completed', 'failed-open': 'failed', 'incomplete-open': 'incomplete'}.get(mode)
            payload = b'data: {"type":"response.output_text.delta","delta":"OK"}\n\n'
            if event:
                payload += ('data: {"type":"response.' + event + '"}\n\n').encode()
            self.wfile.write(('%x\r\n' % len(payload)).encode() + payload + b'\r\n'); self.wfile.flush()
            if mode == 'truncated':
                self.close_connection = True
            else:
                # Keep upstream HTTP open even though the SSE response has ended.
                time.sleep(5)
                self.wfile.write(b'0\r\n\r\n'); self.wfile.flush()
        else:
            first = 'event: response.output_text.delta\ndata: {"delta":"蓝牙测试"}\n\n'.encode()
            second = b'event: response.completed\ndata: {"type":"response.completed"}\n\n'
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(first) + len(second)))
            self.end_headers()
            try:
                self.wfile.write(first); self.wfile.flush(); time.sleep(.6)
                self.wfile.write(second); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass


def fixtures(directory):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    config = dict(upstreamBase=f'http://127.0.0.1:{server.server_port}/v1', apiKey='fixture-upstream-key',
                  localToken=secrets.token_hex(32), pairingToken=secrets.token_hex(32), model='fixture-model', port=free_port())
    try:
        with running(config, directory) as (relay, mac, _):
            assert health(config['port'])['transport'] == 'test-tcp'
            connection, response = call(config, b'{}', token=False)
            assert response.status == 401; response.read(); connection.close()
            print('PASS: local proxy authentication')
            connection, response = call(config, b'{}', path='/forbidden')
            assert response.status == 400; response.read(); connection.close()
            print('PASS: route allowlist')
            connection, response = call(config, path='/models', method='GET')
            assert response.status == 200 and json.loads(response.read()) == {'data': []}; connection.close()
            assert Fixture.received[-1][0] == '/v1/models'
            assert Fixture.received[-1][1]['Authorization'] == 'Bearer fixture-upstream-key'
            print('PASS: source base URL path and upstream credential substitution')
            start = time.monotonic()
            connection, response = call(config, b'{"mode":"stream"}')
            first = response.readline()
            assert first == b'event: response.output_text.delta\n' and time.monotonic() - start < .5
            assert '蓝牙测试' in response.read().decode(); connection.close()
            print('PASS: SSE forwarded before upstream completion; UTF-8 preserved')
            body = (bytes(range(256)) * 1024) + '中文'.encode()
            connection, response = call(config, body, headers={'Content-Encoding': 'identity', 'Cookie': 'must-not-forward'})
            assert response.status == 200 and response.read() == body; connection.close()
            assert 'Cookie' not in Fixture.received[-1][1]
            print('PASS: fragmented 256 KiB binary request and response')
            probe = os.urandom(256 * 1024)
            count = len(Fixture.received)
            connection, response = call(config, probe, path='/bridge/benchmark')
            assert response.status == 200 and response.read() == probe; connection.close()
            assert len(Fixture.received) == count
            connection, response = call(config, b'x' * (4*1024*1024+1), path='/bridge/benchmark')
            assert response.status == 413; response.read(); connection.close()
            print('PASS: authenticated bounded speed probe echoes random data without upstream requests')
            connection, response = call(config, b'{"mode":"burst"}')
            assert response.status == 200
            time.sleep(.2)
            assert response.read() == b'x' * (2 * 1024 * 1024); connection.close()
            print('PASS: 2 MiB burst response with acknowledgement flow control')
            for mode in ('terminal-open', 'failed-open', 'incomplete-open'):
                start = time.monotonic()
                connection, response = call(config, json.dumps({'mode': mode}).encode())
                content = response.read(); connection.close()
                assert b'"delta":"OK"' in content and time.monotonic() - start < 2
            print('PASS: terminal completed/failed/incomplete event releases client before HTTP EOF')
            for _ in range(4):
                connection, response = call(config, b'{"mode":"terminal-open"}')
                assert b'response.completed' in response.read(); connection.close()
            wait_for(lambda: not health(config['port'])['active_requests'])
            assert health(config['port'])['recent_requests'][-1]['terminal_event'] == 'response.completed'
            print('PASS: four follow-ups finish without occupying request slots')
            connection, response = call(config, b'{"mode":"truncated"}')
            try:
                response.read()
                raise AssertionError('Truncated upstream SSE incorrectly succeeded')
            except http.client.IncompleteRead:
                pass
            connection.close()
            print('PASS: missing terminal event with broken HTTP fails instead of inventing completion')
            connection, response = call(config, b'{"mode":"error"}')
            assert response.status == 429 and response.getheader('Retry-After') == '7'
            assert json.loads(response.read())['error']['message'] == 'rate limited'; connection.close()
            print('PASS: upstream error status, headers and body preserved')
            connection, response = call(config, b'{"mode":"redirect"}')
            assert response.status == 302; response.read(); connection.close()
            assert all('/leak' not in entry[0] for entry in Fixture.received)
            print('PASS: redirects never forward API credentials')
            connection, response = call(config, b'{"mode":"stream"}')
            assert response.readline().startswith(b'event:')
            relay.terminate(); relay.wait(timeout=5)
            try:
                response.read()
                raise AssertionError('Interrupted SSE incorrectly succeeded')
            except http.client.IncompleteRead:
                pass
            finally:
                connection.close()
            wait_for(lambda: not health(config['port'])['ready'])
            connection, response = call(config, b'{}')
            assert response.status == 503; response.read(); connection.close()
            print('PASS: interrupted SSE fails and disconnected relay returns 503')
        config['port'] = free_port()
        with running(config, directory, mismatch=True):
            time.sleep(.2)
            assert not health(config['port'])['ready']
            connection, response = call(config, b'{}')
            assert response.status == 503; response.read(); connection.close()
            print('PASS: incorrect pairing secret cannot open relay')
    finally:
        server.shutdown(); server.server_close()


def real_api(directory, source, codex_smoke=False):
    config = json.loads(source.read_text())
    config['port'] = free_port()
    with running(config, directory, allow_loopback=False):
        body = json.dumps({'model': config['model'], 'instructions': 'Reply with OK only.',
                          'input': [{'role': 'user', 'content': [{'type': 'input_text', 'text': 'Reply with OK only.'}]}],
                          'stream': True, 'store': False}).encode()
        start = time.monotonic()
        connection, response = call(config, body)
        payload = response.read(); connection.close()
        # Print status and the minimal test answer only, never headers or auth values.
        if response.status != 200:
            print('REAL API RESULT: HTTP', response.status)
            try:
                error = json.loads(payload).get('error', {})
                print('Error type:', error.get('type'), 'code:', error.get('code'))
            except ValueError:
                pass
            raise AssertionError('Real API did not return HTTP 200')
        events = []
        for line in payload.decode().splitlines():
            if line.startswith('data: '):
                try:
                    events.append(json.loads(line[6:]))
                except ValueError:
                    pass
        completed = any(event.get('type') == 'response.completed' for event in events)
        text = ''.join(event.get('delta', '') for event in events if event.get('type') == 'response.output_text.delta')
        assert completed and 'OK' in text, 'Real API SSE did not complete'
        print(f'PASS: real Codex 2 API over relay engine; model={config["model"]}; HTTP 200; completed={completed}; answer={text[:80]!r}; seconds={time.monotonic() - start:.1f}')
        if codex_smoke:
            codex_home = directory / 'codex-home'
            codex_home.mkdir(mode=0o700)
            original = source.parent / 'config.toml'
            config_text = original.read_text().replace(f'127.0.0.1:{json.loads(source.read_text())["port"]}', f'127.0.0.1:{config["port"]}')
            (codex_home / 'config.toml').write_text(config_text)
            private_json(codex_home / 'auth.json', {'OPENAI_API_KEY': config['localToken']})
            output = directory / 'codex-answer.txt'
            work = directory / 'workspace'; work.mkdir()
            # Actual Codex process can reach localhost only. iPhone engine runs outside this sandbox.
            profile = directory / 'local-only.sb'
            profile.write_text('(version 1)\n(allow default)\n(deny network-outbound)\n(allow network-outbound (remote ip "localhost:*"))\n')
            env = dict(os.environ, CODEX_HOME=str(codex_home))
            command = ['/usr/bin/sandbox-exec', '-f', str(profile), '/Applications/ChatGPT.app/Contents/Resources/codex',
                       'exec', '--strict-config', '--ephemeral', '--skip-git-repo-check', '-s', 'read-only', '-C', str(work),
                       '-o', str(output), 'Reply exactly OK. Do not call tools.']
            result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180)
            if result.returncode != 0:
                print(result.stderr.decode(errors='replace')[-2500:])
                raise AssertionError(f'Codex smoke test failed with exit {result.returncode}')
            answer = output.read_text().strip()
            assert answer == 'OK', f'Unexpected Codex smoke answer: {answer[:80]!r}'
            print('PASS: actual Codex CLI with external networking DENIED; model request through local relay; answer=OK')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--real-api', action='store_true')
    parser.add_argument('--codex-smoke', action='store_true', help='Also test Codex with external networking denied; requires --real-api')
    parser.add_argument('--config', type=Path, default=Path.home() / '.codex-3/bridge.json')
    args = parser.parse_args()
    if args.codex_smoke and not args.real_api:
        parser.error('--codex-smoke requires --real-api')
    with tempfile.TemporaryDirectory(prefix='bluetoothcodex-test-') as tmp:
        directory = Path(tmp)
        fixtures(directory)
        if args.real_api:
            real_api(directory, args.config, args.codex_smoke)
    print('Integration checks passed. Transport was TEST TCP, not physical Bluetooth.')


if __name__ == '__main__':
    main()
