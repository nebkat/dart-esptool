#!/usr/bin/env python3
"""Generate the FAT fixtures with python idftool, the oracle the Dart tests compare against.

Run with a python that can import ``idftool`` (the idftool repo's venv):

    /Users/nebkat/Work/Troo/idftool/.venv/bin/python test/fixtures/generate.py

For each case this writes ``<name>.bin.gz`` (the image ``create-fs`` produces),
``<name>.raw.bin.gz`` (the bare filesystem ``wl.unwrap`` recovers, for wear-levelled
cases) and ``<name>.json`` with the sources that went in, the options, and the
listing (with content digests) python reads back out. Timestamps are pinned and the
timezone forced to UTC so the images are reproducible.
"""
import base64
import gzip
import hashlib
import json
import os
import random
import shutil
import tempfile
import time
from pathlib import Path

os.environ['TZ'] = 'UTC'
time.tzset()

from idftool.fs import collect, fatfs, wl  # noqa: E402

HERE = Path(__file__).parent

# 2024-03-05 06:07:08 UTC; every entry gets its own time a minute and a second apart so
# per-entry timestamps are exercised, not just one shared value.
BASE_MTIME = 1709618828
VOLUME_ID = 0x12345678
DEVICE_ID = 0x9ABCDEF0


def blob(seed: int, size: int) -> bytes:
    return random.Random(seed).randbytes(size)


def basic_tree() -> dict:
    return {
        'README.TXT': b'plain 8.3 name\n',
        # (Not 'readme.txt': the tree is written to a case-insensitive filesystem on macOS.)
        'read me.txt': b'collides with README.TXT in 8.3 form\n',
        'Hello World.txt': b'space and mixed case\n',
        'héllo wörld.txt': b'latin-1 letters that code page 437 has\n',
        'файл.txt': b'cyrillic, nothing in cp437\n',
        '\U0001F600 emoji.txt': b'astral plane character\n',
        'a_very_long_file_name_with_many_characters.log': b'four long name entries\n',
        'exactly13char': b'one long name entry with no terminator\n',
        'exactly26chars_long_name_x': b'two long name entries with no terminator\n',
        'longname1.txt': b'1\n',
        'longname2.txt': b'2\n',
        'longname3.txt': b'3\n',
        'longname4.txt': b'4\n',
        'LONGNA~4.TXT': b'literal tilde name\n',
        'longname5.txt': b'has to skip ~4\n',
        '.hidden': b'leading dot\n',
        'dots.in.name.txt': b'dots\n',
        'noext': b'lower case, no extension\n',
        'NOEXT2': b'upper case, no extension\n',
        'x': b'x',
        'Ab': b'ab\n',
        'Straße.txt': b'python upper-cases the sharp s to SS\n',
        'ﬁle.txt': b'and expands the fi ligature\n',
        'empty.bin': b'',
        'onecluster.bin': blob(1, 4096),
        'dir1/inner.txt': b'in dir1\n',
        'dir1/sub/deep/deeper/deepest/file.txt': b'five levels down\n',
        'Long Directory Name/inner file.txt': b'in a long-named directory\n',
        'empty_dir/': None,
        'dir1/sub/also empty/': None,
    }


def spanning_tree() -> dict:
    return {
        'big.bin': blob(2, 50000),
        'exact.bin': blob(3, 3 * 4096),
        'plus1.bin': blob(4, 4097),
        'one.bin': b'!',
        'zero.bin': b'',
        'after.txt': b'allocated after the big ones\n',
    }


def many_tree() -> dict:
    tree = {f'r{i:03d}.txt': f'root file {i}\n'.encode() for i in range(200)}
    tree.update({f'many/file number {i:03d}.txt': f'file {i}\n'.encode() for i in range(300)})
    tree['many/z_last.txt'] = b'after the directory grew\n'
    tree['a/b/c/d/e/f/g.txt'] = b'seven deep\n'
    return tree


def fat16_tree() -> dict:
    tree = spanning_tree()
    tree['huge.bin'] = blob(5, 100000)  # 196 clusters of 512
    tree.update({f'many/file number {i:03d}.txt': f'file {i}\n'.encode() for i in range(200)})
    tree['nested/dir/file.txt'] = b'nested\n'
    tree['nested/dir/Another Long Name.dat'] = blob(6, 1000)
    return tree


CASES = [
    # name, tree, size, options passed to fatfs.create
    ('empty_256k_wl', {}, 0x40000, {}),
    ('basic_256k_wl', basic_tree(), 0x40000, {}),
    ('basic_256k_raw', basic_tree(), 0x40000, {'wear_levelling': False}),
    ('spanning_1m_wl', spanning_tree(), 0x100000, {}),
    ('many_4m_wl', many_tree(), 0x400000, {}),
    ('fat16_4m_512_raw', fat16_tree(), 0x400000, {'sector_size': 512, 'wear_levelling': False}),
    ('fat16_4m_512_wl', fat16_tree(), 0x400000, {'sector_size': 512}),
    ('spc2_512k_wl', basic_tree(), 0x80000, {'sectors_per_cluster': 2}),
    ('forced16_4m_512_raw', spanning_tree(), 0x400000, {'sector_size': 512, 'wear_levelling': False, 'fat_type': 16}),
    ('tiny_128k_wl', {'a.txt': b'hello\n', 'dir/Long Name.txt': b'world\n', 'dir/b.bin': blob(7, 5000)}, 0x20000, {}),
]

# Geometries to compare with the Dart solver, as (size, sector size, sectors per cluster,
# forced FAT type). No image is built for these: python's pyfatfs decides the FAT width
# before it has subtracted the root directory sectors, so for cluster counts within a
# root directory's worth of the FAT12/16 boundary (the "gap" the solver pads for) it
# treats a FAT12 volume as FAT16 and writes a corrupt image — only the geometry is a
# usable oracle there.
GEOMETRIES = [
    (0x40000, 0x1000, 1, None), (0x3C000, 0x1000, 1, None), (0x100000, 0x1000, 1, None),
    (0x400000, 0x1000, 1, None), (0x400000, 0x1000, 2, None), (0x1000000, 0x1000, 1, None),
    (0x2000000, 0x1000, 1, None), (0x2000000, 0x1000, 4, None), (0x10000000, 0x1000, 1, None),
    (0x10000000, 0x1000, 16, None), (0x400000, 512, 1, None), (0x400000, 512, 8, None),
    (4144 * 512, 512, 1, None), (4141 * 512, 512, 1, None), (4150 * 512, 512, 1, None),
    (0x1004000, 0x1000, 1, None), (0x1008000, 0x1000, 1, None), (0x100C000, 0x1000, 1, None),
    (0x400000, 512, 1, 16), (0x400000, 512, 1, 12), (0x400000, 0x1000, 1, 16), (0x40000, 0x1000, 1, 12),
    (0x8000, 0x1000, 1, None), (0x4000, 0x1000, 1, None), (0x100000, 1024, 1, None), (0x100000, 2048, 2, None),
]


def geometries() -> list:
    out = []
    for size, sector_size, spc, fat_type in GEOMETRIES:
        case = {'size': size, 'sector_size': sector_size, 'sectors_per_cluster': spc, 'fat_type': fat_type}
        try:
            g = fatfs._geometry(size, sector_size, spc, fatfs.FAT_COUNT, fatfs.ROOT_ENTRIES, fat_type)
            case['geometry'] = {'bits': g['bits'], 'fat_size': g['fat_size'], 'clusters': g['clusters']}
        except Exception as e:
            case['error'] = str(e)
        out.append(case)
    return out


def inline_dart() -> str:
    """A Dart source with the tiny fixture inlined, for the browser test."""
    image = base64.b64encode((HERE / 'tiny_128k_wl.bin.gz').read_bytes()).decode()
    raw = base64.b64encode((HERE / 'tiny_128k_wl.raw.bin.gz').read_bytes()).decode()
    fixture = (HERE / 'tiny_128k_wl.json').read_text()
    return (
        "// GENERATED by test/fixtures/generate.py — do not edit.\n"
        "//\n"
        "// The tiny_128k_wl fixture inlined so the browser tests, which cannot read\n"
        "// files, still compare against a python-built image.\n"
        "library;\n\n"
        f"const String tinyImageGzBase64 = '{image}';\n\n"
        f"const String tinyRawGzBase64 = '{raw}';\n\n"
        f"const String tinyFixtureJson = r'''{fixture}''';\n"
    )


def materialise(tree: dict, root: Path) -> None:
    for i, (path, data) in enumerate(sorted(tree.items())):
        target = root / path.rstrip('/')
        if data is None:
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    # Directories last: creating files inside them bumps their mtime.
    paths = sorted(root.rglob('*'), key=lambda p: -len(p.parts))
    for i, path in enumerate(sorted(paths)):
        os.utime(path, (BASE_MTIME + i * 61, BASE_MTIME + i * 61))


def generate(name: str, tree: dict, size: int, options: dict) -> None:
    workdir = Path(tempfile.mkdtemp(prefix='fatfs-fixture-'))
    try:
        materialise(tree, workdir)
        sources = collect(str(workdir))
        opts = {'volume_id': VOLUME_ID, 'device_id': DEVICE_ID, **options}
        image = fatfs.create(sources, size, **opts)
        wear_levelling = opts.get('wear_levelling', True)

        # What python reads back, as a digest: the bytes themselves are already in `sources`.
        with fatfs.mount(image, wear_levelling=wear_levelling) as volume:
            entries = [{'path': e.path, 'is_dir': e.is_dir, 'size': e.size,
                        'sha256': None if e.is_dir else hashlib.sha256(volume.read(e)).hexdigest()}
                       for e in volume.entries()]

        fixture = {
            'size': size,
            'options': {k: v for k, v in opts.items()},
            'geometry': fatfs.describe(size, **opts),
            'sources': [
                {'path': s.path, 'is_dir': s.is_dir, 'mtime': int(s.mtime),
                 'data': None if s.is_dir else base64.b64encode(s.read()).decode()}
                for s in sources
            ],
            'entries': entries,
        }
        (HERE / f'{name}.json').write_text(json.dumps(fixture, indent=1, ensure_ascii=False) + '\n')
        (HERE / f'{name}.bin.gz').write_bytes(gzip.compress(image, mtime=0))
        if wear_levelling:
            (HERE / f'{name}.raw.bin.gz').write_bytes(gzip.compress(wl.unwrap(image), mtime=0))
        print(f'{name}: {fixture["geometry"]}, {len(entries)} entries')
    finally:
        shutil.rmtree(workdir)


if __name__ == '__main__':
    for stale in HERE.glob('*.bin.gz'):
        stale.unlink()
    for stale in HERE.glob('*.json'):
        stale.unlink()
    for case in CASES:
        generate(*case)
    (HERE / 'geometries.json').write_text(json.dumps(geometries(), indent=1) + '\n')
    (HERE.parent / 'inline_fixtures.dart').write_text(inline_dart())
