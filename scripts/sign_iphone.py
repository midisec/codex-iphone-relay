#!/usr/bin/env python3
"""Re-sign the prebuilt iPhone app with the user's own provisioning profile."""
import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


def unpack_ipa(ipa, destination):
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        if len(entries) > 1024 or sum(item.file_size for item in entries) > 100_000_000:
            raise ValueError('IPA 文件过大')
        for item in entries:
            path = PurePosixPath(item.filename)
            mode = item.external_attr >> 16
            if path.is_absolute() or '..' in path.parts or '\\' in item.filename or stat.S_ISLNK(mode):
                raise ValueError('IPA 包含不安全路径')
        archive.extractall(destination)
        for item in entries:
            path = destination / item.filename
            if path.is_file():
                path.chmod(0o755 if (item.external_attr >> 16) & 0o111 else 0o644)
    apps = list((destination / 'Payload').glob('*.app'))
    if len(apps) != 1:
        raise ValueError('IPA 必须包含一个 App')
    app = apps[0]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleExecutable') != 'BluetoothRelay':
        raise ValueError('仅支持 Bluetooth Relay 安装包')
    if (app / 'PlugIns').exists() or (app / 'Frameworks').exists():
        raise ValueError('此签名器不支持包含扩展或内嵌框架的包')
    return app, info


def signing_settings(profile, original_id, identity_listing, requested=None):
    expiration = profile.get('ExpirationDate')
    if not expiration or expiration.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise ValueError('描述文件已过期')
    if not profile.get('ProvisionedDevices'):
        raise ValueError('需要包含目标 iPhone 的 Development 或 Ad Hoc 描述文件')
    entitlements = dict(profile.get('Entitlements', {}))
    app_id = entitlements.get('application-identifier', '')
    prefix, separator, bundle = app_id.partition('.')
    if not separator or prefix not in profile.get('ApplicationIdentifierPrefix', []):
        raise ValueError('描述文件 App ID 无效')
    if '*' in bundle:
        if not bundle.endswith('*') or not original_id.startswith(bundle[:-1]):
            raise ValueError('描述文件的 Bundle ID 不匹配')
        bundle = original_id
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
        raise ValueError('Bundle ID 无效')
    entitlements['application-identifier'] = prefix + '.' + bundle
    if 'keychain-access-groups' in entitlements:
        entitlements['keychain-access-groups'] = [
            group.replace('*', bundle) for group in entitlements['keychain-access-groups']
        ]
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])}
    available = set(re.findall(r'\b[0-9A-Fa-f]{40}\b', identity_listing.upper())) & allowed
    if requested:
        available &= {requested.upper()}
    if len(available) != 1:
        raise ValueError('未找到唯一的匹配签名证书；请导入证书及私钥，或用 --identity 指定证书 SHA-1')
    return bundle, entitlements, available.pop()


def main():
    parser = argparse.ArgumentParser(description='使用自己的证书和描述文件签名预编译 IPA，无需编译源码。')
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--profile', type=Path, required=True, help='包含目标 iPhone 的 .mobileprovision')
    parser.add_argument('--identity', help='钥匙串签名证书 SHA-1；默认自动匹配')
    parser.add_argument('--output', type=Path, default=Path('BluetoothRelay-signed.ipa'))
    parser.add_argument('--device', help='签名后用 Xcode devicectl 安装到指定设备')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('签名工具仅支持 macOS')
    ipa, profile_path, output = (path.expanduser().resolve() for path in (args.ipa, args.profile, args.output))
    if output.exists():
        parser.error('输出文件已存在，请指定新的 --output 路径')
    try:
        decoded = subprocess.run(['/usr/bin/security', 'cms', '-D', '-i', str(profile_path)],
                                 check=True, capture_output=True).stdout
        profile = plistlib.loads(decoded)
        identities = subprocess.run(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'],
                                    check=True, capture_output=True, text=True).stdout
        with tempfile.TemporaryDirectory(prefix='relay-sign-') as directory:
            staging = Path(directory)
            app, info = unpack_ipa(ipa, staging)
            bundle_id, entitlements, identity = signing_settings(
                profile, info['CFBundleIdentifier'], identities, args.identity)
            info['CFBundleIdentifier'] = bundle_id
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            shutil.rmtree(app / '_CodeSignature', ignore_errors=True)
            shutil.copyfile(profile_path, app / 'embedded.mobileprovision')
            entitlement_file = staging / 'entitlements.plist'
            entitlement_file.write_bytes(plistlib.dumps(entitlements))
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--entitlements',
                            str(entitlement_file), '--generate-entitlement-der', str(app)], check=True)
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(app)], check=True)
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open('xb') as stream:
                output.chmod(0o600)
                with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
                    for path in sorted(app.rglob('*')):
                        if path.is_file():
                            archive.write(path, path.relative_to(staging))
            print('已签名：', output)
            print('签名到期：', profile['ExpirationDate'].strftime('%Y-%m-%d %H:%M UTC'))
            if args.device:
                subprocess.run(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', args.device,
                                str(app)], check=True)
    except (ValueError, OSError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        parser.exit(1, f'签名失败：{error}\n')


if __name__ == '__main__':
    main()
