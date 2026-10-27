#!/usr/bin/env python3
"""Batch-export all PSBs in assets/psb/ to psb_out/<model>/:
  tree.json        full object tree (resources as {"$res": idx})
  atlas_<tex>.png  each texture page declared in source (tex / tex#NNN),
                   decoded from its chunk per texture.width/height (RGBA8)
  icons/<tex>_<id>.png  each part rect from that page's icon table
  meta.json        screenSize, textures, icon count, chunk info
Resumable: skips models whose meta.json has "textures".
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from psb_parse import Psb  # noqa: E402
from PIL import Image  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'assets', 'psb')
OUT = os.path.join(ROOT, 'psb_out')


def export_model(name):
    model = name[:-4]
    mdir = os.path.join(OUT, model)
    meta_path = os.path.join(mdir, 'meta.json')
    if os.path.exists(meta_path):
        old = json.load(open(meta_path))
        if 'textures' in old:
            return old
    os.makedirs(os.path.join(mdir, 'icons'), exist_ok=True)
    # clear stale artifacts from the v1 exporter (atlas.png, icons/<id>.png)
    stale = os.path.join(mdir, 'atlas.png')
    if os.path.exists(stale):
        os.remove(stale)
    idir = os.path.join(mdir, 'icons')
    for old in os.listdir(idir):
        if '_' not in old:
            os.remove(os.path.join(idir, old))
    psb = Psb(open(os.path.join(SRC, name), 'rb').read())
    root = psb.root()
    with open(os.path.join(mdir, 'tree.json'), 'w', encoding='utf-8') as f:
        json.dump(root, f, ensure_ascii=False, default=str)
    source = root.get('source') or {}
    tex_keys = sorted(k for k in source if k.startswith('tex'))
    textures, n_icons = [], 0
    for tk in tex_keys:
        tex = source[tk] or {}
        tinfo = tex.get('texture') or {}
        w, h = int(tinfo.get('width', 0)), int(tinfo.get('height', 0))
        res = (tinfo.get('pixel') or {}).get('$res')
        if not w or not h or res is None:
            continue
        raw = psb.chunk_bytes(res)
        # texture.type says "RGBA8" but bytes are stored B,G,R,A
        # (verified against the game's CG art; straight RGBA reads
        # give blue skin)
        atlas = Image.frombytes('RGBA', (w, h), raw[:w * h * 4], 'raw', 'BGRA')
        atlas_name = f'atlas_{tk.replace("#", "")}.png'
        atlas.save(os.path.join(mdir, atlas_name))
        icons = tex.get('icon') or {}
        cnt = 0
        for iid, r in icons.items():
            iw, ih = int(r['width']), int(r['height'])
            if iw <= 0 or ih <= 0:
                continue
            x, y = int(r['left']), int(r['top'])
            atlas.crop((x, y, x + iw, y + ih)).save(
                os.path.join(mdir, 'icons', f'{tk.replace("#", "")}_{iid}.png'))
            cnt += 1
        textures.append({'tex': tk, 'w': w, 'h': h, 'res': res,
                         'atlas': atlas_name, 'icons': cnt})
        n_icons += cnt
    meta = {'model': model, 'screenSize': root.get('screenSize'),
            'textures': textures, 'icons': n_icons,
            'chunks': len(psb.chunks),
            'names': len(psb.names), 'strings': len(psb.strings)}
    with open(meta_path, 'w', encoding='utf-8') as f:
        json.dump(meta, f, ensure_ascii=False)
    return meta


def main():
    os.makedirs(OUT, exist_ok=True)
    manifest = []
    for name in sorted(os.listdir(SRC)):
        if name.endswith('.psb'):
            meta = export_model(name)
            manifest.append(meta)
            print('done', meta['model'], 'tex', len(meta['textures']),
                  'icons', meta['icons'], flush=True)
    with open(os.path.join(OUT, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print('EXPORT_ALL_DONE', len(manifest))


if __name__ == '__main__':
    main()
