"""Check provisioning selection and reject unsafe release archives."""
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('sign_iphone', Path(__file__).resolve().parents[1] / 'scripts/sign_iphone.py')
signer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signer)


class SigningChecks(unittest.TestCase):
    def profile(self, app_id='TEAM.com.example.relay'):
        cert = b'synthetic-certificate'
        digest = hashlib.sha1(cert).hexdigest().upper()
        return dict(ExpirationDate=datetime.now(timezone.utc) + timedelta(days=2),
                    ApplicationIdentifierPrefix=['TEAM'], ProvisionedDevices=['synthetic-device'],
                    DeveloperCertificates=[cert], Entitlements={
                        'application-identifier': app_id, 'keychain-access-groups': ['TEAM.*']}), digest

    def test_uses_profile_bundle_and_matches_certificate(self):
        profile, identity = self.profile()
        bundle, entitlements, chosen = signer.signing_settings(profile, 'old.relay', identity)
        self.assertEqual(bundle, 'com.example.relay')
        self.assertEqual(entitlements['keychain-access-groups'], ['TEAM.com.example.relay'])
        self.assertEqual(chosen, identity)
        with self.assertRaises(ValueError):
            signer.signing_settings(profile, 'old.relay', '0' * 40)

    def test_expiry_device_and_wildcard_validation(self):
        profile, identity = self.profile('TEAM.com.example.*')
        self.assertEqual(signer.signing_settings(profile, 'com.example.relay', identity)[0], 'com.example.relay')
        with self.assertRaises(ValueError):
            signer.signing_settings(profile, 'other.relay', identity)
        profile['ExpirationDate'] = datetime.now(timezone.utc) - timedelta(days=1)
        with self.assertRaises(ValueError):
            signer.signing_settings(profile, 'com.example.relay', identity)
        profile, identity = self.profile()
        profile['ProvisionedDevices'] = []
        with self.assertRaises(ValueError):
            signer.signing_settings(profile, 'com.example.relay', identity)

    def test_rejects_traversal_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for filename, mode in [('Payload/../../escape', 0o100644), ('Payload/link', 0o120777)]:
                ipa = root / 'bad.ipa'
                with zipfile.ZipFile(ipa, 'w') as archive:
                    entry = zipfile.ZipInfo(filename)
                    entry.external_attr = mode << 16
                    archive.writestr(entry, 'invalid')
                with self.assertRaises(ValueError):
                    signer.unpack_ipa(ipa, root / 'extract')

    def test_preserves_executable_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ipa = root / 'app.ipa'
            with zipfile.ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/BluetoothRelay.app/Info.plist', plistlib.dumps({
                    'CFBundleExecutable': 'BluetoothRelay', 'CFBundleIdentifier': 'com.example.relay'}))
                entry = zipfile.ZipInfo('Payload/BluetoothRelay.app/BluetoothRelay')
                entry.external_attr = 0o100755 << 16
                archive.writestr(entry, b'synthetic executable')
            app, _ = signer.unpack_ipa(ipa, root / 'extract')
            self.assertEqual((app / 'BluetoothRelay').stat().st_mode & 0o777, 0o755)


if __name__ == '__main__':
    unittest.main()
