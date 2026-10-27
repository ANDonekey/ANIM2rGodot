#!/usr/bin/env python3
"""Pre-render an E-mote idle loop as an animated WebP.

Architecture (v2, built for batch economics):
  Only THREE stills are evaluated through the real deformation system:
  eyes open (pose as-is), half blink (face_eye_open +10), closed (+20 -
  crosses the eyelid keyframe steps in the eye motions). All loop frames
  are sway/breathing transforms of these stills; the blink window swaps
  the still open -> half -> closed -> half -> open.
  Breathing/sway is a global transform because the fine body deformation
  in this engine is mesh-carried (keyframes differ only in mesh.bp),
  which the evaluator does not warp.

Usage: emote_anim.py <model_dir> <out.webp> [pose_label]
Batch driver: emote_batch.py
"""
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emote_render import Model, composite, parts_box  # noqa: E402
from PIL import Image  # noqa: E402

FPS = 8
FRAMES = 24           # 3.0 s loop
BLINK_AT = 0.76
BLINK_LEN = 0.17      # ~0.5 s window: half, closed, closed, half


def blink_bump(phase):
    d = (phase - BLINK_AT) / BLINK_LEN
    if 0.0 <= d <= 1.0:
        return 20.0 * math.sin(math.pi * d) ** 2
    return 0.0


def build_frames(model, base_vars, frames=FRAMES):
    base = model.metadata.get('base') or {}
    chara = base.get('chara') or 'all_parts'
    motion = base.get('motion') or 'タイムライン構造'

    def vis(vars_):
        return [p for p in model.collect(chara, motion, vars_)
                if p['visible'] and p['opacity'] > 0]

    def with_bump(v, bump):
        v = dict(v or {})
        if bump:
            v['face_eye_open'] = v.get('face_eye_open', 0.0) + bump
        return v

    probes = [vis(with_bump(base_vars, b)) for b in (0.0, 10.0, 20.0)]
    boxes = [parts_box(p) for p in probes]
    min_x = min(b[0] for b in boxes)
    min_y = min(b[1] for b in boxes)
    max_x = max(b[0] + b[2] for b in boxes)
    max_y = max(b[1] + b[3] for b in boxes)
    box = (min_x - 4, min_y - 4,
           int(max_x - min_x) + 8, int(max_y - min_y) + 8)
    W, H = box[2], box[3]
    stills = {0.0: composite(probes[0], box),
              10.0: composite(probes[1], box),
              20.0: composite(probes[2], box)}

    out = []
    for i in range(frames):
        phase = i / frames
        bump = blink_bump(phase)
        src = stills[0.0 if bump < 5 else 10.0 if bump < 15 else 20.0]
        s = 1.0 + 0.006 * math.sin(2 * math.pi * phase)
        dx = 1.5 * math.sin(2 * math.pi * phase + 0.7)
        dy = 1.0 * math.sin(2 * math.pi * phase)
        canvas = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        nh = max(1, int(round(H * s)))
        scaled = src.resize((W, nh), Image.BICUBIC)
        canvas.alpha_composite(scaled, (int(round(dx)), H - nh + int(round(dy))))
        out.append(canvas)
    return out, box


def encode(frames, out_path, fps=FPS, quality=90):
    frames[0].save(out_path, save_all=True, append_images=frames[1:],
                   duration=int(1000 / fps), loop=0, lossless=False,
                   quality=quality, method=4)
    return os.path.getsize(out_path)


def build(model_dir, out_path, base_vars=None, quality=90):
    model = Model(model_dir)
    frames, box = build_frames(model, base_vars)
    size = encode(frames, out_path, quality=quality)
    return box, size


if __name__ == '__main__':
    model_dir, out = sys.argv[1], sys.argv[2]
    vars_ = None
    if len(sys.argv) > 3:
        poses = json.load(open(os.path.join(
            os.path.dirname(model_dir.rstrip('/')), 'em_poses.json'),
            encoding='utf-8'))['poses']
        entry = poses[sys.argv[3]]
        vars_ = entry['vars'] if isinstance(entry, dict) else entry
    box, size = build(model_dir, out, vars_)
    print(f'canvas {box[2]}x{box[3]}, webp {size/1e6:.2f} MB -> {out}')
