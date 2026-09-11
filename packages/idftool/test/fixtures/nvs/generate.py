#!/usr/bin/env python3
"""Regenerate the NVS fixtures from the python `idftool` (the oracle for the Dart port).

Run from this directory. Needs `idftool` on PATH and, for the version-1 image, an ESP-IDF
python env with `esp_idf_nvs_partition_gen` (the first one found under /opt/espressif).

For every image it writes:
  <name>.bin          the image itself
  <name>.pages.txt    `idftool print-nvs --pages -f <name>.bin` minus its first (filename) line
  <name>.extract.csv  `idftool extract-nvs -f <name>.bin`
and for every edit, <name>.log with the change report `set-nvs` printed.
"""
import glob
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)


def run(*args, check=True):
    proc = subprocess.run(args, capture_output=True, text=True)
    if check and proc.returncode != 0:
        sys.exit(f"{' '.join(args)} failed:\n{proc.stdout}\n{proc.stderr}")
    return proc


def blob(n, seed):
    return bytes((i * 7 + seed) & 0xFF for i in range(n)).hex()


def csv(name, rows):
    with open(name, 'w') as f:
        f.write('key,type,encoding,value\n')
        for row in rows:
            f.write(','.join(row) + '\n')


def capture(name):
    out = run('idftool', 'print-nvs', '--pages', '-f', f'{name}.bin').stdout
    with open(f'{name}.pages.txt', 'w') as f:
        f.write(out.split('\n', 1)[1])
    run('idftool', 'extract-nvs', '-f', f'{name}.bin', f'{name}.extract.csv')


def create(name, size):
    run('idftool', 'create-nvs', f'{name}.csv', '-o', f'{name}.bin', '--size', size)
    capture(name)


def edit(name, source, *specs, rewrite=False, expect_fail=False):
    args = ['idftool', 'set-nvs', '-f', f'{source}.bin', '-o', f'{name}.bin']
    if rewrite:
        args.append('--rewrite')
    proc = run(*args, *specs, check=False)
    if expect_fail:
        if proc.returncode == 0:
            sys.exit(f'{name}: expected failure')
        with open(f'{name}.log', 'w') as f:
            f.write(proc.stdout + proc.stderr)
        return
    if proc.returncode != 0:
        sys.exit(f'{name} failed:\n{proc.stdout}\n{proc.stderr}')
    # Drop the "Editing ..." and "Wrote ..." lines, which carry filenames.
    lines = [l for l in proc.stdout.splitlines() if not l.startswith(('Editing ', 'Wrote '))]
    with open(f'{name}.log', 'w') as f:
        f.write('\n'.join(lines) + '\n')
    capture(name)


# -- generated images ----------------------------------------------------------------------

csv('basic.csv', [
    ('storage', 'namespace', '', ''),
    ('device_id', 'data', 'u32', '12345'),
    ('device_name', 'data', 'string', 'idftool-test'),
    ('counter', 'data', 'u16', '7'),
])
create('basic', '0x6000')

# Every type, two namespaces, a string spanning several entries, small blobs in each encoding.
csv('types.csv', [
    ('# a comment line', '', '', ''),
    ('nums', 'namespace', '', ''),
    ('u8_max', 'data', 'u8', '255'),
    ('i8_min', 'data', 'i8', '-128'),
    ('u16_v', 'data', 'u16', '65535'),
    ('i16_v', 'data', 'i16', '-2'),
    ('u32_v', 'data', 'u32', '4294967295'),
    ('i32_v', 'data', 'i32', '-2147483648'),
    ('u64_max', 'data', 'u64', '18446744073709551615'),
    ('i64_min', 'data', 'i64', '-9223372036854775808'),
    ('i64_pos', 'data', 'i64', '1234567890123'),
    ('text', 'namespace', '', ''),
    ('short', 'data', 'string', 'hi'),
    ('empty', 'data', 'string', ''),
    ('exact31', 'data', 'string', 'a' * 31),
    ('exact32', 'data', 'string', 'b' * 32),
    ('long', 'data', 'string', 'The quick brown fox jumps over the lazy dog. ' * 3),
    ('utf8', 'data', 'string', 'héllo wörld ✓'),
    ('bin', 'namespace', '', ''),
    ('hex', 'data', 'hex2bin', 'deadbeef00ff'),
    ('b64', 'data', 'base64', 'aGVsbG8gd29ybGQ='),
    ('empty', 'data', 'hex2bin', ''),
    ('exact32', 'data', 'hex2bin', blob(32, 1)),
    ('big', 'data', 'hex2bin', blob(500, 2)),
])
create('types', '0x6000')

# Re-opening a namespace. nvs_partition_gen has a bug here: `write_namespace` records the
# re-opened index but `write_entry` ignores it and uses the *latest* namespace, so python
# files `late_u8` under `second`. The Dart generator files it under `first`, as the CSV says.
csv('reopen.csv', [
    ('first', 'namespace', '', ''),
    ('a', 'data', 'u8', '1'),
    ('second', 'namespace', '', ''),
    ('b', 'data', 'u8', '2'),
    ('first', 'namespace', '', ''),
    ('late_u8', 'data', 'u8', '3'),
])
create('reopen', '0x3000')

# Blobs that need several pages, plus the largest string nvs_partition_gen accepts. (NVS itself
# takes 4000 bytes including the NUL, but the generator's `entry_num + total >= max_entries`
# check refuses anything that would exactly fill a page, so 3967 + NUL = 124 data entries is
# its real ceiling.)
csv('bigblob.csv', [
    ('blobs', 'namespace', '', ''),
    ('first', 'data', 'hex2bin', blob(6000, 3)),
    ('maxstr', 'data', 'string', 'x' * 3967),
    ('second', 'data', 'hex2bin', blob(4500, 4)),
    ('tail', 'data', 'u8', '9'),
])
create('bigblob', '0x8000')

# Read-only sizes (< 0x3000): the generator reserves no page and pads nothing.
create_ro = csv('readonly.csv', [
    ('ro', 'namespace', '', ''),
    ('a', 'data', 'u8', '1'),
])
create('readonly', '0x2000')

# 0x3000 has two usable pages = 252 entries. Fill 250 of them.
csv('nearfull.csv', [('f', 'namespace', '', '')] +
    [(f'k{i:03d}', 'data', 'u8', str(i & 0xFF)) for i in range(249)])
create('nearfull', '0x3000')

# -- edits -----------------------------------------------------------------------------------

edit('edit-append', 'types', 'nums:new_u8:u8=200', 'other:hello:string=world',
     'bin:more:blob=0102030405')
edit('edit-replace', 'types', 'nums:u8_max=1', 'text:long=changed', 'bin:big:blob=' + blob(700, 5),
     'nums:i64_pos=1234567890123')
edit('edit-delete', 'types', '-d', 'nums:u8_max', '-d', 'text:long', '-d', 'bin:big',
     '-d', 'nums:missing')
edit('edit-bigblob', 'bigblob', 'blobs:first:blob=' + blob(5000, 6))
edit('edit-bigblob2', 'edit-bigblob', 'blobs:first:blob=' + blob(4100, 7), '-d', 'blobs:second')
edit('edit-rewrite', 'types', 'nums:u8_max=2', 'zzz:k:u32=1', '-d', 'text:short', rewrite=True)
edit('edit-compact', 'nearfull', 'f:k000=100', 'f:k001=101', 'f:k002=102', 'f:k003=103')
edit('edit-nospace', 'nearfull', *[f'f:n{i}:u8=1' for i in range(10)], expect_fail=True)

# -- version 1 -------------------------------------------------------------------------------

envs = sorted(glob.glob('/opt/espressif/python_env/*/bin/python'))
if envs:
    csv('v1.csv', [
        ('v1', 'namespace', '', ''),
        ('num', 'data', 'i32', '-5'),
        ('str', 'data', 'string', 'version one'),
        ('blob', 'data', 'hex2bin', blob(100, 8)),
        ('bigblob', 'data', 'base64', 'QUJD' * 400),
    ])
    run(envs[-1], '-m', 'esp_idf_nvs_partition_gen', 'generate', 'v1.csv', 'v1.bin', '0x4000',
        '--version', '1', '--outdir', HERE)
    capture('v1')
    edit('edit-v1', 'v1', 'v1:blob:blob=' + blob(50, 9), 'v1:new:string=added')

print('ok')
