#!/usr/bin/env python3
"""Batch-unpack the kabe2 (ANIM teamMM) full package from game_full.zip.

Outputs under ../assets/:
  images/<name>.png   decrypted cg/*.gax
  psb/<name>.psb      split cg/psbpack.dat (raw PSB, E-mote - later stage)
  bgm/<name>.ogg      bgm/*.eog with 8-byte CRM header stripped
  voice/<name>.ogg    voice/kabe2_wave.pck split + header stripped
  movie/<name>.mpg    copied as-is
  data/sce_gpt_dec.bin, data/define_gpt_dec.bin  decrypted root dats
  data/manifest.json  counts / sizes / per-file problems

GFilePack format (shared by .pck and psbpack.dat):
  [u32 count][count x (u32 zero, u32 offset, u32 size)]
  [NUL-terminated name table][blobs at absolute offsets]
"""
import io
import json
import os
import struct
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gsecret_fast import decrypt_fast  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZIP = os.path.join(ROOT, 'game_full.zip')
OUT = os.path.join(ROOT, 'assets')

PNG_SIG = b'\x89PNG\r\n\x1a\n'
manifest = {'images': [], 'psb': [], 'bgm': [], 'voice': [], 'emote_csv': [],
            'movie': [], 'data': [], 'problems': []}


def norm(name):
    return name.replace('\\', '/')


def split_pack(stream, count_fmt_at=0):
    """Read a GFilePack from a seekable binary stream positioned anywhere;
    returns (names, [(offset, size), ...]). Stream must support seek/read."""
    stream.seek(0)
    count = struct.unpack('<I', stream.read(4))[0]
    entries = []
    for _ in range(count):
        _zero, off, size = struct.unpack('<III', stream.read(12))
        entries.append((off, size))
    names = []
    for _ in range(count):
        buf = bytearray()
        while True:
            ch = stream.read(1)
            if ch in (b'\x00', b''):
                break
            buf += ch
        names.append(buf.decode('ascii', 'replace'))
    return names, entries


def strip_eog(blob, ctx):
    if blob[:4] != b'CRM\x00':
        manifest['problems'].append(f'{ctx}: missing CRM header')
        return blob
    if blob[8:12] != b'OggS':
        manifest['problems'].append(f'{ctx}: no OggS after CRM header')
    return blob[8:]


def main():
    for d in ('images', 'psb', 'bgm', 'voice', 'emote_csv', 'movie', 'data'):
        os.makedirs(os.path.join(OUT, d), exist_ok=True)
    z = zipfile.ZipFile(ZIP)
    names = {norm(n): n for n in z.namelist()}

    # ---- cg/*.gax -> images/*.png ----
    gax = sorted(n for n in names if n.startswith('cg/') and n.endswith('.gax'))
    for i, n in enumerate(gax):
        base = os.path.basename(n)[:-4]
        dst = os.path.join(OUT, 'images', base + '.png')
        if os.path.exists(dst) and os.path.getsize(dst) > 8:
            with open(dst, 'rb') as f:
                if f.read(8) == PNG_SIG:
                    manifest['images'].append(base + '.png')
                    continue
        dec = decrypt_fast(z.read(names[n]))
        if dec[:8] != PNG_SIG:
            manifest['problems'].append(f'{n}: decrypted data is not PNG')
        with open(dst, 'wb') as f:
            f.write(dec)
        manifest['images'].append(base + '.png')
        if (i + 1) % 50 == 0:
            print(f'images {i + 1}/{len(gax)}', flush=True)
    print(f'images done: {len(gax)}', flush=True)

    # ---- cg/psbpack.dat -> psb/*.psb ----
    with z.open(names['cg/psbpack.dat']) as stream:
        pnames, pentries = split_pack(stream)
        for nm, (off, size) in zip(pnames, pentries):
            dst = os.path.join(OUT, 'psb', nm)
            if os.path.exists(dst) and os.path.getsize(dst) == size:
                manifest['psb'].append(nm)
                continue
            stream.seek(off)
            blob = stream.read(size)
            if blob[:4] != b'PSB\x00':
                manifest['problems'].append(f'psb {nm}: bad magic {blob[:4]!r}')
            with open(dst, 'wb') as f:
                f.write(blob)
            manifest['psb'].append(nm)
    print(f'psb done: {len(pnames)}', flush=True)

    # ---- bgm/*.eog -> bgm/*.ogg ----
    for n in sorted(n for n in names if n.startswith('bgm/') and n.endswith('.eog')):
        base = os.path.basename(n)[:-4]
        ogg = strip_eog(z.read(names[n]), n)
        with open(os.path.join(OUT, 'bgm', base + '.ogg'), 'wb') as f:
            f.write(ogg)
        manifest['bgm'].append(base + '.ogg')
    print('bgm done', flush=True)

    # ---- voice/kabe2_wave.pck -> voice/*.ogg ----
    with z.open(names['voice/kabe2_wave.pck']) as stream:
        vnames, ventries = split_pack(stream)
        for i, (nm, (off, size)) in enumerate(zip(vnames, ventries)):
            if nm.endswith('.csv'):
                # E-mote lip-sync curve data, companion of the same-named .eog
                dst = os.path.join(OUT, 'emote_csv', nm)
                if os.path.exists(dst) and os.path.getsize(dst) == size:
                    manifest['emote_csv'].append(nm)
                    continue
                stream.seek(off)
                with open(dst, 'wb') as f:
                    f.write(stream.read(size))
                manifest['emote_csv'].append(nm)
                continue
            out = nm[:-4] + '.ogg' if nm.endswith('.eog') else nm + '.ogg'
            dst = os.path.join(OUT, 'voice', out)
            if os.path.exists(dst) and os.path.getsize(dst) == size - 8:
                manifest['voice'].append(out)
                continue
            stream.seek(off)
            blob = stream.read(size)
            ogg = strip_eog(blob, f'voice {nm}')
            with open(dst, 'wb') as f:
                f.write(ogg)
            manifest['voice'].append(out)
            if (i + 1) % 3000 == 0:
                print(f'voice {i + 1}/{len(vnames)}', flush=True)
    print(f'voice done: {len(vnames)}', flush=True)

    # ---- movie/*.mpg -> copy ----
    for n in sorted(n for n in names if n.startswith('movie/') and n.endswith('.mpg')):
        base = os.path.basename(n)
        dstp = os.path.join(OUT, 'movie', base)
        if os.path.exists(dstp) and os.path.getsize(dstp) == z.getinfo(names[n]).file_size:
            manifest['movie'].append(base)
            continue
        with z.open(names[n]) as src, open(dstp, 'wb') as dst:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                dst.write(chunk)
        manifest['movie'].append(base)
    print('movie done', flush=True)

    # ---- root dats (GPT variant shipped in the zip) ----
    for src_name, out_name in (('kabe2_sce.dat', 'sce_gpt_dec.bin'),
                               ('kabe2_define.dat', 'define_gpt_dec.bin')):
        dec = decrypt_fast(z.read(names[src_name]))
        with open(os.path.join(OUT, 'data', out_name), 'wb') as f:
            f.write(dec)
        manifest['data'].append(out_name)
    print('data done', flush=True)

    with open(os.path.join(OUT, 'data', 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump({k: (len(v) if isinstance(v, list) else v)
                   for k, v in manifest.items()}, f, ensure_ascii=False, indent=1)
        f.write('\n')
    with open(os.path.join(OUT, 'data', 'problems.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(manifest['problems']))
    print('PROBLEMS:', len(manifest['problems']))
    for p in manifest['problems'][:20]:
        print('  ', p)
    print('UNPACK_ALL_DONE', flush=True)


if __name__ == '__main__':
    main()
