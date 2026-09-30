import base64
import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path

spec = importlib.util.spec_from_file_location('windows_publish', Path(__file__).with_name('deploy-windows-remote.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WindowsPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        snapshot = self.base / 'snapshots' / 'original'
        (snapshot / 'updates/macos/arm64').mkdir(parents=True)
        (snapshot / 'updates/macos/arm64/appcast.xml').write_text('original Mac feed')
        (snapshot / 'index.html').write_text('<main>Mac download</main>')
        (self.base / 'site').symlink_to(snapshot, target_is_directory=True)

    def tearDown(self):
        self.temp.cleanup()

    def stage(self, version='0.1.0-windows.2'):
        ident = str(uuid.uuid4())
        root = self.base / 'staging' / ident
        root.mkdir(parents=True)
        data = b'test installer'
        name = f'RecordReady-{version}-x64.exe'
        release = {'version': version, 'platform': 'win32', 'arch': 'x64', 'file': {'name': name, 'size': len(data), 'sha512': base64.b64encode(hashlib.sha512(data).digest()).decode()}}
        envelope = json.dumps({'payload': base64.b64encode(json.dumps(release).encode()).decode(), 'signature': 'client verifies Ed25519 before upload'})
        contents = {name: data, name + '.blockmap': b'map', 'release.json': envelope.encode(), 'inventory.json': b'{}', 'index.html': b'Windows download'}
        for filename, value in contents.items():
            (root / filename).write_bytes(value)
        return {'id': ident, 'version': version, 'files': {name: module.digest(root / name) for name in contents}}

    def test_corrupt_upload_does_not_change_live_site(self):
        payload = self.stage()
        (self.base / 'staging' / payload['id'] / 'index.html').write_text('tampered')
        with self.assertRaisesRegex(RuntimeError, 'HASH_MISMATCH'):
            module.publish(self.base, payload)
        self.assertEqual((self.base / 'site/index.html').read_text(), '<main>Mac download</main>')

    def test_traversal_is_rejected(self):
        payload = self.stage()
        payload['files']['../escape'] = {}
        with self.assertRaisesRegex(RuntimeError, 'INVALID_FILE_NAME'):
            module.publish(self.base, payload)

    def test_signed_artifact_digest_is_checked_independently_of_upload_hash(self):
        payload = self.stage()
        name = f'RecordReady-{payload["version"]}-x64.exe'
        path = self.base / 'staging' / payload['id'] / name
        path.write_bytes(b'changed package')
        payload['files'][name] = module.digest(path)
        with self.assertRaisesRegex(RuntimeError, 'SIGNED_PAYLOAD_HASH_MISMATCH'):
            module.publish(self.base, payload)

    def test_rollback_is_rejected(self):
        newer = self.stage('0.1.0-windows.3')
        feed = self.base / 'site/updates/windows/x64/release.json'
        feed.parent.mkdir(parents=True)
        feed.write_bytes((self.base / 'staging' / newer['id'] / 'release.json').read_bytes())
        with self.assertRaisesRegex(RuntimeError, 'MUST_INCREASE'):
            module.publish(self.base, self.stage())

    def test_existing_release_cannot_be_replaced(self):
        payload = self.stage()
        target = self.base / 'releases/windows' / payload['version']
        target.mkdir(parents=True)
        (target / 'other.exe').write_bytes(b'keep')
        with self.assertRaisesRegex(RuntimeError, 'IMMUTABLE_VERSION_CHANGED'):
            module.publish(self.base, payload)

    @unittest.skipIf(os.name == 'nt', 'Atomic replacement of directory symlinks must run on the Linux server')
    def test_promotion_preserves_mac_and_retains_old_windows_packages(self):
        module.publish(self.base, self.stage('0.1.0-windows.1'))
        module.publish(self.base, self.stage('0.1.0-windows.2'))
        self.assertEqual((self.base / 'site/updates/macos/arm64/appcast.xml').read_text(), 'original Mac feed')
        for version in ('1', '2'):
            self.assertEqual((self.base / f'site/updates/windows/x64/RecordReady-0.1.0-windows.{version}-x64.exe').read_bytes(), b'test installer')
        self.assertEqual((self.base / 'site/index.html').read_text().count('id="windows-download"'), 1)


if __name__ == '__main__':
    unittest.main()
