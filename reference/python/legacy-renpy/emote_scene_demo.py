#!/usr/bin/env python3
"""Build a standalone Ren'Py demo project for ONE sce label, with the
E-mote comment lines (0x52 load / 0x7c pose) rewritten into real
show statements driving the pre-rendered idle-loop WebPs.

Usage: emote_scene_demo.py [label_name]     (default 001-000)
Output: renpy/emote_demo/  (self-contained mini project)
Missing state WebPs are rendered on demand (~5 s each).
"""
import json
import os
import re
import shutil
import struct
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(BASE, 're'))
sys.path.insert(0, os.path.join(BASE, 'pipeline'))
import sce_parse as P  # noqa: E402
import sce_token as T  # noqa: E402
from emote_batch import state_name  # noqa: E402

LABEL = sys.argv[1] if len(sys.argv) > 1 else '001-000'
SRC_PROJ = os.path.join(BASE, 'renpy', 'kabe2_zh')
OUT_PROJ = os.path.join(BASE, 'renpy', 'emote_demo')
GAME = os.path.join(OUT_PROJ, 'game')
SPRITE_H = 700  # on-screen sprite height at 1280x720


def orig_events(label):
    """Replay the ORIG sce segment for `label`: ordered emote events
    [('load', model), ('pose', model, state_key, pose_label), ...]."""
    d = open(os.path.join(BASE, 're', 'sce_orig_dec.bin'), 'rb').read()
    lt_off, pool_off = struct.unpack_from('<II', d, 0)
    labels, segs = T.segments(d, lt_off, pool_off)
    pool = P.load_pool(d, pool_off)
    off2name = {}
    for name, off in labels:
        off2name.setdefault(off, name)
    seg = None
    for a, b in segs:
        if off2name.get(a) == label:
            seg = (a, b)
            break
    if seg is None:
        raise SystemExit(f'label {label} not found')
    poses = json.load(open(os.path.join(BASE, 'psb_out', 'em_poses.json'),
                           encoding='utf-8'))['poses']
    recs, _ = P.parse_segment(d, *seg)
    events, model, state = [], None, {}
    for r in recs:
        if r.op == 0x52:
            model = P.pool_str(pool, r.ops[1]).replace('.psb', '')
            state = {}
            events.append(('load', model))
        elif r.op == 0x7c and model:
            lbl = P.pool_str(pool, r.ops[1])
            pv = poses[lbl]['vars']
            state = dict(pv) if len(pv) >= 18 else {**state, **pv}
            events.append(('pose', model, tuple(sorted(state.items())), lbl))
    return events


def ensure_webp(model, key):
    name = state_name(model, key)
    path = os.path.join(BASE, 'psb_out', 'emote_webp', name + '.webp')
    if not (os.path.exists(path) and os.path.getsize(path) > 0):
        from emote_anim import build_frames, encode
        from emote_render import Model
        mdl = Model(os.path.join(BASE, 'psb_out', model))
        frames, _ = build_frames(mdl, dict(key))
        encode(frames, path)
        print(f'rendered missing state {name}')
    return name


def extract_label_block(script, label_ident):
    m = re.search(rf'^label {re.escape(label_ident)}:\n(.*?)(?=^label |\Z)',
                  script, re.M | re.S)
    if not m:
        raise SystemExit(f'{label_ident} not in script.rpy')
    return m.group(0).rstrip().splitlines()


def main():
    script = open(os.path.join(SRC_PROJ, 'game', 'script.rpy'),
                  encoding='utf-8').read()
    ident = 'l_' + LABEL.replace('-', '_')
    block = extract_label_block(script, ident)

    # cut the block at the trailing conditional jump (scene end for demo)
    cut = len(block)
    for i, ln in enumerate(block):
        if re.match(r'\s*if lf_0 != 1:', ln):
            cut = i
            break
    block = block[:cut]

    events = orig_events(LABEL)
    ev_i = 0
    used_states = []          # ordered unique webp names
    out_lines = []
    for ln in block:
        m52 = re.search(r'# \[img op 0x52\]', ln)
        m7c = re.search(r'# \[img op 0x7c\]', ln)
        out_lines.append(ln)
        if m52 or m7c:
            ev = events[ev_i]
            ev_i += 1
            assert (m52 and ev[0] == 'load') or (m7c and ev[0] == 'pose'), \
                f'event mismatch at {ev_i}: {ev} vs {ln}'
            if ev[0] == 'pose':
                _, model, key, _lbl = ev
                name = ensure_webp(model, key)
                if name not in used_states:
                    used_states.append(name)
                img = 'emote_' + name.lower()
                out_lines.append(
                    f'    show {img} as emote_char at emote_fit_{name.lower()}, emote_stage')
                out_lines.append('    with Dissolve(0.2)')
    assert ev_i == len(events), f'{ev_i} != {len(events)} events consumed'
    out_lines.append('    "（演示场景结束）"')
    out_lines.append('    return')
    # rename the label line
    out_lines[0] = 'label demo_scene:'

    # sub-labels called by the block (verbatim; SleepTime2000 stubbed:
    # its `jump Loop` is engine main-loop machinery, meaningless in a
    # linear demo - treat as return)
    subs = []
    for sub in ('EmSetNegative', 'SleepTime2000', 'ResetSelect'):
        body = extract_label_block(script, sub)
        if sub == 'SleepTime2000':
            body = [ln for ln in body if 'jump Loop' not in ln]
            body.append('    return')
        subs += body + ['']

    # assets referenced by the block
    scenes = sorted(set(re.findall(r'^\s*scene ([a-z0-9_]+)', '\n'.join(block), re.M)))
    musics = sorted(set(re.findall(r'play music "(audio/[^"]+)"', '\n'.join(block))))
    voices = sorted(set(re.findall(r'voice "(audio/[^"]+)"', '\n'.join(block))))

    if os.path.isdir(OUT_PROJ):
        shutil.rmtree(OUT_PROJ)
    os.makedirs(os.path.join(GAME, 'emote_webp'))
    os.makedirs(os.path.join(GAME, 'images'))
    os.makedirs(os.path.join(GAME, 'audio', 'bgm'))
    os.makedirs(os.path.join(GAME, 'audio', 'voice'))

    opts = open(os.path.join(SRC_PROJ, 'game', 'options.rpy'), encoding='utf-8').read()
    opts = opts.replace('GPT汉化 (skeleton)', 'GPT汉化 - E-mote 演示')
    open(os.path.join(GAME, 'options.rpy'), 'w', encoding='utf-8').write(opts)
    shutil.copy(os.path.join(SRC_PROJ, 'game', 'characters.rpy'),
                os.path.join(GAME, 'characters.rpy'))

    img_defs = open(os.path.join(SRC_PROJ, 'game', 'images.rpy'), encoding='utf-8').read()
    keep = []
    for nm in scenes:
        m = re.search(rf'^image {nm} = "images/([^"]+)"', img_defs, re.M)
        assert m, f'no image def for {nm}'
        keep.append(f'image {nm} = "images/{m.group(1)}"')
        shutil.copy(os.path.join(SRC_PROJ, 'game', 'images', m.group(1)),
                    os.path.join(GAME, 'images', m.group(1)))
    open(os.path.join(GAME, 'images.rpy'), 'w', encoding='utf-8').write(
        '# demo subset\n' + '\n'.join(keep) + '\n')

    for rel in musics + voices:
        shutil.copy(os.path.join(SRC_PROJ, 'game', rel),
                    os.path.join(GAME, rel))

    from PIL import Image
    em_lines = ['# E-mote pre-rendered sprites for this scene',
                'transform emote_stage:',
                '    anchor (0.5, 1.0)',
                '    xalign 0.5',
                '    yalign 1.0',
                '']
    for name in used_states:
        src = os.path.join(BASE, 'psb_out', 'emote_webp', name + '.webp')
        shutil.copy(src, os.path.join(GAME, 'emote_webp', name + '.webp'))
        h = Image.open(src).size[1]
        em_lines.append(f'image emote_{name.lower()} = "emote_webp/{name}.webp"')
        em_lines.append(f'transform emote_fit_{name.lower()}:')
        em_lines.append(f'    zoom {SPRITE_H / h:.4f}')
    open(os.path.join(GAME, 'emote_images.rpy'), 'w', encoding='utf-8').write(
        '\n'.join(em_lines) + '\n')

    head = ['# Standalone E-mote scene demo - generated by',
            '# pipeline/emote_scene_demo.py from the kabe2_zh conversion.',
            '# The [img op 0x52/0x7c] comment lines of the original block',
            '# are followed by real show statements driving idle-loop WebPs.',
            '',
            'label start:',
            '    jump demo_scene',
            '']
    open(os.path.join(GAME, 'script.rpy'), 'w', encoding='utf-8').write(
        '\n'.join(head + out_lines + [''] + subs) + '\n')
    print(f'demo built: {OUT_PROJ}')
    print(f'states used: {used_states}')
    print(f'scenes: {scenes}, music: {musics}, voices: {len(voices)}')


if __name__ == '__main__':
    main()
