"""Owned-file LAN protocol and real Swift importer checks with tiny synthetic files."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('owned_content', ROOT/'tools/serve_owned_content.py')
server_api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server_api)

DRIVER = '''import Foundation
@main struct Check {
 @MainActor static func main() async throws {
  let importer = PortalContentImporter()
  do {
   try await importer.run(manifestURL: URL(string: CommandLine.arguments[1])!, documents: URL(fileURLWithPath: CommandLine.arguments[2],isDirectory:true))
  } catch {
   fputs("IMPORT_ERROR \\(error.localizedDescription)\\n",stderr)
   exit(2)
  }
  print(importer.status)
  precondition(importer.completedBytes == importer.totalBytes)
  for path in ["../escape","portal2-userdata/save.sav","/etc/passwd","game/portal2/../../escape","game/portal2//bad","game/portal2\\\\bad"] {
   do { try PortalContentImporter.checkPath(path); fatalError("unsafe path accepted") }
   catch is PortalContentImportError {}
  }
 }
}
'''


class OwnedContentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='p2-owned-test-')
        self.root = Path(self.temp.name)
        self.sources = self.root/'sources'
        self.payloads = {'prep/layout.json': b'{}', 'linux/portal2_linux': b'fixture-linux',
                         'game/portal2/pak01_dir.vpk': bytes(range(256))*512}
        for name, data in self.payloads.items():
            p = self.sources/name
            p.parent.mkdir(parents=True,exist_ok=True)
            p.write_bytes(data)
        self.roots = server_api.source_roots(self.sources/'game', self.sources/'linux', self.sources/'prep')
        self.server, self.url, self.manifest = server_api.prepare(self.roots)
        self.thread = threading.Thread(target=self.server.serve_forever,daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def test_manifest_auth_range_and_finite_paths(self):
        with urllib.request.urlopen(self.url) as response:
            self.assertEqual(json.load(response),self.manifest)
        for file in self.manifest['files']:
            url = self.url.rsplit('/',1)[0]+'/file/'+str(file['id'])
            with urllib.request.urlopen(url) as response:
                data = response.read()
            self.assertEqual(hashlib.sha256(data).hexdigest(),file['sha256'])
            request = urllib.request.Request(url,headers={'Range':'bytes=0-2'})
            with urllib.request.urlopen(request) as response:
                self.assertEqual(response.status,206)
                self.assertEqual(response.read(),data[:3])
        for suffix in ('../config/local.json','file/99999999','file/../1'):
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(self.url.rsplit('/',1)[0]+'/'+suffix)
            self.assertEqual(error.exception.code,404)
            error.exception.close()
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(self.url.replace(self.url.split('/')[-2],'wrong-token'))
        self.assertEqual(error.exception.code,404)
        error.exception.close()

    def test_source_symlinks_cannot_escape(self):
        outside = self.root/'not-exported'
        outside.write_bytes(b'outside')
        (self.sources/'prep/link').symlink_to(outside)
        with self.assertRaises(ValueError):
            server_api.collect_files(self.roots)

    def build_importer(self):
        binary = self.root/'import-check'
        driver = self.root/'driver.swift'
        driver.write_text(DRIVER)
        subprocess.run(['xcrun','swiftc','-DP2_GAME','-swift-version','5','-strict-concurrency=complete',
                        '-warnings-as-errors','-parse-as-library',
                        str(ROOT/'visionos/Sources/PortalContentImporter.swift'),str(driver),'-o',str(binary)],
                       check=True,capture_output=True,text=True)
        return binary

    @unittest.skipUnless(os.uname().sysname=='Darwin','Swift Apple frameworks required')
    def test_real_swift_import_retries_truncated_transfer(self):
        binary = self.build_importer()
        token = self.url.split('/')[-2]
        name = 'game/portal2/pak01_dir.vpk'
        payload = self.payloads[name]
        entry = next(f for f in self.manifest['files'] if f['path']==name)
        route = f'/{token}/file/{entry["id"]}'
        _, table = server_api.build_manifest(server_api.collect_files(self.roots))
        base = server_api.make_handler(token,json.dumps(self.manifest).encode(),table)
        hits = []

        class Truncating(base):
            def do_GET(self):
                if self.path==route:
                    hits.append(1)
                    if len(hits)==1:  # full headers, half the body, then drop the connection
                        self.send_response(200)
                        self.send_header('Content-Length',str(len(payload)))
                        self.end_headers()
                        self.wfile.write(payload[:len(payload)//2])
                        self.close_connection = True
                        return
                super().do_GET()

        self.server.RequestHandlerClass = Truncating
        docs = self.root/'documents'
        dest = docs/name
        dest.parent.mkdir(parents=True)
        dest.write_bytes(b'old asset')
        save = docs/'portal2-userdata/save.sav'
        save.parent.mkdir()
        save.write_bytes(b'preserve save')
        result = subprocess.run([binary,self.url,docs],capture_output=True,text=True,timeout=180)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Imported 3 files',result.stdout)
        self.assertEqual(len(hits),2)
        self.assertEqual(hashlib.sha256(dest.read_bytes()).hexdigest(),entry['sha256'])
        self.assertEqual(save.read_bytes(),b'preserve save')
        backups = list((docs/'Portal2 Import Backups').rglob('pak01_dir.vpk'))
        self.assertEqual([b.read_bytes() for b in backups],[b'old asset'])
        self.assertEqual(list((docs/'Portal2 Import Staging').iterdir()),[])
        self.assertNotIn(token,result.stdout+result.stderr)

    @unittest.skipUnless(os.uname().sysname=='Darwin','Swift Apple frameworks required')
    def test_real_swift_import_reuse_backup_and_symlink_rejection(self):
        binary = self.build_importer()
        docs = self.root/'documents'
        dest = docs/'game/portal2/pak01_dir.vpk'
        dest.parent.mkdir(parents=True)
        dest.write_bytes(b'old asset')
        save = docs/'portal2-userdata/save.sav'
        save.parent.mkdir()
        save.write_bytes(b'preserve save')
        result = subprocess.run([binary,self.url,docs],check=True,capture_output=True,text=True)
        self.assertIn('Imported 3 files',result.stdout)
        for name,data in self.payloads.items(): self.assertEqual((docs/name).read_bytes(),data)
        backups = list((docs/'Portal2 Import Backups').rglob('pak01_dir.vpk'))
        self.assertEqual(len(backups),1)
        self.assertEqual(backups[0].read_bytes(),b'old asset')
        self.assertEqual(save.read_bytes(),b'preserve save')
        result = subprocess.run([binary,self.url,docs],check=True,capture_output=True,text=True)
        self.assertIn('Imported 0 files, reused 3',result.stdout)
        bad_docs = self.root/'bad-documents'
        bad_docs.mkdir()
        outside = self.root/'outside'
        outside.mkdir()
        (bad_docs/'game').symlink_to(outside,target_is_directory=True)
        result = subprocess.run([binary,self.url,bad_docs],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('unsafe',result.stderr.lower())
        self.assertEqual(list(outside.iterdir()),[])
        aux_docs = self.root/'aux-documents'
        aux_docs.mkdir()
        (aux_docs/'Portal2 Import Staging').symlink_to(outside,target_is_directory=True)
        result = subprocess.run([binary,self.url,aux_docs],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(list(outside.iterdir()),[])
        corrupt = json.loads(json.dumps(self.manifest))
        corrupt['files'][0]['sha256'] = '0'*64
        _, table = server_api.build_manifest(server_api.collect_files(self.roots))
        self.server.RequestHandlerClass = server_api.make_handler(self.url.split('/')[-2],json.dumps(corrupt).encode(),table)
        result = subprocess.run([binary,self.url,docs],capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('SHA-256',result.stderr)
        self.assertEqual(dest.read_bytes(),self.payloads['game/portal2/pak01_dir.vpk'])
        self.assertEqual(save.read_bytes(),b'preserve save')
