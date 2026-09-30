import hashlib, importlib.util, json, tempfile, unittest, os
from pathlib import Path
spec=importlib.util.spec_from_file_location('deployment',Path(__file__).with_name('deploy-remote.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class PublicationTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.base=Path(self.temp.name)
 def tearDown(self): self.temp.cleanup()
 def stage(self, ident, build=10001, artifact=b'zip-v1'):
  root=self.base/'staging'/ident
  catalog={'releases':[{'version':'0.1.0-beta.1','build':build}]}
  contents={'web/index.html':b'page','web/releases.json':json.dumps(catalog).encode(),'web/updates/macos/arm64/appcast.xml':f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><sparkle:version>{build}</sparkle:version></rss>'.encode(),'releases/0.1.0-beta.1/test.zip':artifact}
  files={}
  for name,data in contents.items():
   p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);files[name]={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
  return files
 def test_promotes_verified_snapshot_atomically(self):
  module.publish(self.base,'a',self.stage('a'))
  self.assertTrue((self.base/'site').is_symlink())
  self.assertEqual((self.base/'site/releases/0.1.0-beta.1/test.zip').read_bytes(),b'zip-v1')
 def test_changed_upload_leaves_live_snapshot_untouched(self):
  files=self.stage('a');(self.base/'staging/a/web/index.html').write_bytes(b'corrupt')
  with self.assertRaisesRegex(Exception,'HASH'):module.publish(self.base,'a',files)
  self.assertFalse((self.base/'site').exists())
 def test_existing_immutable_release_never_overwritten(self):
  module.publish(self.base,'a',self.stage('a'))
  with self.assertRaisesRegex(Exception,'IMMUTABLE'):module.publish(self.base,'b',self.stage('b',artifact=b'new-zip'))
  self.assertEqual((self.base/'site/releases/0.1.0-beta.1/test.zip').read_bytes(),b'zip-v1')
 def test_remote_newer_catalog_cannot_be_rolled_back(self):
  module.publish(self.base,'a',self.stage('a',10002))
  with self.assertRaisesRegex(Exception,'NEWER'):module.publish(self.base,'b',self.stage('b',10001))
 @unittest.skipIf(os.name == 'nt', 'POSIX mode bits are checked on the Linux publication host')
 def test_private_staging_permissions_become_public_readable(self):
  files=self.stage('a')
  root=self.base/'staging/a'
  for p in root.rglob('*'): p.chmod(0o700 if p.is_dir() else 0o600)
  module.publish(self.base,'a',files)
  self.assertEqual((self.base/'site').resolve().stat().st_mode & 0o777,0o755)
  self.assertEqual((self.base/'site/releases/0.1.0-beta.1').stat().st_mode & 0o777,0o755)
  self.assertEqual((self.base/'site/releases/0.1.0-beta.1/test.zip').stat().st_mode & 0o777,0o644)
 def test_path_traversal_is_rejected(self):
  files=self.stage('a');files['../escape']={'bytes':0,'sha256':'a'*64}
  with self.assertRaisesRegex(Exception,'PATH'):module.publish(self.base,'a',files)
 @unittest.skipIf(os.name == 'nt', 'Replacing a directory symlink requires the Linux publication host')
 def test_mac_republication_preserves_windows_feed_and_download(self):
  module.publish(self.base,'a',self.stage('a'))
  live=self.base/'site'
  (live/'updates/windows/x64').mkdir(parents=True)
  (live/'updates/windows/x64/release.json').write_text('signed Windows feed')
  (live/'windows').mkdir()
  (live/'windows/index.html').write_text('Windows installer')
  files=self.stage('b')
  page=self.base/'staging/b/web/index.html'
  page.write_text('<main>New Mac page</main>')
  files['web/index.html']=module.digest(page)
  module.publish(self.base,'b',files)
  self.assertEqual((live/'updates/windows/x64/release.json').read_text(),'signed Windows feed')
  self.assertEqual((live/'windows/index.html').read_text(),'Windows installer')
  self.assertIn('id="windows-download"',(live/'index.html').read_text())
if __name__=='__main__':unittest.main()
