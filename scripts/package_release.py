#!/usr/bin/env python3
"""Package existing Release builds; never include local configuration or signing profiles."""
import argparse
import hashlib
import importlib.metadata
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_DIRS = {'Sources', 'Tests', 'scripts', 'docs', 'iOS', '.github'}
PUBLIC_FILES = {'README.md', 'README.en.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'Package.swift',
                'Makefile', '.gitignore', '.gitattributes', '.editorconfig'}
PRIVATE_NAMES = {'bridge.json', 'auth.json', 'embedded.mobileprovision', '.DS_Store'}
PRIVATE_SUFFIXES = {'.mobileprovision', '.p12', '.p8', '.pem', '.key', '.log', '.ipa'}


def zip_tree(directory, output, prefix=''):
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(directory.rglob('*')):
            if path.is_symlink():
                raise ValueError(f'Symlink not allowed: {path.name}')
            if path.is_file():
                archive.write(path, str(Path(prefix) / path.relative_to(directory)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ios-app', type=Path, default=ROOT / '.build/ios/Build/Products/Release-iphoneos/BluetoothRelay.app')
    args = parser.parse_args()
    if sys.platform != 'darwin' or platform.machine() != 'arm64':
        parser.error('This release target requires Apple Silicon macOS')
    version = plistlib.loads((ROOT / 'iOS/BluetoothRelay/Info.plist').read_bytes())
    app_info = plistlib.loads((args.ios_app / 'Info.plist').read_bytes())
    for field in ('CFBundleVersion', 'CFBundleShortVersionString'):
        if version[field] != app_info[field]:
            parser.error('iPhone build version does not match source')
    tag = 'v' + version['CFBundleShortVersionString']
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    payload = ROOT / '.build/mac-payload.zip'
    with zipfile.ZipFile(payload, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in ('.build/manual/BluetoothCodex', '.build/manual/libBridgeCore.dylib', 'iOS/BluetoothRelay/Info.plist'):
            archive.write(ROOT / name, name)
    subprocess.run([sys.executable, '-m', 'PyInstaller', '--noconfirm', '--clean', '--onefile',
                    '--name', 'CodexRelaySetup', '--distpath', str(ROOT / '.build/release-tools'),
                    '--workpath', str(ROOT / '.build/release-pyinstaller'), '--specpath', str(ROOT / '.build'),
                    '--add-data', str(payload) + ':.', str(ROOT / 'scripts/release_entry.py')], check=True)
    outputs = []
    with tempfile.TemporaryDirectory(prefix='relay-release-') as directory:
        staging = Path(directory)
        mac = staging / 'mac'
        mac.mkdir()
        for name in ('Install.command', 'Sign-iPhone.command'):
            shutil.copy2(ROOT / 'scripts' / name, mac / name)
            (mac / name).chmod(0o755)
        shutil.copy2(ROOT / '.build/release-tools/CodexRelaySetup', mac / 'CodexRelaySetup')
        shutil.copy2(ROOT / 'LICENSE', mac / 'LICENSE')
        for source_name, target_name in [('BINARY_INSTALL.md', 'README.md'), ('BINARY_INSTALL.en.md', 'README.en.md')]:
            guide = (ROOT / 'docs' / source_name).read_text()
            guide = guide.replace('(BINARY_INSTALL.en.md)', '(README.en.md)').replace('(BINARY_INSTALL.md)', '(README.md)')
            (mac / target_name).write_text(guide)
        licenses = mac / 'Licenses'
        shutil.copytree(ROOT / 'docs/licenses', licenses)
        python_license = Path(sys.base_prefix) / f'lib/python{sys.version_info.major}.{sys.version_info.minor}/LICENSE.txt'
        shutil.copy2(python_license, licenses / 'Python.txt')
        pyinstaller = importlib.metadata.distribution('pyinstaller')
        for file in pyinstaller.files:
            if str(file).endswith('/COPYING.txt'):
                shutil.copy2(pyinstaller.locate_file(file), licenses / 'PyInstaller.txt')
                break
        else:
            raise FileNotFoundError('PyInstaller license missing')
        mac_output = dist / f'codex-relay-{tag}-macos-arm64.zip'
        zip_tree(mac, mac_output, 'Codex-Relay-' + tag)
        outputs.append(mac_output)

        iphone = staging / 'iphone/Payload/BluetoothRelay.app'
        shutil.copytree(args.ios_app, iphone)
        shutil.rmtree(iphone / '_CodeSignature', ignore_errors=True)
        (iphone / 'embedded.mobileprovision').unlink(missing_ok=True)
        binary = iphone / app_info['CFBundleExecutable']
        signed = subprocess.run(['/usr/bin/codesign', '-d', str(binary)], capture_output=True)
        if signed.returncode == 0:
            subprocess.run(['/usr/bin/codesign', '--remove-signature', str(binary)], check=True)
        for path in iphone.rglob('*'):
            if path.name in PRIVATE_NAMES or path.suffix in PRIVATE_SUFFIXES:
                raise ValueError('Private file in iPhone payload')
        ipa = dist / f'codex-relay-{tag}-ios-unsigned.ipa'
        zip_tree(staging / 'iphone', ipa)
        outputs.append(ipa)

    source = dist / f'codex-relay-{tag}-source.zip'
    listing = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=ROOT)
    with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(set(listing.decode().split('\0')) - {''}):
            relative = Path(name)
            if relative.parts[0] not in PUBLIC_DIRS and name not in PUBLIC_FILES:
                continue
            if any(part in {'.local', '.build', 'dist', '__pycache__', 'xcuserdata'} for part in relative.parts):
                continue
            if relative.name in PRIVATE_NAMES or relative.suffix in PRIVATE_SUFFIXES:
                raise ValueError('Private file in source selection')
            path = ROOT / relative
            if path.is_symlink():
                raise ValueError('Source symlink not allowed')
            archive.write(path, 'codex-relay/' + name)
    outputs.append(source)
    (dist / 'SHA256SUMS').write_text(''.join(
        hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in outputs))
    for path in outputs:
        print(path.name, path.stat().st_size, 'bytes')


if __name__ == '__main__':
    main()
