"""Exercise a frozen installer without changing the user's installed apps or profile."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import tempfile
import time
import urllib.request


def free_port():
    with socket.socket() as connection:
        connection.bind(('127.0.0.1', 0))
        return connection.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--setup', type=Path, default=Path('.build/release-tools/CodexRelaySetup'))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='relay-install-test-') as directory:
        stage = Path(directory)
        source = stage / 'source'
        source.mkdir()
        (source / 'config.toml').write_text('model="release-test"\nmodel_provider="example"\n'
            '[model_providers.example]\nbase_url="https://example.org/v1"\nwire_api="responses"\n')
        (source / 'auth.json').write_text(json.dumps({'OPENAI_API_KEY': 'release-synthetic-key'}))
        before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in source.iterdir()}
        codex = stage / "Codex ' test.app/Contents/Resources/codex"
        codex.parent.mkdir(parents=True)
        codex.write_text('#!/bin/bash\nprintf "synthetic Codex version\\n"\n')
        codex.chmod(0o755)
        local_port, relay_port = free_port(), free_port()
        install_args = [str(args.setup.resolve()), '--source', str(source), '--destination', str(stage / 'profile'),
            '--apps', str(stage / 'Applications'), '--codex-app', str(codex.parents[2]),
            '--cli-path', str(stage / 'codex3'), '--port', str(local_port)]
        env = dict(os.environ, PATH='/usr/bin:/bin:/usr/sbin:/sbin')
        for iteration in range(2):
            result = subprocess.run(install_args, check=True, capture_output=True, text=True, env=env)
            assert 'release-synthetic-key' not in result.stdout + result.stderr
            profile = json.loads((stage / 'profile/bridge.json').read_text())
            if iteration == 0:
                first = profile
            else:
                assert all(first[key] == profile[key] for key in ('pairingToken', 'localToken'))
        assert before == {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in source.iterdir()}
        assert (stage / 'profile/bridge.json').stat().st_mode & 0o777 == 0o600
        for name in ('Bluetooth Codex.app', 'Codex 3.app'):
            app = stage / 'Applications' / name
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True, capture_output=True)
            assert plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
        result = subprocess.run([str(stage / 'codex3'), '--version'], check=True, capture_output=True, text=True, env=env)
        assert result.stdout == 'synthetic Codex version\n'
        proxy = stage / 'Applications/Bluetooth Codex.app/Contents/MacOS/BluetoothCodex'
        child = subprocess.Popen([str(proxy), '--config', str(stage / 'profile/bridge.json'), '--headless',
            '--test-relay-port', str(relay_port)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        try:
            for _ in range(50):
                try:
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    with opener.open(f'http://127.0.0.1:{local_port}/health', timeout=.5) as response:
                        health = json.load(response)
                    assert health['transport'] == 'test-tcp'
                    break
                except (OSError, ValueError):
                    if child.poll() is not None:
                        raise RuntimeError(child.communicate()[1].decode())
                    time.sleep(.1)
            else:
                raise RuntimeError('Installed proxy did not start')
        finally:
            child.terminate()
            try:
                child.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.communicate()
    print('PASS: frozen install/update, source unchanged, private permissions, signing, CLI and proxy health')


if __name__ == '__main__':
    main()
