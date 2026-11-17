#!/usr/bin/env python3
"""Local custom Portal 2 test chambers (compiled .bsp the player already has), without Steam Workshop.

Same rules and layout as runtime/custom_levels.c, for the Mac side (a content root that is then
copied to the device, the simulator container, or any --game-dir):

  <game>/portal2/maps/custom/<name>.bsp        loaded with `+map custom/<name>`
  <game>/portal2/maps/custom/<name>.files.json companion files added by a package import
  <game>/portal2/<materials|models|...>/...    companion files (never replacing or shadowing stock files)

Commands:
  check FILE.bsp
  import --game-dir GAME SOURCE [--name NAME] [--replace] [--dry-run]
         SOURCE = a .bsp, a folder, or a .zip holding maps/*.bsp plus optional companion folders
  list   --game-dir GAME
  remove --game-dir GAME NAME
  launch --documents DOCS --game-dir GAME NAME   (one-shot `+map custom/NAME` block in DOCS/launch.args)
  clear  --documents DOCS

Nothing here talks to Steam. Original campaign files, VPKs, saves and other launch.args lines are
never modified. A custom map that needs loose assets missing from its pakfile only works if the
package carries them. This is not the in-game Puzzle Maker (editor), which is not provided here.
"""
import argparse
import hashlib
import json
import os
import re
import stat
import struct
import sys
import tempfile
import zipfile
from pathlib import PurePosixPath

BSP_VERSION = 21
HEADER_BYTES = 8 + 64 * 16 + 4
MAX_BSP = 1 << 30
MAX_PACKAGE = 2 << 30
MAX_ENTRIES = 20000
NAME = re.compile(r'[a-z0-9_][a-z0-9_-]{0,63}\Z')
BEGIN = '# p2-custom-level begin: one-shot, removed by the launcher after start'
END = '# p2-custom-level end'
COMPANION_DIRS = {'materials', 'models', 'sound', 'scripts', 'particles', 'resource'}
COMPANION_EXT = {'.vmt', '.vtf', '.mdl', '.vvd', '.vtx', '.phy', '.ani', '.wav', '.mp3', '.txt', '.nut', '.pcf', '.vcd', '.res'}


class LevelError(Exception):
    pass


# ---------------------------------------------------------------- names and BSP header
def name_from_path(path):
    base = os.path.basename(path)
    if base.lower().endswith('.bsp'):
        base = base[:-4]
    name = ''.join(c if ('a' <= c <= 'z' or '0' <= c <= '9' or c == '-') else '_' for c in base.lower())[:64].lstrip('-')
    if not NAME.match(name):
        raise LevelError(f'cannot derive a map name from {path!r}')
    return name


def check_name(name):
    if not isinstance(name, str) or not NAME.match(name):
        raise LevelError('invalid map name (use a-z, 0-9, _ and -, at most 64 characters)')
    return name


def inspect_bsp(data_or_file):
    """Validate a VBSP v21 header and lump table. Accepts bytes-like header+size or an open file."""
    if isinstance(data_or_file, (bytes, bytearray)):
        size, header = len(data_or_file), bytes(data_or_file[:HEADER_BYTES])
    else:
        st = os.fstat(data_or_file.fileno())
        if not stat.S_ISREG(st.st_mode):
            raise LevelError('not a regular file')
        size = st.st_size
        data_or_file.seek(0)
        header = data_or_file.read(HEADER_BYTES)
    if size > MAX_BSP:
        raise LevelError('map file too large')
    if size < HEADER_BYTES:
        if size >= 4 and header[:4] == b'VBSP':
            raise LevelError('damaged or incomplete map (truncated header)')
        raise LevelError('not a compiled Source map (VBSP header missing)')
    if header[:4] != b'VBSP':
        raise LevelError('not a compiled Source map (VBSP header missing)')
    version = struct.unpack_from('<i', header, 4)[0]
    if version != BSP_VERSION:
        raise LevelError(f'not a Portal 2 map (VBSP version {version}, expected 21)')
    lengths = []
    for i in range(64):
        offset, length = struct.unpack_from('<ii', header, 8 + 16 * i)
        lengths.append(length)
        if offset < 0 or length < 0 or (length and (offset < HEADER_BYTES or offset + length > size)):
            raise LevelError(f'damaged or incomplete map (lump {i} out of range)')
    if not all(lengths[i] for i in (0, 1, 5, 14)):
        raise LevelError('damaged or incomplete map (essential lumps empty)')
    return {'version': version, 'map_revision': struct.unpack_from('<i', header, 8 + 64 * 16)[0],
            'size': size, 'has_pakfile': lengths[40] > 0}


# ---------------------------------------------------------------- safe directories
def open_dir_chain(base, parts, create=False):
    """Open base/parts... one component at a time, refusing symbolic links. Returns a dir fd."""
    try:
        fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY)
    except (FileNotFoundError, NotADirectoryError):
        raise LevelError(f'{base}: game folder not found') from None
    try:
        for part in parts:
            try:
                st = os.stat(part, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                if not create:
                    raise LevelError(f'{part}: folder not found under {base}') from None
                os.mkdir(part, 0o755, dir_fd=fd)
                st = os.stat(part, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                raise LevelError(f'{part}: symbolic links are refused')
            if not stat.S_ISDIR(st.st_mode):
                raise LevelError(f'{part}: not a folder')
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def custom_dir(game_dir, create=False):
    maps = open_dir_chain(game_dir, ['portal2', 'maps'])     # game content must already exist
    try:
        return _child(maps, 'custom', create)
    finally:
        os.close(maps)


def _child(parent_fd, name, create):
    try:
        st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        if not create:
            raise LevelError('no custom maps installed') from None
        os.mkdir(name, 0o755, dir_fd=parent_fd)
        st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if stat.S_ISLNK(st.st_mode):
        raise LevelError(f'{name}: symbolic links are refused')
    if not stat.S_ISDIR(st.st_mode):
        raise LevelError(f'{name}: not a folder')
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)


def lstat_at(dir_fd, name):
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def write_new(dir_fd, name, chunks, replace=False):
    """Write chunks to dir_fd/name atomically. Without replace, never overwrites (link-based)."""
    temp = f'.{name}.part-{os.getpid()}'
    try:
        os.unlink(temp, dir_fd=dir_fd)
    except FileNotFoundError:
        pass
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644, dir_fd=dir_fd)
    try:
        with os.fdopen(fd, 'wb') as out:
            for chunk in chunks:
                out.write(chunk)
            out.flush()
            os.fsync(out.fileno())
        if replace:
            os.replace(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        else:
            try:
                os.link(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
            except FileExistsError:
                raise LevelError(f'{name} already exists') from None
    finally:
        try:
            os.unlink(temp, dir_fd=dir_fd)
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------- stock content index
def vpk_paths(path):
    """Lower-case file paths listed by a VPK v1/v2 directory file."""
    with open(path, 'rb') as f:
        data = f.read()
    if len(data) < 12 or struct.unpack_from('<I', data, 0)[0] != 0x55AA1234:
        raise LevelError(f'{path}: not a VPK directory')
    version, tree = struct.unpack_from('<II', data, 4)
    pos = {1: 12, 2: 28}.get(version)
    if pos is None or pos + tree > len(data):
        raise LevelError(f'{path}: unsupported VPK directory')
    end = pos + tree

    def cstr():
        nonlocal pos
        stop = data.index(b'\0', pos, end)
        text = data[pos:stop].decode('latin-1')
        pos = stop + 1
        return text

    paths = set()
    while True:
        ext = cstr()
        if not ext:
            break
        while True:
            folder = cstr()
            if not folder:
                break
            while True:
                file = cstr()
                if not file:
                    break
                if pos + 18 > end:
                    raise LevelError(f'{path}: truncated VPK entry')
                preload = struct.unpack_from('<H', data, pos + 4)[0]
                pos += 18 + preload
                rel = file + '.' + ext if folder.strip() == '' else f'{folder}/{file}.{ext}'
                paths.add(rel.lower())
    return paths


def stock_index(game_dir):
    """Stock paths: every game/<dir>/pak01_dir.vpk entry. Loose files are checked on disk separately."""
    paths = set()
    for entry in sorted(os.listdir(game_dir)):
        vpk = os.path.join(game_dir, entry, 'pak01_dir.vpk')
        if os.path.isfile(vpk) and not os.path.islink(vpk):
            paths |= vpk_paths(vpk)
    return paths


def loose_exists(game_dir, rel):
    for entry in os.listdir(game_dir):
        if os.path.lexists(os.path.join(game_dir, entry, rel)):
            return True
    return False


# ---------------------------------------------------------------- package sources
def clean_relative(name):
    if not name or '\\' in name or '\0' in name or name.startswith('/') or re.match(r'[A-Za-z]:', name):
        raise LevelError(f'unsafe path in package: {name!r}')
    parts = PurePosixPath(name).parts
    if any(p in ('..', '.', '') for p in parts):
        raise LevelError(f'unsafe path in package: {name!r}')
    return '/'.join(parts)


def package_entries(source):
    """[(relative path, size, opener)] for a folder or zip, after safety checks."""
    entries = []
    if os.path.isdir(source) and not os.path.islink(source):
        for top, dirs, files in os.walk(source, followlinks=False):
            for name in dirs + files:
                full = os.path.join(top, name)
                st = os.lstat(full)
                if stat.S_ISLNK(st.st_mode):
                    raise LevelError(f'symbolic link in package: {os.path.relpath(full, source)}')
                if name in files and not stat.S_ISREG(st.st_mode):
                    raise LevelError(f'not a regular file: {os.path.relpath(full, source)}')
            for name in files:
                full = os.path.join(top, name)
                rel = clean_relative(os.path.relpath(full, source).replace(os.sep, '/'))
                entries.append((rel, os.lstat(full).st_size, lambda full=full: open(full, 'rb', buffering=0)))
    elif zipfile.is_zipfile(source):
        archive = zipfile.ZipFile(source)
        for info in archive.infolist():
            if info.flag_bits & 0x1:
                raise LevelError(f'encrypted entry in package: {info.filename}')
            if stat.S_ISLNK(info.external_attr >> 16):
                raise LevelError(f'symbolic link in package: {info.filename}')
            if info.is_dir():
                clean_relative(info.filename.rstrip('/'))
                continue
            rel = clean_relative(info.filename)
            entries.append((rel, info.file_size, lambda info=info: archive.open(info)))
    else:
        raise LevelError('source must be a .bsp, a folder or a .zip')
    if len(entries) > MAX_ENTRIES or sum(size for _, size, _ in entries) > MAX_PACKAGE:
        raise LevelError('package too large')
    seen = set()
    for rel, _, _ in entries:
        if rel.lower() in seen:
            raise LevelError(f'duplicate path in package: {rel}')
        seen.add(rel.lower())
    # A single wrapper folder (common for zips) is stripped: chamber/maps/x.bsp -> maps/x.bsp.
    tops = {rel.split('/', 1)[0] for rel, _, _ in entries}
    if len(tops) == 1 and not (tops & (COMPANION_DIRS | {'maps', 'portal2'})) and all('/' in rel for rel, _, _ in entries):
        entries = [(rel.split('/', 1)[1], size, op) for rel, size, op in entries]
    if all(rel.startswith('portal2/') for rel, _, _ in entries):
        entries = [(rel[len('portal2/'):], size, op) for rel, size, op in entries]
    return entries


def bounded_chunks(opener, declared, limit):
    """Stream a member, refusing more bytes than declared (zip bomb / growing file guard)."""
    total = 0
    with opener() as stream:
        while True:
            chunk = stream.read(1 << 16)
            if not chunk:
                break
            total += len(chunk)
            if total > declared or total > limit:
                raise LevelError('package member larger than declared')
            yield chunk
    if total != declared:
        raise LevelError('package member shorter than declared')


# ---------------------------------------------------------------- operations
def install_bsp_bytes(custom_fd, name, opener, size, replace):
    existing = lstat_at(custom_fd, f'{name}.bsp')
    if existing is not None:
        if stat.S_ISLNK(existing.st_mode):
            raise LevelError(f'{name}.bsp: symbolic links are refused')
        if not replace:
            raise LevelError(f'a custom map named {name} already exists (use --replace)')
    head = b''.join(bounded_chunks(opener, size, MAX_BSP)) if size <= (64 << 20) else None
    if head is not None:
        inspect_bsp(head)
        write_new(custom_fd, f'{name}.bsp', [head], replace)
        return
    with tempfile.TemporaryFile() as spool:          # large map: validate before installing
        for chunk in bounded_chunks(opener, size, MAX_BSP):
            spool.write(chunk)
        spool.flush()
        inspect_bsp(spool)
        spool.seek(0)
        write_new(custom_fd, f'{name}.bsp', iter(lambda: spool.read(1 << 16), b''), replace)


def import_source(game_dir, source, name=None, replace=False, dry_run=False):
    report = {'maps': [], 'companions': [], 'shared': [], 'ignored': []}
    if os.path.islink(source):
        raise LevelError('symbolic links are refused')
    if os.path.isfile(source) and source.lower().endswith('.bsp'):
        name = check_name(name) if name else name_from_path(source)
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, 'rb', buffering=0) as f:
            info = inspect_bsp(f)
        report['maps'].append({'name': name, 'map': f'custom/{name}', **info})
        if not dry_run:
            custom = custom_dir(game_dir, create=True)
            try:
                install_bsp_bytes(custom, name, lambda: open(source, 'rb', buffering=0), info['size'], replace)
            finally:
                os.close(custom)
        return report

    entries = package_entries(source)
    maps = [(rel, size, op) for rel, size, op in entries if rel.lower().startswith('maps/') and rel.lower().endswith('.bsp')]
    if not maps:
        raise LevelError('package has no maps/*.bsp')
    if name and len(maps) != 1:
        raise LevelError('--name needs a package with exactly one map')
    planned_maps = []
    for rel, size, op in maps:
        map_name = check_name(name) if name else name_from_path(rel)
        if any(m[0] == map_name for m in planned_maps):
            raise LevelError(f'two maps in the package would be named {map_name}')
        planned_maps.append((map_name, size, op))
    stock = stock_index(game_dir)
    primary = planned_maps[0][0]
    own_manifest = read_manifest(game_dir, primary) if replace else {}
    companions = []
    for rel, size, op in entries:
        low = rel.lower()
        top = low.split('/', 1)[0]
        if (rel, size, op) in maps:
            continue
        if top not in COMPANION_DIRS or os.path.splitext(low)[1] not in COMPANION_EXT or '/' not in rel:
            report['ignored'].append(rel)
            continue
        if low in stock:
            raise LevelError(f'{rel} would replace an original game file; refused')
        recorded = own_manifest.get('companions', {}).get(rel)
        if recorded:
            existing = os.path.join(game_dir, 'portal2', rel)
            if os.path.lexists(existing) and (os.path.islink(existing) or sha256_file(existing) != recorded):
                raise LevelError(f'{rel} was modified since it was imported; refused')
        elif loose_exists(game_dir, rel):
            existing = os.path.join(game_dir, 'portal2', rel)
            if not (os.path.isfile(existing) and not os.path.islink(existing) and sha256_file(existing) == sha256_member(op, size)):
                raise LevelError(f'{rel} already exists with different content; refused')
        companions.append((rel, size, op))
    for map_name, _, _ in planned_maps:
        report['maps'].append({'name': map_name, 'map': f'custom/{map_name}'})
    report['companions'] = [rel for rel, _, _ in companions]
    if dry_run:
        for map_name, size, op in planned_maps:
            with tempfile.TemporaryFile() as spool:
                for chunk in bounded_chunks(op, size, MAX_BSP):
                    spool.write(chunk)
                spool.flush()
                inspect_bsp(spool)
        return report

    written, custom = [], custom_dir(game_dir, create=True)
    try:
        for map_name, size, op in planned_maps:
            install_bsp_bytes(custom, map_name, op, size, replace)
            written.append(('map', map_name))
        manifest = {'maps': [m[0] for m in planned_maps], 'companions': {}}
        for rel, size, op in companions:
            parts = rel.split('/')
            folder = open_dir_chain(game_dir, ['portal2'] + parts[:-1], create=True)   # portal2/ checked above
            try:
                digest = hashlib.sha256()
                def tee():
                    for chunk in bounded_chunks(op, size, MAX_BSP):
                        digest.update(chunk)
                        yield chunk
                ours = rel in own_manifest.get('companions', {})
                if lstat_at(folder, parts[-1]) is None or ours:
                    write_new(folder, parts[-1], tee(), ours)   # ours: written by an earlier import of this package
                    written.append(('file', rel) if not ours else ('kept', rel))
                    manifest['companions'][rel] = digest.hexdigest()
                else:
                    report['shared'].append(rel)               # identical pre-existing file: never recorded, never removed
            finally:
                os.close(folder)
        write_new(custom, f'{primary}.files.json', [json.dumps(manifest, indent=1, sort_keys=True).encode()], True)
    except BaseException:
        for kind, item in reversed(written):          # roll back what this import created
            try:
                if kind == 'map' and not replace:
                    os.unlink(f'{item}.bsp', dir_fd=custom)
                elif kind == 'file':
                    os.unlink(os.path.join(game_dir, 'portal2', item))
            except OSError:
                pass
        raise
    finally:
        os.close(custom)
    return report


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 16), b''):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_member(opener, size):
    digest = hashlib.sha256()
    for chunk in bounded_chunks(opener, size, MAX_BSP):
        digest.update(chunk)
    return digest.hexdigest()


def read_manifest(game_dir, name):
    try:
        custom = custom_dir(game_dir)
    except LevelError:
        return {}
    try:
        st = lstat_at(custom, f'{name}.files.json')
        if st is None or not stat.S_ISREG(st.st_mode):
            return {}
        fd = os.open(f'{name}.files.json', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=custom)
        with os.fdopen(fd, 'rb') as f:
            return json.load(f)
    finally:
        os.close(custom)


def list_maps(game_dir):
    try:
        custom = custom_dir(game_dir)
    except LevelError as error:
        if 'no custom maps' in str(error):
            return []
        raise
    try:
        result = []
        for entry in os.listdir(custom):
            if not entry.endswith('.bsp') or not NAME.match(entry[:-4]):
                continue
            st = lstat_at(custom, entry)
            if st and stat.S_ISREG(st.st_mode):
                result.append({'name': entry[:-4], 'map': f'custom/{entry[:-4]}', 'size': st.st_size})
        return sorted(result, key=lambda item: item['name'])
    finally:
        os.close(custom)


def remove_map(game_dir, name):
    check_name(name)
    manifest = read_manifest(game_dir, name)
    others = [read_manifest(game_dir, m['name']) for m in list_maps(game_dir) if m['name'] != name]
    shared = {rel for other in others for rel in other.get('companions', {})}
    kept, removed = [], []
    custom = custom_dir(game_dir)
    try:
        for map_name in manifest.get('maps', [name]):
            st = lstat_at(custom, f'{map_name}.bsp')
            if st is None:
                continue
            if not stat.S_ISREG(st.st_mode):
                raise LevelError(f'{map_name}.bsp: not a regular file; left in place')
            os.unlink(f'{map_name}.bsp', dir_fd=custom)
            removed.append(f'maps/custom/{map_name}.bsp')
        if not removed:
            raise LevelError(f'no custom map named {name}')
        for rel, digest in manifest.get('companions', {}).items():
            path = os.path.join(game_dir, 'portal2', clean_relative(rel))
            if rel in shared or os.path.islink(path) or not os.path.isfile(path) or sha256_file(path) != digest:
                kept.append(rel)
                continue
            os.unlink(path)
            removed.append(rel)
        if lstat_at(custom, f'{name}.files.json'):
            os.unlink(f'{name}.files.json', dir_fd=custom)
    finally:
        os.close(custom)
    return {'removed': removed, 'kept': kept}


# ---------------------------------------------------------------- launch.args
def _launch_lines(documents):
    path = os.path.join(documents, 'launch.args')
    if os.path.islink(path):
        raise LevelError('launch.args is a symbolic link; refused')
    try:
        with open(path, 'rb') as f:
            text = f.read(64 * 1024 + 1).decode('utf-8')
    except FileNotFoundError:
        return []
    if len(text) > 64 * 1024:
        raise LevelError('launch.args too large')
    kept, inside = [], False
    for line in text.split('\n')[:-1] if text.endswith('\n') else text.split('\n') if text else []:
        bare = line[:-1] if line.endswith('\r') else line
        if bare == BEGIN:
            inside = True
        elif inside and bare == END:
            inside = False
        elif not inside:
            kept.append(line)
    return kept


def _write_launch(documents, lines):
    text = ''.join(line + '\n' for line in lines).encode('utf-8')
    fd = os.open(documents, os.O_RDONLY | os.O_DIRECTORY)
    try:
        write_new(fd, 'launch.args', [text], replace=True)
    finally:
        os.close(fd)


def request_launch(documents, game_dir, name):
    check_name(name)
    custom = custom_dir(game_dir)
    try:
        fd = os.open(f'{name}.bsp', os.O_RDONLY | os.O_NOFOLLOW, dir_fd=custom)
    except FileNotFoundError:
        raise LevelError(f'no custom map named {name}') from None
    except OSError as error:
        raise LevelError(f'{name}.bsp: {error.strerror}') from None
    finally:
        os.close(custom)
    with os.fdopen(fd, 'rb', buffering=0) as f:
        inspect_bsp(f)
    _write_launch(documents, _launch_lines(documents) + [BEGIN, '+map', f'custom/{name}', END])


def clear_launch(documents):
    _write_launch(documents, _launch_lines(documents))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('check'); p.add_argument('file')
    p = sub.add_parser('import'); p.add_argument('--game-dir', required=True); p.add_argument('source')
    p.add_argument('--name'); p.add_argument('--replace', action='store_true'); p.add_argument('--dry-run', action='store_true')
    p = sub.add_parser('list'); p.add_argument('--game-dir', required=True)
    p = sub.add_parser('remove'); p.add_argument('--game-dir', required=True); p.add_argument('name')
    p = sub.add_parser('launch'); p.add_argument('--documents', required=True); p.add_argument('--game-dir', required=True); p.add_argument('name')
    p = sub.add_parser('clear'); p.add_argument('--documents', required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == 'check':
            fd = os.open(args.file, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb', buffering=0) as f:
                result = inspect_bsp(f)
        elif args.command == 'import':
            result = import_source(args.game_dir, args.source, args.name, args.replace, args.dry_run)
        elif args.command == 'list':
            result = list_maps(args.game_dir)
        elif args.command == 'remove':
            result = remove_map(args.game_dir, args.name)
        elif args.command == 'launch':
            request_launch(args.documents, args.game_dir, args.name)
            result = {'launch': f'+map custom/{args.name}', 'note': 'one-shot: run `clear` after the game has started'}
        else:
            clear_launch(args.documents)
            result = {'cleared': True}
    except (LevelError, OSError) as error:
        print(json.dumps({'error': str(error)}), file=sys.stderr)
        return 1
    print(json.dumps(result, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main())
