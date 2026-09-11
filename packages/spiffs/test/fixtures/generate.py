#!/usr/bin/env python3
"""Regenerate the SPIFFS test fixtures with the python idftool CLI (the oracle).

Each case becomes a directory here holding:

    config.json   image size and the ``--spiffs-*`` options used to build it
    src/          the tree that was packed (absent for the empty case)
    image.bin.gz  ``idftool create-fs`` output, gzipped (a 1 MiB image is mostly 0xFF)
    listing.txt   ``idftool print-fs`` output

``idftool extract-fs`` is run as well and asserted to give back ``src/`` exactly, so the
Dart tests only need ``src/`` as the expected contents.
"""
import gzip
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def pattern(n: int, seed: int) -> bytes:
    # Deterministic, non-repeating-looking bytes that don't compress to nothing.
    out = bytearray(n)
    x = seed * 2654435761 + 12345
    for i in range(n):
        x = (x * 1103515245 + 12345) & 0xFFFFFFFF
        out[i] = (x >> 16) & 0xFF
    return bytes(out)


def text(n: int, seed: int) -> bytes:
    line = f"line from file {seed}: the quick brown fox jumps over the lazy dog\n".encode()
    return (line * (n // len(line) + 1))[:n]


CASES = {
    # A blank volume: only the per-block magic distinguishes it from erased flash.
    'empty': dict(size=0x10000, files={}),
    # Small files, including the interesting sizes around one data page (251 bytes of
    # content per 256-byte page).
    'small': dict(size=0x10000, files={
        'hello.txt': b'hello spiffs\n',
        'zero.bin': b'',
        'one.bin': b'\x00',
        'page-1.bin': pattern(250, 1),
        'page.bin': pattern(251, 2),
        'page+1.bin': pattern(252, 3),
        'two-pages.bin': pattern(502, 4),
        'notes.txt': text(700, 5),
    }),
    # Files needing several index pages: a head index page holds 103 page references,
    # each further one 124. 40 KiB is 164 data pages; 100 KiB is 408.
    'large': dict(size=0x40000, files={
        'forty-k.bin': pattern(40 * 1024, 10),
        'hundred-k.bin': pattern(100 * 1024, 11),
        'tail.txt': text(300, 12),
        'text-20k.txt': text(20 * 1024, 13),
    }),
    # SPIFFS is flat: these are just names containing '/'.
    'nested': dict(size=0x10000, files={
        'a/b/c/deep.txt': b'deep\n',
        'a/b/sibling.txt': b'sibling\n',
        'a/top.txt': b'top\n',
        'root.txt': b'root\n',
        'z/last.bin': pattern(600, 20),
    }),
    # Names at the 32-character limit, counting the leading '/' SPIFFS stores.
    'names': dict(size=0x10000, files={
        'x': b'x\n',
        'abcdefghijklmnopqrstuvwxyz01234': b'31 chars plus the slash\n',
        'dir/abcdefghijklmnopqrstuvwxyz0': b'nested at the limit\n',
        'UPPER.CASE.EXT': b'case\n',
        'with space.txt': b'space\n',
    }),
    # A 64 KiB image filled to a few pages short of its 240 usable pages.
    'tiny-full': dict(size=0x10000, files={
        'big.bin': pattern(200 * 251, 30),
        'rest.bin': pattern(30 * 251 - 7, 31),
    }),
    # A 1 MiB image with a file spanning many blocks.
    'mib': dict(size=0x100000, files={
        'three-hundred-k.bin': pattern(300 * 1024 + 17, 40),
        'small.txt': text(100, 41),
        'sub/medium.bin': pattern(5000, 42),
    }),
    # Non-default geometry.
    'page512': dict(size=0x10000, options=['--spiffs-page-size', '512'], files={
        'a.bin': pattern(2000, 50),
        'b.txt': text(507, 51),
        'c.bin': pattern(508, 52),
    }),
    'page128': dict(size=0x10000, options=['--spiffs-page-size', '128'], files={
        'a.bin': pattern(2000, 60),
        'b.txt': text(123, 61),
        'c.bin': pattern(124, 62),
    }),
    'block8k': dict(size=0x20000, options=['--spiffs-block-size', '8192'], files={
        'a.bin': pattern(9000, 70),
        'b.txt': text(50, 71),
    }),
    'no-magic-len': dict(size=0x10000, options=['--no-spiffs-use-magic-len'], files={
        'a.txt': text(80, 80),
    }),
    'no-magic': dict(size=0x10000, options=['--no-spiffs-use-magic'], files={
        'a.txt': text(80, 90),
        'b.bin': pattern(1000, 91),
    }),
    'namelen64-meta0': dict(
        size=0x10000, options=['--spiffs-obj-name-len', '64', '--spiffs-meta-len', '0'],
        files={
            'a-name-that-is-far-longer-than-thirty-two-characters.txt': text(40, 100),
            'b.bin': pattern(3000, 101),
        }),
    'meta16': dict(size=0x10000, options=['--spiffs-meta-len', '16'], files={
        'a.bin': pattern(3000, 110),
    }),
}


def run(*args: str) -> str:
    result = subprocess.run(['idftool', *args], check=True, capture_output=True, text=True)
    return result.stdout


def tree(root: Path) -> dict:
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in sorted(root.rglob('*')) if p.is_file()}


def main():
    only = set(sys.argv[1:])
    for name, case in CASES.items():
        if only and name not in only:
            continue
        case_dir = HERE / name
        if case_dir.exists():
            shutil.rmtree(case_dir)
        src = case_dir / 'src'
        src.mkdir(parents=True)
        for path, content in case['files'].items():
            target = src / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)

        options = case.get('options', [])
        image = case_dir / 'image.bin'
        run('create-fs', str(src), '-o', str(image), '--size', hex(case['size']), '--type', 'spiffs', *options)
        listing = run('print-fs', '-f', str(image), '--type', 'spiffs', *options)
        # print-fs echoes the file name on its first line; keep only the table.
        (case_dir / 'listing.txt').write_text(listing.split('\n', 1)[1])

        extracted = case_dir / 'extracted'
        run('extract-fs', '-f', str(image), '--type', 'spiffs', *options, str(extracted))
        assert tree(extracted) == case['files'], f'{name}: extract-fs did not round-trip'
        shutil.rmtree(extracted)

        with open(image, 'rb') as f, open(case_dir / 'image.bin.gz', 'wb') as out:
            # mtime=0 keeps the archive reproducible.
            with gzip.GzipFile(fileobj=out, mode='wb', mtime=0) as g:
                shutil.copyfileobj(f, g)
        image.unlink()
        if not case['files']:
            src.rmdir()

        (case_dir / 'config.json').write_text(json.dumps({
            'size': case['size'],
            'options': options,
        }, indent=2) + '\n')
        print(f'{name}: {len(case["files"])} files')


if __name__ == '__main__':
    main()
