#!/usr/bin/env python3
"""Serve owned Portal 2 content to the visionOS PortalContentImporter over the LAN.

Developer bootstrap only. Serves a fixed, precomputed file map under a random capability
token: no directory listings, no writes, no path resolution from requests. The token URL
is written only to the private --output receipt, never to stdout or request logs.
"""
import argparse
import hashlib
import http.server
import json
import os
import re
import secrets
import sys
import threading
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GAME_SUBDIRS = ("bin", "platform", "update", "portal2", "portal2_dlc1", "portal2_dlc2")
CHUNK = 4 << 20
SKIP_NAMES = {".DS_Store"}
FILE_ROUTE = re.compile(r"file/([1-9][0-9]{0,8})")
RANGE = re.compile(r"bytes=([0-9]*)-([0-9]*)")


def source_roots(game_root, linux_root, prep_root):
    """Return [(manifest_prefix, directory)] for every exported owned-content root."""
    game = Path(game_root).expanduser()
    roots = [("prep", Path(prep_root).expanduser()), ("linux", Path(linux_root).expanduser())]
    return roots + [(f"game/{name}", game / name) for name in GAME_SUBDIRS]


def load_local_roots(repo=REPO):
    """Read only game_root/linux_root from the ignored config/local.json, plus build/game/prep."""
    config = json.loads((Path(repo) / "config" / "local.json").read_text())
    required = [(Path(config["game_root"]) / "portal2/pak01_dir.vpk"),
                (Path(config["linux_root"]) / "portal2_linux"), (Path(repo) / "build/game/prep/layout.json")]
    if not all(path.is_file() for path in required):
        raise ValueError("Owned Portal 2 content, Linux depot and prepared images must be present")
    return source_roots(config["game_root"], config["linux_root"], Path(repo) / "build" / "game" / "prep")


def _inside(real, allowed):
    return any(real == root or real.startswith(root + os.sep) for root in allowed)


def collect_files(roots):
    """Return sorted [(manifest_path, real_path)]; raise on symlinks escaping the source roots."""
    present = [(prefix, Path(root)) for prefix, root in roots if Path(root).is_dir()]
    allowed = [os.path.realpath(root) for _, root in present]
    entries = {}
    for prefix, root in present:
        for dirpath, dirnames, filenames in os.walk(root, followlinks=True):
            real_dir = os.path.realpath(dirpath)
            if not _inside(real_dir, allowed):
                raise ValueError(f"symlink escapes owned roots: {dirpath}")
            rel_parts = Path(dirpath).relative_to(root).parts
            ancestors = {os.path.realpath(root.joinpath(*rel_parts[:i])) for i in range(len(rel_parts))}
            if real_dir in ancestors:
                raise ValueError(f"symlink loop: {dirpath}")
            dirnames.sort()
            for name in sorted(filenames):
                if name in SKIP_NAMES:
                    continue
                full = os.path.join(dirpath, name)
                real = os.path.realpath(full)
                if not _inside(real, allowed):
                    raise ValueError(f"symlink escapes owned roots: {full}")
                if not os.path.isfile(real):
                    raise ValueError(f"not a regular file: {full}")
                path = f"{prefix}/{Path(full).relative_to(root).as_posix()}"
                if "\\" in path or "\0" in path or path in entries:
                    raise ValueError(f"unsafe or duplicate path: {path}")
                entries[path] = real
    return sorted(entries.items())


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(CHUNK):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(files):
    """Return (manifest, {id: (real_path, bytes)}) for [(manifest_path, real_path)]."""
    entries, table = [], {}
    for file_id, (path, real) in enumerate(files, 1):
        size = os.path.getsize(real)
        entries.append({"id": file_id, "path": path, "bytes": size, "sha256": sha256_file(real)})
        table[file_id] = (real, size)
    return {"version": 1, "total_bytes": sum(e["bytes"] for e in entries), "files": entries}, table


def make_handler(token, manifest_body, table):
    token_bytes = token.encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        disable_nagle_algorithm = True
        server_version = "P2OwnedContent/1"
        sys_version = ""
        timeout = 120

        def log_message(self, *args):
            pass  # request lines contain the capability token

        def do_GET(self):
            self._route(head=False)

        def do_HEAD(self):
            self._route(head=True)

        def _reply(self, code, length=0, headers=()):
            self.send_response(code)
            self.send_header("Content-Length", str(length))
            for name, value in headers:
                self.send_header(name, value)
            self.end_headers()

        def _route(self, head):
            parts = self.path.split("/", 2)
            if len(parts) != 3 or parts[0] or not secrets.compare_digest(parts[1].encode("latin-1", "replace"), token_bytes):
                return self._reply(404)
            if parts[2] == "manifest.json":
                self.server.record("manifest_requests",1)
                self._reply(200, len(manifest_body), [("Content-Type", "application/json"), ("Cache-Control", "no-store")])
                if not head:
                    self.wfile.write(manifest_body)
                return
            match = FILE_ROUTE.fullmatch(parts[2])
            if not match or int(match[1]) not in table:
                return self._reply(404)
            self._send_file(*table[int(match[1])], head)

        def _send_file(self, real, size, head):
            try:
                f = open(real, "rb")
            except OSError:
                return self._reply(404)
            with f:
                if os.fstat(f.fileno()).st_size != size:
                    return self._reply(409)  # changed since the manifest was hashed
                start, end, code = 0, size - 1, 200
                if self.headers.get("Range"):
                    match = RANGE.fullmatch(self.headers["Range"].strip())
                    if match and match[1]:
                        start, end = int(match[1]), min(int(match[2]), size - 1) if match[2] else size - 1
                    elif match and match[2] and int(match[2]) > 0:
                        start = max(size - int(match[2]), 0)
                    else:
                        start = size
                    if start > end or start >= size:
                        return self._reply(416, headers=[("Content-Range", f"bytes */{size}")])
                    code = 206
                length = max(end - start + 1, 0)
                headers = [("Content-Type", "application/octet-stream"), ("Accept-Ranges", "bytes")]
                if code == 206:
                    headers.append(("Content-Range", f"bytes {start}-{end}/{size}"))
                self._reply(code, length, headers)
                if not head and length:
                    try:
                        sent = self.connection.sendfile(f, start, length)
                        self.server.record("bytes_sent",sent)
                        self.server.record("files_served",1)
                    except (BrokenPipeError, ConnectionResetError):
                        self.close_connection = True

    return Handler


class OwnedContentServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self,*args,**kwargs):
        self.activity_lock = threading.Lock()
        self.activity = {"manifest_requests":0,"files_served":0,"bytes_sent":0}
        self.activity_path = None
        super().__init__(*args,**kwargs)

    def record(self,key,value):
        with self.activity_lock:
            self.activity[key] += value
            self.activity["last_activity_at"] = time.time()
            if self.activity_path:
                path = Path(self.activity_path)
                temporary = path.with_suffix(".tmp")
                fd = os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
                with os.fdopen(fd,"w") as stream: json.dump(self.activity,stream)
                os.replace(temporary,path)

    def handle_error(self, request, client_address):
        print(f"request error: {sys.exc_info()[0].__name__}", file=sys.stderr)


def prepare(roots, bind="127.0.0.1", port=0, advertise_host=None):
    """Hash the roots and bind a server; return (server, manifest_url, manifest). Does not serve yet."""
    host = advertise_host or bind
    if host in ("", "0.0.0.0", "::"):
        raise ValueError("--advertise-host is required when binding all interfaces")
    manifest, table = build_manifest(collect_files(roots))
    token = secrets.token_urlsafe(32)
    body = json.dumps(manifest, separators=(",", ":")).encode()
    server = OwnedContentServer((bind, port), make_handler(token, body, table))
    url = f"http://{host}:{server.server_address[1]}/{token}/manifest.json"
    return server, url, manifest


def write_receipt(path, url, manifest, expires_at):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"manifest_url": url, "files": len(manifest["files"]),
                   "total_bytes": manifest["total_bytes"], "expires_at": expires_at}, f, indent=2)


def run_until(server, ttl):
    """Serve until ttl seconds elapse (or Ctrl-C), then close the listener."""
    timer = threading.Timer(ttl, server.shutdown)
    timer.daemon = True
    timer.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        timer.cancel()
        server.server_close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bind", default="127.0.0.1", help="interface address; use the Mac's LAN IP for the device")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--advertise-host", help="host placed in the manifest URL (defaults to --bind)")
    parser.add_argument("--ttl", type=int, default=3600, help="seconds before the listener stops")
    parser.add_argument("--output", default=str(REPO / "build" / "owned_content_receipt.json"),
                        help="private receipt containing the token URL (mode 0600)")
    args = parser.parse_args(argv)
    if args.ttl <= 0:
        parser.error("--ttl must be positive")

    print("Hashing owned content...", flush=True)
    server, url, manifest = prepare(load_local_roots(), args.bind, args.port, args.advertise_host)
    server.activity_path = Path(args.output).with_suffix(".activity.json")
    write_receipt(args.output, url, manifest, int(time.time()) + args.ttl)
    print(f"Serving {len(manifest['files'])} files ({manifest['total_bytes']} bytes) on "
          f"{args.bind}:{server.server_address[1]} for {args.ttl}s; manifest URL in {args.output}", flush=True)
    run_until(server, args.ttl)
    print("Listener stopped.")


if __name__ == "__main__":
    main()
