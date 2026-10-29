"""Real HTTP framing checks for large owned-content responses and source failures."""
import http.client
import importlib.util
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('owned_server_checks', ROOT/'tools/serve_owned_content.py')
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


class OwnedContentServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='p2-http-framing-')
        self.root = Path(self.temp.name)
        self.payload = bytes(range(251)) * 14000
        self.file = self.root/'fixture.bin'
        self.file.write_bytes(self.payload)
        self.server, manifest_url, _ = api.prepare([('prep', self.root)])
        self.url = manifest_url.rsplit('/', 1)[0]+'/file/1'
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def test_large_full_and_range_responses(self):
        with urllib.request.urlopen(self.url, timeout=3) as response:
            self.assertEqual(int(response.headers['Content-Length']), len(self.payload))
            self.assertEqual(response.read(), self.payload)
        start, end = 117, 2200000
        request = urllib.request.Request(self.url, headers={'Range': f'bytes={start}-{end}'})
        with urllib.request.urlopen(request, timeout=3) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.read(), self.payload[start:end+1])
        self.assertEqual(self.server.activity['files_served'], 2)
        self.assertEqual(self.server.activity['bytes_sent'], len(self.payload)+end-start+1)

    def test_source_early_eof_closes_body_then_new_request_succeeds(self):
        real_open = open

        class ShortSource:
            def __init__(self, stream):
                self.stream, self.read_once = stream, False
            def __enter__(self): return self
            def __exit__(self, *_): self.stream.close()
            def fileno(self): return self.stream.fileno()
            def seek(self, *args): return self.stream.seek(*args)
            def read(self, count):
                if self.read_once: return b''
                self.read_once = True
                return self.stream.read(min(count, 8192))

        def short_open(path, *args, **kwargs):
            stream = real_open(path, *args, **kwargs)
            return ShortSource(stream) if Path(path).resolve() == self.file.resolve() else stream

        with patch.object(api, 'open', short_open, create=True):
            with urllib.request.urlopen(self.url, timeout=3) as response:
                with self.assertRaises(http.client.IncompleteRead) as failure:
                    response.read()
                self.assertEqual(failure.exception.partial, self.payload[:8192])
        self.assertEqual(self.server.activity.get('transfer_failures'), 1)
        self.assertEqual(self.server.activity['files_served'], 0)
        with urllib.request.urlopen(self.url, timeout=3) as response:
            self.assertEqual(response.read(), self.payload)
        self.assertEqual(self.server.activity['files_served'], 1)
