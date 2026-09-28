"""Installer smoke checks using temporary profiles and mocked code signing."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('relay_install', Path(__file__).resolve().parents[1] / 'scripts/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerChecks(unittest.TestCase):
    def test_explicit_app_and_invalid_path(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'Custom Codex.app'
            binary = app / 'Contents/Resources/codex'
            binary.parent.mkdir(parents=True)
            binary.write_text('test executable')
            self.assertEqual(installer.resolve_codex_app(app), app.resolve())
            with self.assertRaises(ValueError):
                installer.resolve_codex_app(Path(directory) / 'Missing.app')

    def test_isolated_install_and_update_preserve_tokens(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            source.mkdir()
            source_config = 'model="test-model"\nmodel_provider="test"\n[model_providers.test]\nbase_url="https://api.example.org/v1"\nwire_api="responses"\n'
            (source / 'config.toml').write_text(source_config)
            (source / 'auth.json').write_text(json.dumps({'OPENAI_API_KEY': 'synthetic-upstream-key'}))
            app = root / "App with spaces' quote.app"
            binary = app / 'Contents/Resources/codex'
            binary.parent.mkdir(parents=True)
            binary.write_text('test executable')
            build = root / '.build/manual'
            build.mkdir(parents=True)
            for name in ('BluetoothCodex', 'libBridgeCore.dylib'):
                (build / name).write_bytes(b'test binary')
            info = root / 'iOS/BluetoothRelay/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '1.3', 'CFBundleVersion': '6'}))
            destination = root / 'destination'
            apps = root / 'Applications'
            args = ['install.py', '--source', str(source), '--destination', str(destination),
                    '--apps', str(apps), '--codex-app', str(app), '--skip-build']
            output = io.StringIO()
            with patch.object(installer, 'ROOT', root), patch.object(Path, 'home', return_value=root), \
                 patch.object(sys, 'argv', args), patch.object(sys, 'platform', 'darwin'), \
                 patch.object(installer.subprocess, 'run') as run, contextlib.redirect_stdout(output):
                installer.main()
                first = json.loads((destination / 'bridge.json').read_text())
                installer.main()
                second = json.loads((destination / 'bridge.json').read_text())
                self.assertTrue(all(call.args[0][0] == 'codesign' for call in run.call_args_list))
            self.assertEqual(first['pairingToken'], second['pairingToken'])
            self.assertEqual(first['localToken'], second['localToken'])
            self.assertEqual((source / 'config.toml').read_text(), source_config)
            self.assertEqual((destination / 'bridge.json').stat().st_mode & 0o777, 0o600)
            self.assertNotIn('synthetic-upstream-key', output.getvalue())
            local_auth = json.loads((destination / 'auth.json').read_text())
            self.assertEqual(local_auth['OPENAI_API_KEY'], first['localToken'])
            bundle_info = plistlib.loads((apps / 'Bluetooth Codex.app/Contents/Info.plist').read_bytes())
            self.assertEqual(bundle_info['CFBundleShortVersionString'], '1.3')
            self.assertEqual((apps / 'Bluetooth Codex.app/Contents/MacOS/BluetoothCodex').stat().st_mode & 0o777, 0o755)
            for script in [root / '.local/bin/codex3', apps / 'Codex 3.app/Contents/MacOS/Codex3Launcher']:
                subprocess.run(['bash', '-n', str(script)], check=True)

    def test_reimport_supersedes_synced_phone_and_preserves_it(self):
        phone = dict(credentials=dict(baseURL='https://phone.example.org', apiKey='synthetic', model='phone'),
                     revision=dict(milliseconds=9999999999999, logical=7, id='phone'))
        previous = dict(apiSettings=dict(phone=phone, selection='phone',
                        selectionRevision=dict(milliseconds=9999999999999, logical=8, id='choice')))
        result = installer.imported_settings(previous, 'https://mac.example.org', 'new-key', 'mac')
        self.assertEqual(result['phone'], phone)
        self.assertEqual(result['selection'], 'automatic')
        self.assertEqual(result['computer']['revision']['logical'], 9)
        self.assertEqual(result['selectionRevision']['logical'], 10)

    def test_private_write_is_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'private/config.json'
            installer.private_write(path, '{}\n')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.read_text(), '{}\n')


if __name__ == '__main__':
    unittest.main()
