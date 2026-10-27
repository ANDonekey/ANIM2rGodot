#!/usr/bin/env python3
"""Batch pre-render every distinct (model, pose-state) used in the sce.

States are enumerated by replaying the sce record stream: 0x52 loads a
model, 0x7c plays an em label - full poses (18 vars) replace the state,
partial sets merge into it. Each distinct state becomes one idle-loop
WebP (emote_anim.build_frames + lossy encode).

Output: psb_out/emote_webp/<Model>_<hash8>.webp
Manifest: psb_out/emote_states.json [{model, vars, plays, file}]
Resumable: existing non-empty files are skipped.
"""
import hashlib
import json
import os
import struct
import sys
from collections import Counter, defaultdict
from multiprocessing import Pool

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, 're'))
sys.path.insert(0, os.path.join(BASE, 'pipeline'))
import sce_parse as P  # noqa: E402
import sce_token as T  # noqa: E402
from emote_anim import build_frames, encode  # noqa: E402
from emote_render import Model  # noqa: E402

OUT_DIR = os.path.join(BASE, 'psb_out', 'emote_webp')
MANIFEST = os.path.join(BASE, 'psb_out', 'emote_states.json')


def enumerate_states():
    d = open(os.path.join(BASE, 're', 'sce_orig_dec.bin'), 'rb').read()
    lt_off, pool_off = struct.unpack_from('<II', d, 0)
    _, segs = T.segments(d, lt_off, pool_off)
    pool = P.load_pool(d, pool_off)
    poses = json.load(open(os.path.join(BASE, 'psb_out', 'em_poses.json'),
                           encoding='utf-8'))['poses']
    model, state, cnt = None, {}, Counter()
    for a, b in segs:
        recs, _ = P.parse_segment(d, a, b)
        for r in recs:
            if r.op == 0x52:
                model = P.pool_str(pool, r.ops[1]).replace('.psb', '')
                state = {}
            elif r.op == 0x7c and model:
                e = poses.get(P.pool_str(pool, r.ops[1]))
                if e is None:
                    continue
                pv = e['vars']
                state = dict(pv) if len(pv) >= 18 else {**state, **pv}
                cnt[(model, tuple(sorted(state.items())))] += 1
    return cnt


def state_name(model, key):
    h = hashlib.md5(repr(key).encode()).hexdigest()[:8]
    return f'{model}_{h}'


def work_model(args):
    model, items = args
    done, failed = [], []
    mdir = os.path.join(BASE, 'psb_out', model)
    try:
        mdl = Model(mdir)
    except Exception as e:  # noqa: BLE001
        return [(model, k, n, None, f'model load: {e}') for k, n in items]
    for key, plays in items:
        name = state_name(model, key)
        out = os.path.join(OUT_DIR, name + '.webp')
        if os.path.exists(out) and os.path.getsize(out) > 0:
            done.append((model, key, plays, name))
            continue
        try:
            frames, _box = build_frames(mdl, dict(key))
            encode(frames, out)
            done.append((model, key, plays, name))
        except Exception as e:  # noqa: BLE001
            failed.append((model, key, plays, None, str(e)))
    return [(m, k, n, nm, None) for m, k, n, nm in done] + failed


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    cnt = enumerate_states()
    by_model = defaultdict(list)
    for (model, key), n in cnt.items():
        if os.path.isdir(os.path.join(BASE, 'psb_out', model)):
            by_model[model].append((key, n))
    tasks = sorted(by_model.items(), key=lambda kv: -sum(n for _, n in kv[1]))
    total = sum(len(v) for v in by_model.values())
    print(f'{total} states across {len(tasks)} models', flush=True)
    results = []
    with Pool(2) as pool:
        for i, res in enumerate(pool.imap_unordered(work_model, tasks)):
            results.extend(res)
            ok = sum(1 for r in results if r[3])
            print(f'[{i + 1}/{len(tasks)} models] states ok so far: {ok}', flush=True)
    manifest = []
    failures = []
    for model, key, plays, name, err in results:
        if err:
            failures.append({'model': model, 'vars': dict(key),
                             'plays': plays, 'error': err})
        else:
            manifest.append({'model': model, 'vars': dict(key),
                             'plays': plays, 'file': name + '.webp'})
    manifest.sort(key=lambda e: -e['plays'])
    json.dump({'states': manifest, 'failures': failures},
              open(MANIFEST, 'w'), ensure_ascii=False, indent=1)
    print(f'DONE: {len(manifest)} ok, {len(failures)} failed -> {MANIFEST}',
          flush=True)


if __name__ == '__main__':
    main()
