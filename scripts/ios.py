#!/usr/bin/env python3
"""Build and install the iPhone app with Apple's tools, without changing global Xcode selection."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'iOS/BluetoothRelay.xcodeproj'
DERIVED = ROOT / '.build/ios'


def resolve_xcode(requested=None):
    if requested:
        candidates = [Path(requested).expanduser()]
    else:
        selected = subprocess.run(['xcode-select', '-p'], capture_output=True, text=True)
        candidates = [Path(selected.stdout.strip())] if selected.returncode == 0 else []
        candidates += sorted(Path('/Applications').glob('Xcode*.app'))
        candidates += sorted((Path.home() / 'Applications').glob('Xcode*.app'))
    for candidate in candidates:
        developer = candidate / 'Contents/Developer' if candidate.suffix == '.app' else candidate
        if (developer / 'usr/bin/xcodebuild').is_file():
            return developer
    raise RuntimeError('没有找到完整 Xcode。请安装支持当前 Mac 和 iPhone 的 Xcode，或用 --xcode 指定路径；见 iOS/INSTALL.md。')


def apple(args, env, capture=False):
    return subprocess.run(args, env=env, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def devices(env):
    with tempfile.TemporaryDirectory(prefix='codex-ios-devices-') as tmp:
        output = Path(tmp) / 'devices.json'
        apple(['xcrun', 'devicectl', 'list', 'devices', '--json-output', str(output)], env, capture=True)
        data = json.loads(output.read_text())
    result = []
    for device in data.get('result', {}).get('devices', []):
        properties = device.get('deviceProperties', {})
        hardware = device.get('hardwareProperties', {})
        if hardware.get('platform') != 'iOS':
            continue
        if device.get('connectionProperties', {}).get('pairingState') not in (None, 'paired'):
            continue
        result.append(dict(identifier=device['identifier'], udid=hardware.get('udid'), name=properties.get('name', 'iPhone'),
                           version=properties.get('osVersionNumber', '未知'),
                           developer_mode=properties.get('developerModeStatus', '未知')))
    return result


def select_device(found, requested):
    if requested:
        for device in found:
            if requested in (device['identifier'], device['name']):
                return device
        raise RuntimeError('指定设备不在已配对 iPhone 列表中，请检查数据线和信任提示。')
    if len(found) != 1:
        raise RuntimeError('没有找到唯一的已配对 iPhone；请连接手机并信任此 Mac，或用 --device 指定设备名称。')
    return found[0]


def resolve_team(requested):
    if requested:
        return requested
    # Read only Xcode's public team metadata, never account credentials.
    result = subprocess.run(['defaults', 'read', 'com.apple.dt.Xcode', 'IDEProvisioningTeamByIdentifier'],
                            capture_output=True, text=True)
    teams = set(re.findall(r'\bteamID\s*=\s*"?([A-Z0-9]{10})"?\s*;', result.stdout))
    if result.returncode == 0 and len(teams) == 1:
        return teams.pop()
    raise RuntimeError('无法确定唯一 Apple 开发团队，请在 Xcode 登录账号，或用 --team 指定 10 位团队 ID。')


def check_device_image(env, device):
    command = ['xcrun', 'devicectl', 'device', 'info', 'ddiServices',
               '--device', device['identifier'], '--timeout', '30']
    with tempfile.TemporaryDirectory(prefix='codex-ios-ddi-') as tmp:
        output = Path(tmp) / 'ddi.json'
        apple(command + ['--json-output', str(output)], env, capture=True)
        metadata = json.loads(output.read_text()).get('result', {}).get('ddiMetadata', {})
    if not metadata.get('isUsable') or not metadata.get('contentIsCompatible'):
        raise RuntimeError('Apple 工具报告当前开发镜像不兼容或不可用，未继续安装。')


def prepare_device(env, device):
    if device.get('developer_mode') == 'disabled':
        raise RuntimeError('请先在 iPhone 设置 → 隐私与安全性中开启开发者模式，并重启确认。')
    try:
        check_device_image(env, device)
    except subprocess.CalledProcessError as error:
        details = (error.stdout or '') + (error.stderr or '')
        helper = ROOT / '.local/ios-tools/bin/python'
        if '12040' not in details or not helper.exists() or not device.get('udid'):
            raise RuntimeError('手机开发镜像尚不可用；请解锁手机，并按 iOS/INSTALL.md 的新机型设备支持说明处理。') from error
        print('Xcode 自带开发镜像无法挂载，使用已安装的辅助工具准备兼容镜像。', flush=True)
        mobile_env = dict(env)
        mobile_env['NO_PROXY'] = env.get('NO_PROXY', '') + ',.apple.com'
        mobile_env['no_proxy'] = mobile_env['NO_PROXY']
        apple([str(helper), '-m', 'pymobiledevice3', 'mounter', 'auto-mount',
               '--udid', device['udid']], mobile_env)
        # The Apple tool must confirm that the mounted image is usable.
        check_device_image(env, device)
    print('iPhone 开发镜像服务已就绪。', flush=True)


def build(env, args, device=None):
    command = ['xcodebuild', '-project', str(PROJECT), '-configuration', args.configuration]
    if device:
        if not device.get('udid'):
            raise RuntimeError('Apple 设备列表尚未提供 UDID，请先在 Xcode 中完成设备配对。')
        if device.get('developer_mode') == 'disabled':
            raise RuntimeError('请在 iPhone 设置 → 隐私与安全性中打开开发者模式，并按手机提示重启确认。')
        if not args.team or not re.fullmatch('[A-Z0-9]{10}', args.team):
            raise RuntimeError('真机安装需要 --team TEAM_ID（10 位 Apple 开发团队 ID）；可在 Xcode 中选择 Personal Team。')
        command += ['-scheme', 'BluetoothRelay', '-derivedDataPath', str(DERIVED),
                    '-destination', 'id=' + device['udid'], '-allowProvisioningUpdates',
                    '-allowProvisioningDeviceRegistration', 'CODE_SIGN_STYLE=Automatic', 'DEVELOPMENT_TEAM=' + args.team]
    else:
        # Building a target directly uses the bundled device SDK without requiring
        # Xcode's optional simulator runtime or a run destination to be enabled.
        command += ['-target', 'BluetoothRelay', '-sdk', 'iphoneos', 'CODE_SIGNING_ALLOWED=NO',
                    'SYMROOT=' + str(DERIVED / 'Build/Products'),
                    'OBJROOT=' + str(DERIVED / 'Build/Intermediates.noindex')]
    if args.bundle_id:
        if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', args.bundle_id):
            raise RuntimeError('Bundle ID 格式无效。')
        command += ['PRODUCT_BUNDLE_IDENTIFIER=' + args.bundle_id]
    apple(command + ['build'], env)
    app = DERIVED / ('Build/Products/' + args.configuration + '-iphoneos/BluetoothRelay.app')
    if not app.exists():
        raise RuntimeError('构建完成后没有找到预期的 BluetoothRelay.app。')
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['doctor', 'build', 'prepare-device', 'install'])
    parser.add_argument('--xcode', help='完整 Xcode.app 路径，可覆盖当前命令行工具选择')
    parser.add_argument('--team', help='Apple 开发团队 ID；install 默认使用 Xcode 中唯一的团队')
    parser.add_argument('--device', help='已配对的设备名称或标识符')
    parser.add_argument('--bundle-id', help='可选的个人唯一 Bundle Identifier')
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release', help='默认安装经过优化的 Release 构建')
    args = parser.parse_args()
    try:
        developer = resolve_xcode(args.xcode)
        env = dict(os.environ, DEVELOPER_DIR=str(developer))
        print('使用 Xcode:', developer.parent.parent, flush=True)
        apple(['xcodebuild', '-version'], env)
        if args.action == 'doctor':
            apple(['xcodebuild', '-showsdks'], env)
            found = devices(env)
            print('已配对 iPhone 数量:', len(found))
            for device in found:
                print('设备:', device['name'], 'iOS:', device['version'], '开发者模式:', device['developer_mode'])
            return
        if args.action == 'install':
            args.team = resolve_team(args.team)
        device = select_device(devices(env), args.device) if args.action in ('install', 'prepare-device') else None
        if device:
            prepare_device(env, device)
            if args.action == 'prepare-device':
                return
        app = build(env, args, device)
        if not device:
            print('iPhone App 编译成功（未签名，尚不能安装）:', app)
            return
        # Require a real development provisioning profile before any device installation.
        if not (app / 'embedded.mobileprovision').exists():
            raise RuntimeError('构建产物缺少 provisioning profile，未尝试安装未签名 App。')
        apple(['codesign', '--verify', '--deep', '--strict', str(app)], env)
        with (app / 'Info.plist').open('rb') as stream:
            identifier = plistlib.load(stream)['CFBundleIdentifier']
        apple(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device['identifier'], str(app)], env)
        apple(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device['identifier'], identifier], env)
        print('iPhone 安装及启动命令成功。请保持 App 在前台，扫描 Mac 二维码并点击开始转发。')
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        print('Apple 工具执行失败。请按输出完成 Xcode 组件安装、Apple ID 登录、设备信任或开发者模式设置后重试。', file=sys.stderr)
        raise SystemExit(error.returncode or 1)
    except RuntimeError as error:
        raise SystemExit(str(error))


if __name__ == '__main__':
    main()
