#!/usr/bin/env python3
"""E-mote pose evaluator - Python port of FreeMote's StaticMotionPainterCore,
extended with the variable/parameterize evaluation the static painter lacks:

- Every layer may carry `parameterize` = index into its motion's parameter
  list; the layer's frameList is then evaluated at the timeline position
  of the CURRENT VALUE of that parameter's variable:
      t = (v - rangeBegin) * division / (rangeEnd - rangeBegin)
- Tween (type 3) keyframes interpolate numeric fields (coord/angle/zoom/
  slant/opacity/origin) linearly; discrete fields come from the earlier key.
- metadata.selectorControl maps selector variables (arm_type, face_type)
  onto fade_* variables (selected option -> onValue, others -> offValue).
- Measured storage quirks: coord components are int16-wrapped
  (65019 -> -517); int angles and parameter ranges in (180,255] are
  byte-wrapped negatives (252 -> -4, 226 -> -30).

Usage: emote_render.py <model_dir> [out.png] [pose_label]
  model_dir = psb_out/<Model>; pose_label looks up ../em_poses.json.
"""
import json
import math
import os
import sys

from PIL import Image

FT_NULL, FT_SINGLE, FT_CONT, FT_TWEEN = 0, 1, 2, 3
TR_FLIP, TR_ANGLE, TR_ZOOM, TR_SLANT = 0, 1, 2, 3

_LERP_FIELDS = ('ox', 'oy', 'angle', 'zx', 'zy', 'sx', 'sy', 'opa')


def mat_mul(a, b):
    return (a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
            a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3])


IDENT = (1.0, 0.0, 0.0, 1.0)


def calc_affine(order, fx, fy, angle, zx, zy, sx, sy):
    m = IDENT
    for t in order:
        if t == TR_FLIP:
            if fx:
                m = (-m[0], -m[1], m[2], m[3])
            if fy:
                m = (m[0], m[1], -m[2], -m[3])
        elif t == TR_ZOOM:
            m = (m[0] * zx, m[1] * zx, m[2] * zy, m[3] * zy)
        elif t == TR_ANGLE:
            if abs(angle) > 0.0001:
                rad = angle * math.pi * 2 / 360.0
                c, s = math.cos(rad), math.sin(rad)
                m = (c * m[0] - s * m[2], c * m[1] - s * m[3],
                     s * m[0] + c * m[2], s * m[1] + c * m[3])
        elif t == TR_SLANT:
            if abs(sx) > 0.0001 or abs(sy) > 0.0001:
                m = (m[0] + sx * m[2], m[1] + sx * m[3],
                     sy * m[0] + m[2], sy * m[1] + m[3])
    return m


def unwrap_byte(v):
    v = float(v)
    if v == int(v) and 180 < v <= 255:
        return v - 256
    return v


def unwrap_coord(v):
    if isinstance(v, (int, float)) and 60000 <= v < 65536:
        return v - 65536
    return v


class Ctx:
    __slots__ = ('x', 'y', 'z', 'opacity', 'visible', 'matrix')

    def __init__(self, x=0.0, y=0.0, z=0.0, opacity=255, visible=True,
                 matrix=IDENT):
        self.x, self.y, self.z = x, y, z
        self.opacity, self.visible, self.matrix = opacity, visible, matrix


class Model:
    def __init__(self, model_dir):
        self.dir = model_dir
        self.tree = json.load(open(os.path.join(model_dir, 'tree.json'),
                                   encoding='utf-8'))
        self.objects = self.tree.get('object') or {}
        self.source = self.tree.get('source') or {}
        self.metadata = self.tree.get('metadata') or {}
        self._icons = {}

    # ---- resources ----
    def icon(self, tex_key, icon_id):
        key = (tex_key, icon_id)
        if key in self._icons:
            return self._icons[key]
        result = None
        tex = self.source.get(tex_key)
        if isinstance(tex, dict):
            info = (tex.get('icon') or {}).get(icon_id)
            if info is not None:
                fname = f"{tex_key.replace('#', '')}_{icon_id}.png"
                path = os.path.join(self.dir, 'icons', fname)
                if os.path.exists(path):
                    img = Image.open(path).convert('RGBA')
                    # byte-wrapped negative origins (255 on a 17px icon
                    # means -1); legit center origins have size >= value
                    ox = float(info.get('originX', 0))
                    oy = float(info.get('originY', 0))
                    if ox == int(ox) and 180 < ox <= 255 and ox > img.size[0]:
                        ox -= 256
                    if oy == int(oy) and 180 < oy <= 255 and oy > img.size[1]:
                        oy -= 256
                    result = (img, ox, oy)
        self._icons[key] = result
        return result

    # ---- motions / variables ----
    def motion(self, chara, name):
        grp = self.objects.get(chara)
        if isinstance(grp, dict):
            return (grp.get('motion') or {}).get(name)
        return None

    @staticmethod
    def axis_time(param, value):
        rb = unwrap_byte(param.get('rangeBegin', 0))
        re_ = unwrap_byte(param.get('rangeEnd', 0))
        div = float(param.get('division', 0))
        if abs(re_ - rb) < 0.0001 or div <= 0:
            return 0.0
        t = (float(value) - rb) * div / (re_ - rb)
        return max(0.0, min(div, t))

    def ambient_time(self, mo, vars_):
        """A motion instance's un-parameterized layers sit at the axis
        position of its first enabled parameter (0 if it has none)."""
        for p in (mo.get('parameter') or []):
            if isinstance(p, dict) and p.get('enabled', 1):
                return self.axis_time(p, vars_.get(p.get('id'), 0.0))
        return 0.0

    def effective_vars(self, raw):
        vars_ = dict(raw or {})
        for sel in self.metadata.get('selectorControl') or []:
            if not isinstance(sel, dict) or not sel.get('enabled', 1):
                continue
            chosen = vars_.get(sel.get('label'), 0)
            for idx, opt in enumerate(sel.get('optionList') or []):
                if not isinstance(opt, dict):
                    continue
                vars_[opt.get('label')] = (opt.get('onValue', 0)
                                           if chosen == idx
                                           else opt.get('offValue', 1))
        return vars_

    # ---- frame evaluation ----
    def _frame_content(self, frame_list, time):
        idx = -1
        for i, fr in enumerate(frame_list):
            if isinstance(fr, dict) and float(fr.get('time', 0)) <= time:
                idx = i
            else:
                break
        if idx < 0:
            return None
        fr = frame_list[idx]
        ftype = int(fr.get('type', FT_NULL))
        if ftype == FT_NULL:
            return None
        if ftype == FT_SINGLE and abs(float(fr.get('time', 0)) - time) >= 0.001:
            return None
        content = fr.get('content')
        if not isinstance(content, dict):
            return None
        base = self._read_frame(content)
        if ftype == FT_TWEEN and idx + 1 < len(frame_list):
            nxt = frame_list[idx + 1]
            ncontent = nxt.get('content') if isinstance(nxt, dict) else None
            if isinstance(ncontent, dict):
                t0 = float(fr.get('time', 0))
                t1 = float(nxt.get('time', 0))
                if t1 > t0:
                    u = (time - t0) / (t1 - t0)
                    if 0 < u < 1:
                        over = self._read_frame(ncontent)
                        for k in _LERP_FIELDS:
                            base[k] = base[k] + (over[k] - base[k]) * u
                        for k in ('cx', 'cy', 'cz'):
                            base[k] = base[k] + (over[k] - base[k]) * u
        return base

    @staticmethod
    def _read_frame(content):
        coord = [unwrap_coord(v) for v in (content.get('coord') or [0, 0, 0])]

        def g(k, d):
            v = content.get(k, d)
            return float(v) if isinstance(v, (int, float)) else d

        angle = g('angle', 0.0)
        if angle == int(angle) and 180 < angle <= 255:
            angle -= 256
        return {
            'src': content.get('src') if isinstance(content.get('src'), str) else '',
            'icon': str(content['icon']) if content.get('icon') is not None else None,
            'ox': g('ox', 0.0), 'oy': g('oy', 0.0),
            'cx': float(coord[0]) if len(coord) > 0 else 0.0,
            'cy': float(coord[1]) if len(coord) > 1 else 0.0,
            'cz': float(coord[2]) if len(coord) > 2 else 0.0,
            'opa': g('opa', 255),
            'fx': int(g('fx', 0)) != 0, 'fy': int(g('fy', 0)) != 0,
            'angle': angle,
            'zx': g('zx', 1.0), 'zy': g('zy', 1.0),
            'sx': g('sx', 0.0), 'sy': g('sy', 0.0),
        }

    def _build_ctx(self, layer, frame, parent):
        order = layer.get('transformOrder') or [TR_FLIP, TR_SLANT, TR_ZOOM, TR_ANGLE]
        local = calc_affine([int(x) for x in order], frame['fx'], frame['fy'],
                            frame['angle'], frame['zx'], frame['zy'],
                            frame['sx'], frame['sy'])
        m = parent.matrix
        tx = m[0] * frame['cx'] + m[1] * frame['cy']
        ty = m[2] * frame['cx'] + m[3] * frame['cy']
        inherit_all = all(layer.get(k, 1) for k in (
            'inheritFlipX', 'inheritFlipY', 'inheritAngle', 'inheritZoomX',
            'inheritZoomY', 'inheritSlantX', 'inheritSlantY'))
        if layer.get('inheritOpacity', 1):
            opa = int(round(parent.opacity * frame['opa'] / 255.0))
        else:
            opa = int(frame['opa'])
        return Ctx(parent.x + tx, parent.y + ty, parent.z + frame['cz'],
                   opa, parent.visible,
                   mat_mul(parent.matrix, local) if inherit_all else local)

    # ---- tree walk ----
    def collect(self, chara, motion_name, vars_=None):
        self._out = []
        vars_ = self.effective_vars(vars_)
        mo = self.motion(chara, motion_name)
        if isinstance(mo, dict):
            self._travel(mo.get('layer'), chara, mo, vars_, Ctx(), set())
        self._out.sort(key=lambda r: r['z'])
        return self._out

    def _travel(self, node, chara, mo, vars_, ctx, stack):
        if isinstance(node, list):
            for item in node:
                self._travel(item, chara, mo, vars_, ctx, stack)
            return
        if not isinstance(node, dict):
            return
        cur = ctx
        if isinstance(node.get('frameList'), list):
            params = (mo.get('parameter') or []) if isinstance(mo, dict) else []
            pk = node.get('parameterize')
            if isinstance(pk, int) and 0 <= pk < len(params):
                t = self.axis_time(params[pk], vars_.get(params[pk].get('id'), 0.0))
            else:
                t = self.ambient_time(mo, vars_) if isinstance(mo, dict) else 0.0
            frame = self._frame_content(node['frameList'], t)
            if frame is not None:
                cur = self._build_ctx(node, frame, ctx)
                self._try_add(node, frame, vars_, cur, stack)
            if node.get('exportSelf', 1):
                self._travel(node.get('children'), chara, mo, vars_, cur, stack)
                self._travel(node.get('layer'), chara, mo, vars_, cur, stack)
            return
        if node.get('exportSelf', 1):
            self._travel(node.get('children'), chara, mo, vars_, ctx, stack)
            self._travel(node.get('layer'), chara, mo, vars_, ctx, stack)

    def _try_add(self, layer, frame, vars_, ctx, stack):
        src = frame['src']
        if not src:
            return
        if src in self.source and frame['icon'] is not None:
            got = self.icon(src, frame['icon'])
            if got is not None:
                img, iox, ioy = got
                if frame['icon'].startswith('icon') and frame['icon'] != 'icon1':
                    return
                self._out.append({
                    'img': img, 'label': layer.get('label', ''),
                    'x': ctx.x, 'y': ctx.y, 'z': ctx.z,
                    'matrix': ctx.matrix,
                    'ox': frame['ox'] + iox, 'oy': frame['oy'] + ioy,
                    'opacity': ctx.opacity, 'visible': ctx.visible})
        elif src in self.objects and frame['icon'] is not None:
            key = f'{src}/{frame["icon"]}'
            if key in stack:
                return
            sub = self.motion(src, frame['icon'])
            if isinstance(sub, dict):
                stack.add(key)
                self._travel(sub.get('layer'), src, sub, vars_, ctx, stack)
                stack.discard(key)


def part_corners(p):
    m = p['matrix']
    w, h = p['img'].size
    pts = []
    for (px, py) in ((0, 0), (w, 0), (w, h), (0, h)):
        dx, dy = px - p['ox'], py - p['oy']
        pts.append((p['x'] + m[0] * dx + m[1] * dy,
                    p['y'] + m[2] * dx + m[3] * dy))
    return pts


def parts_box(parts):
    all_pts = [pt for p in parts for pt in part_corners(p)]
    min_x = min(pt[0] for pt in all_pts)
    min_y = min(pt[1] for pt in all_pts)
    max_x = max(pt[0] for pt in all_pts)
    max_y = max(pt[1] for pt in all_pts)
    return (min_x, min_y,
            max(1, math.ceil(max_x - min_x)), max(1, math.ceil(max_y - min_y)))


def composite(parts, box):
    """Draw parts onto a canvas fixed by box=(min_x, min_y, W, H)."""
    min_x, min_y, W, H = box
    canvas = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    parts = [p for p in parts if p['visible'] and p['opacity'] > 0]
    for p in parts:
        img = p['img']
        if p['opacity'] < 255:
            img = img.copy()
            alpha = img.getchannel('A').point(
                lambda a, o=p['opacity']: a * o // 255)
            img.putalpha(alpha)
        m = p['matrix']
        det = m[0] * m[3] - m[1] * m[2]
        if abs(det) < 1e-9:
            continue
        inv = (m[3] / det, -m[1] / det, -m[2] / det, m[0] / det)
        bx = p['x'] - min_x
        by = p['y'] - min_y
        pts = part_corners(p)
        x0 = int(math.floor(min(pt[0] for pt in pts) - min_x))
        y0 = int(math.floor(min(pt[1] for pt in pts) - min_y))
        x1 = int(math.ceil(max(pt[0] for pt in pts) - min_x))
        y1 = int(math.ceil(max(pt[1] for pt in pts) - min_y))
        bw, bh = max(1, x1 - x0), max(1, y1 - y0)
        a, b, d, e = inv
        c = p['ox'] + inv[0] * (x0 - bx) + inv[1] * (y0 - by)
        f = p['oy'] + inv[2] * (x0 - bx) + inv[3] * (y0 - by)
        warped = img.transform((bw, bh), Image.AFFINE, (a, b, c, d, e, f),
                               resample=Image.BICUBIC)
        canvas.alpha_composite(warped, (x0, y0))
    return canvas


def render(model_dir, out_path, vars_=None, chara=None, motion_name=None,
           box=None):
    model = Model(model_dir)
    base = model.metadata.get('base') or {}
    chara = chara or base.get('chara') or 'all_parts'
    motion_name = motion_name or base.get('motion') or 'タイムライン構造'
    parts = [p for p in model.collect(chara, motion_name, vars_)
             if p['visible'] and p['opacity'] > 0]
    if not parts:
        raise SystemExit('no drawable parts collected')
    if box is None:
        box = parts_box(parts)
    canvas = composite(parts, box)
    canvas.save(out_path)
    return len(parts), (box[2], box[3])


if __name__ == '__main__':
    model_dir = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else '/tmp/emote_render.png'
    vars_ = None
    if len(sys.argv) > 3:
        poses = json.load(open(os.path.join(
            os.path.dirname(model_dir.rstrip('/')), 'em_poses.json'),
            encoding='utf-8'))['poses']
        entry = poses[sys.argv[3]]
        vars_ = entry['vars'] if isinstance(entry, dict) else entry
        print('pose', sys.argv[3], 'vars:', vars_)
    n, size = render(model_dir, out, vars_)
    print(f'parts drawn: {n}, canvas: {size}, -> {out}')
