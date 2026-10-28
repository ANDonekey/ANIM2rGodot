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

Advanced rendering (v2, semantics pinned from the sample data itself;
FreeMote's painter ignores all of these):
- Frame content `mask` is a field-PRESENCE bitmask (proven: its value is a
  deterministic function of the content's key set: coord=0x2, color=0x200,
  opa=0x400, bm=0x20000, motion=0x80000, mesh=0x2000000). It is NOT a
  stencil id; missing fields just fall back to defaults.
- Mesh warp: frame content `mesh.bp` is 32 floats = a 4x4 grid of points
  in icon-normalized space (identity = uniform grid, values may leave
  [0,1]). Rendered as a cubic Bezier patch through those points
  ("bp" = Bezier points; layers carry meshDivision = tessellation
  density). A warp applies in the frame space of the layer carrying it,
  to that layer's own icon AND to its whole subtree (this is how blank
  carrier layers like eye_pos warp the iris sub-motion). Tween keys
  interpolate bp componentwise (a missing bp means the identity grid).
- Stencil: a layer with `stencilCompositeMaskLayerList` (stencilType 5)
  clips its subtree to the union alpha of the parts emitted under the
  listed layer labels in the SAME motion instance (proven by the eye
  motions: iris layers under the stencil layer are clipped to the
  shirome + add_mask parts). `src = "blank"` parts are invisible
  procedural rectangles (icon name "W:H:OX:OY") - never drawn, but they
  count as mask geometry. stencilType 6 layers reference masks that do
  not exist in the same file and have no drawable subtree in the sample
  game; they stay no-ops.
- Evaluator-only extras for the player: `layer_offsets` (label -> (dx,
  dy)) adds a translation to matching layers (physics sway hooks).

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

# Tessellation segments per side for warped parts (Bezier patch grid).
WARP_SEG = 5

IDENT_GRID = tuple(v for r in range(4) for c in range(4)
                   for v in (c / 3.0, r / 3.0))


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
    # a coord component stored as a PSB int in (180, 255] is a
    # byte-wrapped negative (234 == -22); float-stored components are
    # genuine values
    if isinstance(v, int) and not isinstance(v, bool) and 180 < v <= 255:
        return v - 256
    if isinstance(v, (int, float)) and 60000 <= v < 65536:
        return v - 65536
    return v


def _bernstein(t):
    u = 1.0 - t
    return (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)


def bezier_patch(bp, u, v):
    """Evaluate the 4x4 Bezier patch bp (row-major, row = v) at (u, v);
    returns normalized (x, y)."""
    bu = _bernstein(u)
    bv = _bernstein(v)
    x = y = 0.0
    for r in range(4):
        for c in range(4):
            w = bv[r] * bu[c]
            x += w * bp[(r * 4 + c) * 2]
            y += w * bp[(r * 4 + c) * 2 + 1]
    return (x, y)


def warp_point(warp, px, py):
    """Apply one layer's warp (bp, w, h, ox, oy) to a point expressed in
    that layer's frame space."""
    bp, w, h, ox, oy = warp
    if w <= 0 or h <= 0:
        return (px, py)
    u = (px + ox) / w
    v = (py + oy) / h
    nx, ny = bezier_patch(bp, u, v)
    return (nx * w - ox, ny * h - oy)


def chain_point(segs, px, py):
    """Push a point through the segment chain (own layer first). Each seg
    is (cx, cy, matrix, warp|None): warp applies in the segment's frame
    space, then the segment's local affine maps to the parent frame."""
    for cx, cy, m, warp in reversed(segs):
        if warp is not None:
            px, py = warp_point(warp, px, py)
        px, py = cx + m[0] * px + m[1] * py, cy + m[2] * px + m[3] * py
    return (px, py)


def parse_blank(icon):
    """blank icon name 'W:H:OX:OY' -> (w, h, ox, oy) or None."""
    if not isinstance(icon, str):
        return None
    parts = icon.split(':')
    if len(parts) != 4:
        return None
    try:
        w, h, ox, oy = (float(p) for p in parts)
    except ValueError:
        return None
    return (w, h, ox, oy)


class Ctx:
    __slots__ = ('x', 'y', 'z', 'opacity', 'visible', 'matrix', 'segs',
                 'clip')

    def __init__(self, x=0.0, y=0.0, z=0.0, opacity=255, visible=True,
                 matrix=IDENT, segs=(), clip=None):
        self.x, self.y, self.z = x, y, z
        self.opacity, self.visible, self.matrix = opacity, visible, matrix
        self.segs = segs
        self.clip = clip


class _Instance:
    """One motion instantiation (top-level or via a reference layer):
    stencil mask labels referenced inside it + parts registered under
    those labels, in emission order."""
    __slots__ = ('referenced', 'registry')

    def __init__(self, referenced):
        self.referenced = referenced
        self.registry = {}


class Model:
    def __init__(self, model_dir):
        self.dir = model_dir
        self.tree = json.load(open(os.path.join(model_dir, 'tree.json'),
                                   encoding='utf-8'))
        self.objects = self.tree.get('object') or {}
        self.source = self.tree.get('source') or {}
        self.metadata = self.tree.get('metadata') or {}
        self._icons = {}
        self._ref_cache = {}
        self.layer_offsets = {}

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

    def icon_size(self, tex_key, icon_id):
        got = self.icon(tex_key, icon_id)
        if got is None:
            return None
        img, ox, oy = got
        return (img.size[0], img.size[1], ox, oy)

    # ---- motions / variables ----
    def motion(self, chara, name):
        grp = self.objects.get(chara)
        if isinstance(grp, dict):
            return (grp.get('motion') or {}).get(name)
        return None

    def referenced_labels(self, chara, name):
        key = (chara, name)
        if key in self._ref_cache:
            return self._ref_cache[key]
        refs = set()
        mo = self.motion(chara, name)
        if isinstance(mo, dict):
            def visit(node):
                if isinstance(node, dict):
                    lst = node.get('stencilCompositeMaskLayerList')
                    if isinstance(lst, list):
                        refs.update(x for x in lst if isinstance(x, str))
                    for k in ('children', 'layer'):
                        visit(node.get(k))
                elif isinstance(node, list):
                    for it in node:
                        visit(it)
            visit(mo.get('layer'))
        self._ref_cache[key] = refs
        return refs

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
                        bp_a = base['mesh_bp']
                        bp_b = over['mesh_bp']
                        if bp_a is not None or bp_b is not None:
                            ga = bp_a if bp_a is not None else IDENT_GRID
                            gb = bp_b if bp_b is not None else IDENT_GRID
                            base['mesh_bp'] = tuple(
                                ga[i] + (gb[i] - ga[i]) * u for i in range(32))
        return base

    @staticmethod
    def _read_frame(content):
        coord = [unwrap_coord(v) for v in (content.get('coord') or [0, 0, 0])]

        def g(k, d):
            v = content.get(k, d)
            return float(v) if isinstance(v, (int, float)) else d

        raw_angle = content.get('angle')
        angle = g('angle', 0.0)
        if isinstance(raw_angle, int) and 180 < angle <= 255:
            # proven byte-wrapped storage (int in (180, 255] means angle-256)
            angle -= 256
        elif angle > 180 or angle <= -180:
            # degree-form storage (e.g. float 350.0 means -10 degrees);
            # normalize so tween lerp takes the short arc
            angle = (angle + 180) % 360 - 180
        mesh = content.get('mesh')
        bp = None
        if isinstance(mesh, dict):
            raw_bp = mesh.get('bp')
            if isinstance(raw_bp, list) and len(raw_bp) == 32:
                bp = tuple(float(v) for v in raw_bp)
                if all(abs(bp[i] - IDENT_GRID[i]) < 1e-6 for i in range(32)):
                    bp = None
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
            'mesh_bp': bp,
            'bm': int(g('bm', 0)),
        }

    def _frame_warp(self, frame):
        """Warp descriptor (bp, w, h, ox, oy) for a frame, in its own
        frame space; None when the frame carries no mesh or its icon
        size is unknown (motion references have neither)."""
        bp = frame['mesh_bp']
        if bp is None:
            return None
        src = frame['src']
        if src == 'blank':
            dims = parse_blank(frame['icon'])
            if dims is None:
                return None
            w, h, ox, oy = dims
            return (bp, w, h, frame['ox'] + ox, frame['oy'] + oy)
        if src in self.source and frame['icon'] is not None:
            size = self.icon_size(src, frame['icon'])
            if size is None:
                return None
            w, h, iox, ioy = size
            return (bp, float(w), float(h),
                    frame['ox'] + iox, frame['oy'] + ioy)
        return None

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
        off = self.layer_offsets.get(layer.get('label'))
        ox = oy = 0.0
        if off:
            ox, oy = float(off[0]), float(off[1])
        seg = (frame['cx'] + ox, frame['cy'] + oy, local,
               self._frame_warp(frame))
        return Ctx(parent.x + tx + (m[0] * ox + m[1] * oy),
                   parent.y + ty + (m[2] * ox + m[3] * oy),
                   parent.z + frame['cz'],
                   opa, parent.visible,
                   mat_mul(parent.matrix, local) if inherit_all else local,
                   parent.segs + (seg,), parent.clip)

    # ---- tree walk ----
    def collect(self, chara, motion_name, vars_=None, layer_offsets=None):
        self._out = []
        self.layer_offsets = layer_offsets or {}
        vars_ = self.effective_vars(vars_)
        mo = self.motion(chara, motion_name)
        if isinstance(mo, dict):
            inst = _Instance(self.referenced_labels(chara, motion_name))
            self._travel(mo.get('layer'), chara, mo, vars_, Ctx(), [], inst)
        self._out.sort(key=lambda r: r['z'])
        self._resolve_clips()
        return self._out

    def _resolve_clips(self):
        for part in self._out:
            pending = part.pop('_clip_pending', None)
            if not pending:
                part['clip'] = None
                continue
            inst, labels = pending
            geoms = []
            for label in labels:
                geoms.extend(inst.registry.get(label, []))
            geoms = [g for g in geoms if g is not part]
            part['clip'] = geoms if geoms else None

    def _register(self, label_stack, geom):
        for inst, label in label_stack:
            if label in inst.referenced:
                inst.registry.setdefault(label, []).append(geom)

    def _travel(self, node, chara, mo, vars_, ctx, label_stack, inst):
        if isinstance(node, list):
            for item in node:
                self._travel(item, chara, mo, vars_, ctx, label_stack, inst)
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
            label_stack = label_stack + [(inst, node.get('label'))]
            clip = ctx.clip
            stencil = node.get('stencilCompositeMaskLayerList')
            if isinstance(stencil, list) and stencil:
                clip = (inst, tuple(x for x in stencil
                                    if isinstance(x, str)))
            if frame is not None:
                cur = self._build_ctx(node, frame, ctx)
                cur.clip = clip
                self._try_add(node, frame, vars_, cur, label_stack, inst)
            else:
                # no frame: children still travel, under the clip if any
                cur = Ctx(ctx.x, ctx.y, ctx.z, ctx.opacity, ctx.visible,
                          ctx.matrix, ctx.segs, clip)
            if node.get('exportSelf', 1):
                self._travel(node.get('children'), chara, mo, vars_, cur,
                             label_stack, inst)
                self._travel(node.get('layer'), chara, mo, vars_, cur,
                             label_stack, inst)
            return
        if node.get('exportSelf', 1):
            self._travel(node.get('children'), chara, mo, vars_, ctx,
                         label_stack, inst)
            self._travel(node.get('layer'), chara, mo, vars_, ctx,
                         label_stack, inst)

    def _grid_for(self, frame, ctx, w, h, ox, oy):
        """Destination points of the icon's tessellation grid (row-major,
        (WARP_SEG+1)^2 points when any warp is in the chain, else the 4
        corners), in model space."""
        warped = any(seg[3] is not None for seg in ctx.segs)
        n = WARP_SEG if warped else 1
        pts = []
        for gy in range(n + 1):
            for gx in range(n + 1):
                qx = w * gx / n
                qy = h * gy / n
                pts.append(chain_point(ctx.segs, qx - ox, qy - oy))
        return pts, n

    def _try_add(self, layer, frame, vars_, ctx, label_stack, inst):
        src = frame['src']
        if not src or frame['icon'] is None:
            return
        if src == 'blank':
            dims = parse_blank(frame['icon'])
            if dims is None:
                return
            w, h, iox, ioy = dims
            grid, n = self._grid_for(frame, ctx, w, h,
                                     frame['ox'] + iox, frame['oy'] + ioy)
            geom = {'blank': (w, h), 'grid': grid, 'grid_n': n,
                    'opa': ctx.opacity, 'vis': ctx.visible,
                    'label': layer.get('label', '')}
            self._register(label_stack, geom)
            return
        if src in self.source:
            got = self.icon(src, frame['icon'])
            if got is not None:
                img, iox, ioy = got
                if frame['icon'].startswith('icon') and frame['icon'] != 'icon1':
                    return
                ox = frame['ox'] + iox
                oy = frame['oy'] + ioy
                grid, n = self._grid_for(frame, ctx, img.size[0],
                                         img.size[1], ox, oy)
                part = {
                    'img': img, 'label': layer.get('label', ''),
                    'x': ctx.x, 'y': ctx.y, 'z': ctx.z,
                    'matrix': ctx.matrix,
                    'ox': ox, 'oy': oy,
                    'opacity': ctx.opacity, 'visible': ctx.visible,
                    'grid': grid, 'grid_n': n,
                    'bm': frame['bm'],
                    '_clip_pending': ctx.clip}
                self._out.append(part)
                self._register(label_stack, part)
        elif src in self.objects:
            key = f'{src}/{frame["icon"]}'
            if any(s == key for s in getattr(self, '_stack', ())):
                return
            sub = self.motion(src, frame['icon'])
            if isinstance(sub, dict):
                self._stack = getattr(self, '_stack', ()) + (key,)
                sub_inst = _Instance(self.referenced_labels(src,
                                                            frame['icon']))
                self._travel(sub.get('layer'), src, sub, vars_, ctx,
                             label_stack, sub_inst)
                self._stack = self._stack[:-1]


def part_corners(p):
    if p.get('grid'):
        n = p['grid_n']
        g = p['grid']
        return [g[0], g[n], g[(n + 1) * (n + 1) - 1], g[n * (n + 1)]]
    m = p['matrix']
    w, h = p['img'].size
    pts = []
    for (px, py) in ((0, 0), (w, 0), (w, h), (0, h)):
        dx, dy = px - p['ox'], py - p['oy']
        pts.append((p['x'] + m[0] * dx + m[1] * dy,
                    p['y'] + m[2] * dx + m[3] * dy))
    return pts


def parts_box(parts):
    all_pts = []
    for p in parts:
        if p.get('grid'):
            all_pts.extend(p['grid'])
        else:
            all_pts.extend(part_corners(p))
    min_x = min(pt[0] for pt in all_pts)
    min_y = min(pt[1] for pt in all_pts)
    max_x = max(pt[0] for pt in all_pts)
    max_y = max(pt[1] for pt in all_pts)
    return (min_x, min_y,
            max(1, math.ceil(max_x - min_x)), max(1, math.ceil(max_y - min_y)))


def _blit(target, img, dest4, src4, opacity=255, white=False):
    """Draw img (full icon) onto target, mapping src4 (icon-space quad
    TL,TR,BR,BL) to dest4 (target-space quad) with an affine fit on
    TL/TR/BL. Used for whole parts (src4 = icon corners) and for single
    tessellation cells (src4 = cell corners)."""
    (ax, ay), (bx, by), _, (cx, cy) = dest4
    (sa, sb, sc, sd) = src4
    dx1, dy1 = bx - ax, by - ay
    dx2, dy2 = cx - ax, cy - ay
    det = dx1 * dy2 - dx2 * dy1
    if abs(det) < 1e-9:
        return
    # source = S * D^-1 * (dest - A) + sA, S columns = (sB-sA, sD-sA)
    s1x, s1y = sb[0] - sa[0], sb[1] - sa[1]
    s2x, s2y = sd[0] - sa[0], sd[1] - sa[1]
    m00 = (s1x * dy2 - s2x * dy1) / det
    m01 = (s2x * dx1 - s1x * dx2) / det
    m10 = (s1y * dy2 - s2y * dy1) / det
    m11 = (s2y * dx1 - s1y * dx2) / det
    xs = [p[0] for p in dest4]
    ys = [p[1] for p in dest4]
    x0 = int(math.floor(min(xs)))
    y0 = int(math.floor(min(ys)))
    x1 = int(math.ceil(max(xs)))
    y1 = int(math.ceil(max(ys)))
    bw, bh = max(1, x1 - x0), max(1, y1 - y0)
    # PIL AFFINE maps output pixel -> input: input = M*(out - A) + sA,
    # out = patch_local + (x0, y0)
    c = sa[0] + m00 * (x0 - ax) + m01 * (y0 - ay)
    f = sa[1] + m10 * (x0 - ax) + m11 * (y0 - ay)
    src_img = img
    if white:
        src_img = Image.new('RGBA', img.size, (255, 255, 255, 255))
        src_img.putalpha(img.getchannel('A'))
    if opacity < 255:
        src_img = src_img.copy()
        alpha = src_img.getchannel('A').point(
            lambda a, o=opacity: a * o // 255)
        src_img.putalpha(alpha)
    warped = src_img.transform((bw, bh), Image.AFFINE,
                               (m00, m01, c, m10, m11, f),
                               resample=Image.BICUBIC)
    # clip the patch to the target (alpha_composite needs valid dest)
    tx0, ty0 = max(0, x0), max(0, y0)
    tx1 = min(target.size[0], x0 + bw)
    ty1 = min(target.size[1], y0 + bh)
    if tx1 <= tx0 or ty1 <= ty0:
        return
    if (tx0, ty0, tx1, ty1) != (x0, y0, x0 + bw, y0 + bh):
        warped = warped.crop((tx0 - x0, ty0 - y0, tx1 - x0, ty1 - y0))
    target.alpha_composite(warped, (tx0, ty0))


def _geom_image(geom):
    if geom.get('img') is not None:
        return geom['img']
    w, h = geom['blank']
    return Image.new('RGBA', (int(w), int(h)), (255, 255, 255, 255))


def _geom_size(geom):
    if geom.get('img') is not None:
        return geom['img'].size
    return geom['blank']


def _paint_geom(target, geom, min_x, min_y, white=False):
    """Paint one part/geom onto target (whose (0,0) is model (min_x,
    min_y))."""
    if not geom.get('visible', geom.get('vis', True)):
        return
    if white:
        # Mask geometry uses the part's RAW texture alpha: the sample's
        # trimming-frame mask part has frame opa 0 (never drawn) yet must
        # mask at full strength, or the whole character would vanish.
        opa = 255
    else:
        opa = geom.get('opacity', geom.get('opa', 255))
        if opa <= 0:
            return
    img = _geom_image(geom)
    w, h = _geom_size(geom)
    grid = geom['grid']
    n = geom['grid_n']
    dest = [(gx - min_x, gy - min_y) for (gx, gy) in grid]
    if n == 1:
        # grid order is TL,TR,BL,BR; _blit wants TL,TR,BR,BL
        quad = [dest[0], dest[1], dest[3], dest[2]]
        src4 = [(0, 0), (w, 0), (w, h), (0, h)]
        _blit(target, img, quad, src4, opa, white)
        return
    for gy in range(n):
        for gx in range(n):
            i00 = gy * (n + 1) + gx
            quad = [dest[i00], dest[i00 + 1], dest[i00 + n + 2],
                    dest[i00 + n + 1]]
            sx0 = w * gx / n
            sy0 = h * gy / n
            sx1 = w * (gx + 1) / n
            sy1 = h * (gy + 1) / n
            src4 = [(sx0, sy0), (sx1, sy0), (sx1, sy1), (sx0, sy1)]
            _blit(target, img, quad, src4, opa, white)


def composite(parts, box):
    """Draw parts onto a canvas fixed by box=(min_x, min_y, W, H)."""
    min_x, min_y, W, H = box
    canvas = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    parts = [p for p in parts if p['visible'] and p['opacity'] > 0]
    mask_cache = {}
    for p in parts:
        clip = p.get('clip')
        if not clip:
            _paint_geom(canvas, p, min_x, min_y)
            continue
        key = id(clip)
        if key not in mask_cache:
            mask = Image.new('RGBA', (W, H), (0, 0, 0, 0))
            for geom in clip:
                _paint_geom(mask, geom, min_x, min_y, white=True)
            mask_cache[key] = mask.getchannel('A')
        # draw the part alone, multiply its alpha by the mask, then over
        tmp = Image.new('RGBA', (W, H), (0, 0, 0, 0))
        _paint_geom(tmp, p, min_x, min_y)
        tmp.putalpha(_multiply(tmp.getchannel('A'), mask_cache[key]))
        canvas.alpha_composite(tmp)
    return canvas


def _multiply(a, b):
    return Image.frombytes('L', a.size,
                           bytes(x * y // 255 for x, y in
                                 zip(a.tobytes(), b.tobytes())))


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
