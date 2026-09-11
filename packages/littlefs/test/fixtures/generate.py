#!/usr/bin/env python
"""Generate the littlefs test fixtures with the reference implementation.

Every image is produced by littlefs (the C library, via littlefs-python) and
the expected results by python idftool, so the Dart reader is checked against
the reference rather than against itself. Run it with a python that has
``littlefs`` importable and ``idftool`` on PATH, from this directory:

    /Users/nebkat/Work/Troo/idftool/.venv/bin/python generate.py

Per fixture ``<name>`` it writes:

    <name>.bin.gz    the image (gzip, deterministic)
    <name>.geom.txt  block_size/block_count/name_max/disk_version, key=value
    <name>.list.txt  ``idftool print-fs`` rows as ``<path>\\t<size|dir>``
    <name>.tar.gz    ``idftool extract-fs`` output (every file's exact bytes)

Plain trees go through ``idftool create-fs`` like a build would. littlefs-python
defaults ``prog_size`` to the block size, which makes every commit fill a whole
block, so the scenarios that need real logs — rewrites, deletes, renames,
attributes, an interrupted move — drive ``littlefs.LittleFS`` directly with a
small ``prog_size``.
"""
import gzip
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

from littlefs import LittleFS
from littlefs.context import UserContext
from littlefs.errors import LittleFSError

HERE = Path(__file__).resolve().parent
DISK_VERSION_NEWEST = 0x00020001


# --------------------------------------------------------------------------
# Deterministic content
# --------------------------------------------------------------------------

def lines(tag: str, size: int) -> bytes:
    """`size` bytes of numbered lines: compressible, but every block differs."""
    out = io.BytesIO()
    n = 0
    while out.tell() < size:
        out.write(f"{tag} line {n:08d} {'-' * (n % 37)}\n".encode())
        n += 1
    return out.getvalue()[:size]


def noise(seed: int, size: int) -> bytes:
    """`size` bytes from xorshift32: incompressible binary content."""
    x = (seed * 2654435761 + 1) & 0xFFFFFFFF or 1
    out = bytearray(size)
    for i in range(size):
        x ^= (x << 13) & 0xFFFFFFFF
        x ^= x >> 17
        x ^= (x << 5) & 0xFFFFFFFF
        out[i] = x & 0xFF
    return bytes(out)


def ctz_capacity(block_size: int, blocks: int) -> int:
    """Bytes a CTZ file of exactly `blocks` blocks holds (block 0 has no pointers)."""
    total = 0
    for i in range(blocks):
        pointers = 0 if i == 0 else ((i & -i).bit_length()) # ctz(i) + 1
        total += block_size - 4 * pointers
    return total


# --------------------------------------------------------------------------
# Oracle
# --------------------------------------------------------------------------

def run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def oracle_listing(image: Path) -> str:
    """`idftool print-fs` reduced to `path\\tsize` lines in the Dart sort order."""
    rows = []
    for line in run('idftool', 'print-fs', '-f', str(image)).splitlines():
        m = re.match(r'^\| (.*?) +\| +(\d+|<dir>) \|$', line)
        if m and m.group(1) != 'Path':
            rows.append((m.group(1).split('/'), m.group(1), 'dir' if m.group(2) == '<dir>' else m.group(2)))
    rows.sort(key=lambda r: r[0])
    return ''.join(f"{path}\t{size}\n" for _, path, size in rows)


def oracle_extract(image: Path, out: Path) -> None:
    """`idftool extract-fs` into a deterministic tar.gz."""
    with tempfile.TemporaryDirectory() as tmp:
        run('idftool', 'extract-fs', '-f', str(image), tmp)
        with gzip.GzipFile(out, 'wb', mtime=0) as gz, tarfile.open(fileobj=gz, mode='w', format=tarfile.GNU_FORMAT) as tar:
            for root, dirs, files in os.walk(tmp):
                dirs.sort()
                for name in sorted(dirs) + sorted(files):
                    full = Path(root) / name
                    info = tar.gettarinfo(str(full), str(full.relative_to(tmp)))
                    info.mtime = 0
                    info.uid = info.gid = 0
                    info.uname = info.gname = ''
                    with (open(full, 'rb') if info.isfile() else open(os.devnull, 'rb')) as f:
                        tar.addfile(info, f if info.isfile() else None)


def store(name: str, image: bytes, *, block_size: int, name_max: int = 64, disk_version: int = DISK_VERSION_NEWEST) -> None:
    bin_path = HERE / f'{name}.bin'
    bin_path.write_bytes(image)
    with gzip.GzipFile(HERE / f'{name}.bin.gz', 'wb', mtime=0) as gz:
        gz.write(image)
    (HERE / f'{name}.geom.txt').write_text(
        f"block_size={block_size}\nblock_count={len(image) // block_size}\nname_max={name_max}\n"
        f"disk_version={disk_version:#x}\n")
    (HERE / f'{name}.list.txt').write_text(oracle_listing(bin_path))
    oracle_extract(bin_path, HERE / f'{name}.tar.gz')
    bin_path.unlink()
    print(f"  {name}: {len(image):#x} bytes, {sum(1 for _ in open(HERE / f'{name}.list.txt'))} entries")


# --------------------------------------------------------------------------
# Trees built with `idftool create-fs`
# --------------------------------------------------------------------------

def create_fs(name: str, tree: dict, size: int, *, block_size: int = 4096, name_max: int = 64,
              disk_version: int | None = None) -> None:
    """`tree` maps paths to bytes (files) or None (empty directories)."""
    with tempfile.TemporaryDirectory() as tmp:
        for path, content in tree.items():
            full = Path(tmp) / path
            if content is None:
                full.mkdir(parents=True, exist_ok=True)
            else:
                full.parent.mkdir(parents=True, exist_ok=True)
                full.write_bytes(content)
        out = Path(tmp) / 'out.bin'
        args = ['idftool', 'create-fs', tmp, '-o', str(out), '--type', 'littlefs', '--size', hex(size),
                '--littlefs-block-size', str(block_size), '--littlefs-name-max', str(name_max)]
        if disk_version is not None:
            args += ['--littlefs-disk-version', hex(disk_version)]
        run(*args)
        store(name, out.read_bytes(), block_size=block_size, name_max=name_max,
              disk_version=disk_version or DISK_VERSION_NEWEST)


def cli_fixtures() -> None:
    create_fs('empty', {}, 0x40000)

    create_fs('inline', {
        'empty.txt': b'',
        'one.bin': b'\x42',
        'hello.txt': b'hello world\n',
        'n500.bin': noise(500, 500),
        'n512.bin': noise(512, 512),   # inline_max for 4 KiB blocks
        'n513.bin': noise(513, 513),   # first CTZ size
        'n1000.bin': noise(1000, 1000),
        'text.txt': lines('text', 300),
    }, 0x40000)

    # Files straddling exact CTZ block counts.
    blocks = {}
    for n in (1, 2, 3, 4, 8):
        cap = ctz_capacity(4096, n)
        for delta in (-1, 0, 1):
            blocks[f'blocks{n}{"m" if delta < 0 else "p" if delta > 0 else ""}.txt'] = lines(f'b{n}{delta:+d}', cap + delta)
    blocks['b4088.bin'] = noise(4088, 4088)
    blocks['b4089.bin'] = noise(4089, 4089)
    create_fs('blocks', blocks, 0x100000)

    create_fs('large', {
        'big200k.txt': lines('big200k', 200 * 1024),
        'big300k.txt': lines('big300k', 300 * 1024),
        'noise20k.bin': noise(20, 20 * 1024),
        'small.txt': b'small\n',
    }, 0x100000)

    nested = {'top.txt': b'top\n', 'empty_dir': None}
    path = ''
    for depth in range(10):
        path = f'{path}d{depth}/' if path else 'd0/'
        nested[f'{path}file{depth}.txt'] = lines(f'depth{depth}', 100 * (depth + 1))
        nested[f'{path}sib{depth}/x.txt'] = f'sibling {depth}\n'.encode()
        nested[f'{path}empty{depth}'] = None
    nested[f'{path}deep.bin'] = noise(9, 6000)
    create_fs('nested', nested, 0x100000)

    many = {f'f{i:03d}.txt': f'file {i}\n'.encode() for i in range(300)}
    many.update({f'sub/s{i:03d}.txt': f'sub file {i}\n'.encode() for i in range(150)})
    many.update({f'dirs/d{i:02d}': None for i in range(20)})
    many['sub/bigger.txt'] = lines('bigger', 10000)
    create_fs('many', many, 0x100000)

    l64 = 'n' * 60 + '.txt'
    l63 = 'm' * 59 + '.txt'
    d64 = 'D' * 64
    create_fs('longnames', {
        l64: b'sixty-four\n',
        l63: b'sixty-three\n',
        f'{d64}/{l64}': b'nested long\n',
        f'{d64}/{d64}/{l63}': lines('long', 5000),
        'a': b'a\n',
    }, 0x40000)

    l255 = 'x' * 251 + '.txt'
    create_fs('longnames255', {l255: b'255\n', 'Y' * 255: None, f'{"Z" * 255}/{l255}': lines('l255', 700)},
              0x40000, name_max=255)

    create_fs('small', {'a.txt': b'hello\n', 'sub/big.txt': lines('small', 5000), 'sub/empty': None}, 0x8000)

    create_fs('big2m', {
        'hundredk.txt': lines('hundredk', 100 * 1024),
        'dir/a.txt': b'a\n',
        'dir/b.bin': noise(11, 700),
        'z.txt': b'z\n',
    }, 0x200000)

    create_fs('bs512', {
        'sixtyk.txt': lines('sixtyk', 60 * 1024),
        'n300.bin': noise(300, 300),
        'n60.bin': noise(60, 60),      # inline (512 / 8 = 64 max)
        'n65.bin': noise(65, 65),      # CTZ in a single block
        'dir/n1000.bin': noise(1000, 1000),
        'dir/sub/x.txt': b'x\n',
    }, 0x20000, block_size=512)

    create_fs('bs8192', {
        'hundredk.txt': lines('hundredk8', 100 * 1024),
        'n1000.bin': noise(1000, 1000),
        'n1025.bin': noise(1025, 1025),
        'dir/y.txt': b'y\n',
    }, 0x80000, block_size=8192)

    create_fs('v20', {
        'a.txt': b'version 2.0\n',
        'dir/n9000.bin': noise(9000, 9000),
        'dir/twenty.txt': lines('v20', 20000),
    }, 0x40000, disk_version=0x00020000)


# --------------------------------------------------------------------------
# Logs written by littlefs itself
# --------------------------------------------------------------------------

def new_fs(block_size: int = 4096, block_count: int = 64, *, prog_size: int = 64, name_max: int = 64,
           context: UserContext | None = None, mount: bool = True, **kwargs) -> LittleFS:
    context = context or UserContext(buffsize=block_size * block_count)
    return LittleFS(context=context, block_size=block_size, block_count=block_count, read_size=prog_size,
                    prog_size=prog_size, cache_size=max(prog_size, 256), name_max=name_max, mount=mount, **kwargs)


def write(fs: LittleFS, path: str, data: bytes) -> None:
    with fs.open(path, 'wb') as f:
        f.write(data)


def log_fixtures() -> None:
    # Rewrites in both directions across the inline/CTZ boundary, appends,
    # truncation, deletes, renames within and across directories, and names
    # created out of order so CREATE splices land at low ids.
    fs = new_fs()
    fs.mkdir('/src')
    fs.mkdir('/dst')
    for i in range(10):
        write(fs, f'/m{i}.txt', f'first {i}\n'.encode())
    write(fs, '/grow.bin', noise(1, 100))
    write(fs, '/grow.bin', noise(2, 9000))            # inline -> CTZ
    write(fs, '/shrink.bin', noise(3, 9000))
    write(fs, '/shrink.bin', noise(4, 100))           # CTZ -> inline
    write(fs, '/append.txt', b'')
    for i in range(5):
        with fs.open('/append.txt', 'ab') as f:
            f.write(f'append {i}\n'.encode() * 40)
    write(fs, '/trunc.txt', lines('trunc', 20000))
    with fs.open('/trunc.txt', 'r+b') as f:
        f.truncate(4500)
    for i in (1, 3, 5):
        fs.remove(f'/m{i}.txt')
    fs.rename('/m2.txt', '/m2-renamed.txt')
    write(fs, '/src/moved.txt', lines('moved', 3000))
    fs.rename('/src/moved.txt', '/dst/moved.txt')
    fs.rename('/src', '/renamed-src')
    fs.mkdir('/gone')
    fs.rmdir('/gone')
    write(fs, '/aaa.txt', b'sorts first\n')
    write(fs, '/m0.txt', b'rewritten 0\n')
    write(fs, '/dst/zzz.txt', b'sorts last\n')
    fs.unmount()
    store('log_rewrite', bytes(fs.context.buffer), block_size=4096)

    # Enough churn that the root spans several pairs, compacts, shrinks again
    # and relocates (the superblock chain gains pairs).
    fs = new_fs(block_count=128)
    for i in range(300):
        write(fs, f'/f{i:03d}.txt', f'churn {i}\n'.encode())
    for i in range(0, 300, 2):
        fs.remove(f'/f{i:03d}.txt')
    for i in range(300, 400):
        write(fs, f'/g{i:03d}.txt', f'churn {i}\n'.encode())
    for i in range(1, 300, 4):
        write(fs, f'/f{i:03d}.txt', f'churn {i} again\n'.encode() * 3)
    for i in range(300, 400, 3):
        fs.remove(f'/g{i:03d}.txt')
    fs.mkdir('/d')
    for i in range(80):
        write(fs, f'/d/x{i:02d}.txt', f'd {i}\n'.encode())
    for i in range(0, 80, 2):
        fs.remove(f'/d/x{i:02d}.txt')
    fs.unmount()
    store('log_churn', bytes(fs.context.buffer), block_size=4096)

    # User attributes: tags a reader must skip by length, including a removed one.
    fs = new_fs()
    write(fs, '/attrs.txt', b'has attributes\n')
    fs.setattr('/attrs.txt', 0x10, b'\x01\x02\x03')
    fs.setattr('/attrs.txt', 0x20, noise(5, 200))
    fs.setattr('/attrs.txt', 0x30, b'removed')
    fs.removeattr('/attrs.txt', 0x30)
    write(fs, '/plain.txt', b'no attributes\n')
    fs.mkdir('/d')
    fs.setattr('/d', 0x40, b'dir attr')
    write(fs, '/d/inner.bin', noise(6, 5000))
    fs.setattr('/d/inner.bin', 0x50, b'ctz attr')
    fs.unmount()
    store('log_attrs', bytes(fs.context.buffer), block_size=4096)

    # Tiny program size: many small commits with odd padding, on 512-byte blocks.
    fs = new_fs(block_size=512, block_count=256, prog_size=16)
    for i in range(30):
        write(fs, f'/p{i:02d}.txt', f'prog16 {i}\n'.encode() * (i + 1))
    for i in range(0, 30, 3):
        fs.remove(f'/p{i:02d}.txt')
    write(fs, '/long.txt', lines('prog16', 30000))
    fs.unmount()
    store('log_prog16', bytes(fs.context.buffer), block_size=512)

    # A superblock pair where block 0 is stale: whole-block commits alternate
    # between the two blocks, so an odd number of root updates leaves block 1
    # newest; then block 0 is erased (as if power failed after the erase that
    # starts its next rewrite) or overwritten with garbage.
    fs = new_fs(prog_size=4096)
    write(fs, '/keep.txt', b'keep\n')
    fs.unmount()
    image = bytearray(fs.context.buffer)
    rev0 = int.from_bytes(image[0:4], 'little')
    rev1 = int.from_bytes(image[4096:4100], 'little')
    if (rev1 - rev0) & 0xFFFFFFFF >= 0x80000000:  # block 0 newer: one more commit
        fs = new_fs(prog_size=4096, context=UserContext(buffer=image))
        write(fs, '/keep2.txt', b'keep two\n')
        fs.unmount()
        image = bytearray(fs.context.buffer)
    rev0 = int.from_bytes(image[0:4], 'little')
    rev1 = int.from_bytes(image[4096:4100], 'little')
    assert (rev1 - rev0) & 0xFFFFFFFF < 0x80000000, 'block 1 should be the newer superblock'
    erased = bytearray(image)
    erased[0:4096] = b'\xff' * 4096
    store('stale0_erased', bytes(erased), block_size=4096)
    garbage = bytearray(image)
    garbage[0:4096] = noise(0xdead, 4096)
    store('stale0_garbage', bytes(garbage), block_size=4096)

    pending_move_fixtures()


class FailingContext(UserContext):
    """Fails the `fail_at`-th program call, like power loss mid-commit."""

    def __init__(self, buffer: bytearray, fail_at: int | None = None) -> None:
        super().__init__(buffer=buffer)
        self.progs = 0
        self.fail_at = fail_at

    def prog(self, cfg, block, off, data):
        self.progs += 1
        if self.fail_at is not None and self.progs == self.fail_at:
            return -5  # LFS_ERR_IO
        return super().prog(cfg, block, off, data)


def pending_move_fixtures() -> None:
    """A rename across directories interrupted between its two commits.

    The first commit adds the entry to the destination and records in the
    global state that the source id is to be deleted; the second deletes the
    source. Between them the file is physically in both directories and only
    the global state says which copy is real.
    """
    fs = new_fs()
    fs.mkdir('/src')
    fs.mkdir('/dst')
    write(fs, '/src/moved.txt', lines('pending', 2000))
    write(fs, '/src/stays.txt', b'stays\n')
    write(fs, '/dst/other.txt', b'other\n')
    write(fs, '/src/zlast.txt', b'after the moved id\n')
    fs.unmount()
    base = bytes(fs.context.buffer)

    ctx = FailingContext(bytearray(base))
    fs = new_fs(context=ctx)
    fs.rename('/src/moved.txt', '/dst/moved.txt')
    fs.unmount()
    total = ctx.progs

    found = {}
    for fail_at in range(1, total + 1):
        ctx = FailingContext(bytearray(base), fail_at)
        fs = new_fs(context=ctx)
        try:
            fs.rename('/src/moved.txt', '/dst/moved.txt')
            continue  # not interrupted
        except LittleFSError:
            pass
        image = bytes(ctx.buffer)
        check = new_fs(context=UserContext(buffer=bytearray(image)))
        paths = {f'{root.strip("/")}/{f}'.lstrip('/') for root, _, files in check.walk('/') for f in files}
        check.unmount()
        if 'dst/moved.txt' in paths and 'src/moved.txt' not in paths and image.count(b'moved.txt') >= 2:
            found[fail_at] = image
            if len(found) == 2:
                break
    if not found:
        print('  (no interrupted-rename state reached; pending move fixtures skipped)')
        return
    for i, (fail_at, image) in enumerate(found.items()):
        store('pending_move' if i == 0 else 'pending_move_partial', image, block_size=4096)

    # littlefs's own read path applies the pending move as a hole at the moved
    # id, which also hides the entry after it (`src/stays.txt` above) until the
    # next write completes the move. This is the listing after that write —
    # the state the Dart reader reports for the pending image, minus the
    # marker file.
    image = bytearray(next(iter(found.values())))
    fs = new_fs(context=UserContext(buffer=image))
    write(fs, '/recovered.txt', b'the write that completed the move\n')
    fs.unmount()
    store('pending_move_recovered', bytes(image), block_size=4096)


DART2JS_FIXTURES = ('small', 'log_prog16', 'stale0_erased', 'pending_move', 'pending_move_recovered')


def dart2js_fixtures() -> None:
    """Inline a subset for the browser test, which cannot read files."""
    import base64
    out = ['// GENERATED by test/fixtures/generate.py — do not edit.',
           '//',
           '// A subset of the fixtures, base64-encoded for the dart2js test, which',
           '// has no dart:io. Keys are `<name>.bin.gz`, `<name>.tar.gz` and',
           '// `<name>.list.txt` with the same contents as the files in test/fixtures.',
           'const Map<String, String> dart2jsFixtures = {']
    for name in DART2JS_FIXTURES:
        for suffix in ('.bin.gz', '.tar.gz', '.list.txt'):
            data = base64.b64encode((HERE / f'{name}{suffix}').read_bytes()).decode()
            out.append(f"  '{name}{suffix}': '{data}',")  # one line each, as dart format wants it
    out.append('};')
    (HERE.parent / 'dart2js_fixtures.dart').write_text('\n'.join(out) + '\n')


if __name__ == '__main__':
    os.chdir(HERE)
    for stale in HERE.glob('*.bin.gz'):
        stale.unlink()
    print('CLI trees:')
    cli_fixtures()
    print('littlefs logs:')
    log_fixtures()
    dart2js_fixtures()
