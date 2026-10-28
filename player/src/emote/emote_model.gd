class_name EmoteModel
extends RefCounted
## E-mote pose evaluator - port of reference/python/emote_render.py
## (itself a port of FreeMote's StaticMotionPainterCore + variable
## evaluation + the v2 advanced rendering pinned from the sample data).
##
## collect() returns draw parts in z order. Each part:
##   {tex, icon, rect (in atlas), ox, oy, x, y, z, m [a,b,c,d], opa, vis,
##    label, grid (Array of Vector2, model space, row-major), grid_n,
##    bm, clip (Array of geom dicts), clip_id}
## Unwarped parts have grid_n == 1 and grid = the 4 corners
## (TL, TR, BL, BR). Warped parts (a mesh `bp` Bezier patch anywhere in
## the layer chain) have grid_n == WARP_SEG and (WARP_SEG+1)^2 points.
## `clip` holds the stencil mask geometry (parts and blank rects, same
## dict shapes; blank geoms carry "blank": [w, h] and no "tex").
##
## Storage quirks (measured, mirrored from the Python evaluator):
## coord components are int16-wrapped, and a coord component stored as
## a PSB int in (180, 255] is a byte-wrapped negative (234 == -22;
## float-stored components are genuine); int angles / parameter ranges
## in (180, 255] are byte-wrapped negatives; icon origins in (180, 255]
## that exceed the icon's own size are byte-wrapped negatives.

const FT_NULL := 0
const FT_SINGLE := 1
const FT_TWEEN := 3
const IDENT := [1.0, 0.0, 0.0, 1.0]
const LERP_FIELDS := ["ox", "oy", "angle", "zx", "zy", "sx", "sy", "opa"]
const WARP_SEG := 5

var tree: Dictionary
var objects: Dictionary
var source: Dictionary
var metadata: Dictionary
var psb: Psb

var _out: Array = []
var _layer_offsets: Dictionary = {}
## Game mode: invisible parts that cannot serve as mask geometry get
## flat (4-corner) grids - the full warp tessellation is wasted on
## parts that are never drawn. The test suite leaves this off so the
## output stays bit-comparable with the Python reference evaluator.
var fast := false
## Web packages preprocessed by web_preprocess.py store texture
## chunks already channel-swapped; texture_image() then skips its
## per-pixel R/B swap loop.
var pre_swapped := false
var _gid := 0
var _clip_seq := 0
## Phase profiling for the collect-cache design (docs/collect-cache-
## design.md step 0): where collect()'s time actually goes.
var stat_travel_ms := 0.0
var stat_grid_ms := 0.0
var stat_grid_calls := 0
var stat_grid_hits := 0
var stat_clips_ms := 0.0
var stat_sorts_ms := 0.0
var stat_parts := 0
## Warped-grid cache (design doc, option B): a part's grid is a pure
## function of its size/origin and the ctx segment chain; during
## driver animation most chains are static or move sub-quantization
## amounts per tick. Cached point arrays are READ-ONLY — consumers
## (stage, mask code) only ever read grid points. Off by default:
## keys are quantized (0.005 px), which the bit-parity test suite
## must not see; the stage enables it for gameplay (like `fast`).
var grid_cache := false
var _grid_cache: Dictionary = {}
var _grid_lru: Array[String] = []
var _grid_sizes: Dictionary = {}
var _grid_points := 0
const GRID_CACHE_POINTS := 1500000
var _stack: Dictionary = {}
var _ref_cache: Dictionary = {}


class Ctx:
	var x := 0.0
	var y := 0.0
	var z := 0.0
	var opacity := 255
	var visible := true
	var matrix: Array = [1.0, 0.0, 0.0, 1.0]
	# Per-level segments [cx, cy, local_matrix, warp|null], root first.
	var segs: Array = []
	# Pending stencil spec [Inst, labels Array, clip_id] or null.
	var clip: Variant = null


class Inst:
	# One motion instantiation: stencil mask labels referenced inside
	# it + geoms registered under those labels, in emission order.
	var referenced: Dictionary = {}
	var registry: Dictionary = {}


static func from_psb(p_psb: Psb) -> EmoteModel:
	var m := EmoteModel.new()
	m.psb = p_psb
	m.tree = p_psb.root()
	m.objects = m.tree.get("object", {})
	m.source = m.tree.get("source", {})
	m.metadata = m.tree.get("metadata", {})
	return m


func base_chara() -> String:
	var b: Dictionary = metadata.get("base", {})
	return b.get("chara", "all_parts")


func base_motion() -> String:
	var b: Dictionary = metadata.get("base", {})
	return b.get("motion", "")


## Atlas texture for a source texture key. The chunk is labeled
## "RGBA8" but stores bytes as B,G,R,A (verified against the game's
## CG art: straight RGBA reads give blue skin), so R/B are swapped.
func texture_image(tex_key: String) -> Image:
	var tex: Dictionary = source.get(tex_key, {})
	var td: Dictionary = tex.get("texture", {})
	var w := int(td.get("width", 0))
	var h := int(td.get("height", 0))
	if w <= 0 or h <= 0:
		return null
	var pix: Dictionary = td.get("pixel", {})
	var bytes := psb.chunk_bytes(int(pix.get("$res", -1)))
	var total := w * h * 4
	if bytes.size() < total:
		var padded := PackedByteArray()
		padded.resize(total)
		for i in bytes.size():
			padded[i] = bytes[i]
		bytes = padded
	elif bytes.size() > total:
		bytes = bytes.slice(0, total)
	if pre_swapped:
		return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
	var swapped := PackedByteArray()
	swapped.resize(total)
	for px in w * h:
		var o := px * 4
		var v := bytes.decode_u32(o)
		swapped.encode_u32(o, (v & 0xFF00FF00) | ((v >> 16) & 0xFF) | ((v & 0xFF) << 16))
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, swapped)


## Icon placement info: {rect, ox, oy} with the origin unwrap applied.
func icon_info(tex_key: String, icon_id: String) -> Variant:
	var tex: Dictionary = source.get(tex_key, {})
	if tex.is_empty():
		return null
	var icons: Dictionary = tex.get("icon", {})
	var info: Variant = icons.get(icon_id)
	if info == null:
		return null
	var w := int(info.get("width", 0))
	var h := int(info.get("height", 0))
	var ox := float(info.get("originX", 0))
	var oy := float(info.get("originY", 0))
	if ox == floor(ox) and ox > 180.0 and ox <= 255.0 and ox > w:
		ox -= 256.0
	if oy == floor(oy) and oy > 180.0 and oy <= 255.0 and oy > h:
		oy -= 256.0
	return {"rect": Rect2i(int(info.get("left", 0)), int(info.get("top", 0)), w, h),
			"ox": ox, "oy": oy}


func _motion(chara: String, motion_name: String) -> Variant:
	var grp: Variant = objects.get(chara)
	if grp is Dictionary:
		var motions: Dictionary = grp.get("motion", {})
		return motions.get(motion_name)
	return null


# ---- stencil bookkeeping ----

func referenced_labels(chara: String, motion_name: String) -> Dictionary:
	var key := chara + "/" + motion_name
	if _ref_cache.has(key):
		return _ref_cache[key]
	var refs := {}
	var mo: Variant = _motion(chara, motion_name)
	if mo is Dictionary:
		_collect_refs(mo.get("layer"), refs)
	_ref_cache[key] = refs
	return refs


func _collect_refs(node: Variant, refs: Dictionary) -> void:
	if node is Array:
		for item in node:
			_collect_refs(item, refs)
	elif node is Dictionary:
		var lst: Variant = node.get("stencilCompositeMaskLayerList")
		if lst is Array:
			for x in lst:
				if x is String:
					refs[x] = true
		_collect_refs(node.get("children"), refs)
		_collect_refs(node.get("layer"), refs)


func _register(label_stack: Array, geom: Dictionary) -> void:
	for pair in label_stack:
		var inst: Inst = pair[0]
		var label: String = pair[1]
		if inst.referenced.has(label):
			if not inst.registry.has(label):
				inst.registry[label] = []
			inst.registry[label].append(geom)


# ---- variables / time ----

static func _unwrap_byte(v: float) -> float:
	if v == floor(v) and v > 180.0 and v <= 255.0:
		return v - 256.0
	return v


static func _axis_time(param: Dictionary, value: float) -> float:
	var rb := _unwrap_byte(float(param.get("rangeBegin", 0)))
	var re_ := _unwrap_byte(float(param.get("rangeEnd", 0)))
	var div := float(param.get("division", 0))
	if abs(re_ - rb) < 0.0001 or div <= 0.0:
		return 0.0
	var t := (value - rb) * div / (re_ - rb)
	return clampf(t, 0.0, div)


func _ambient_time(mo: Dictionary, vars_: Dictionary) -> float:
	for p in mo.get("parameter", []):
		if p is Dictionary and int(p.get("enabled", 1)) != 0:
			return _axis_time(p, float(vars_.get(p.get("id"), 0.0)))
	return 0.0


func effective_vars(raw: Dictionary) -> Dictionary:
	var vars_ := raw.duplicate()
	for sel in metadata.get("selectorControl", []):
		if not (sel is Dictionary) or int(sel.get("enabled", 1)) == 0:
			continue
		var chosen: float = vars_.get(sel.get("label"), 0)
		var idx := 0
		for opt in sel.get("optionList", []):
			if opt is Dictionary:
				vars_[opt.get("label")] = opt.get("onValue", 0) if chosen == idx else opt.get("offValue", 1)
			idx += 1
	return vars_


# ---- affine / warp math ----

static func _mat_mul(a: Array, b: Array) -> Array:
	return [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3],
			a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3]]


static func _calc_affine(order: Array, fx: bool, fy: bool, angle: float,
		zx: float, zy: float, sx: float, sy: float) -> Array:
	var m: Array = IDENT.duplicate()
	for t in order:
		match int(t):
			0:  # FLIP
				if fx:
					m = [-m[0], -m[1], m[2], m[3]]
				if fy:
					m = [m[0], m[1], -m[2], -m[3]]
			2:  # ZOOM
				m = [m[0] * zx, m[1] * zx, m[2] * zy, m[3] * zy]
			1:  # ANGLE
				if abs(angle) > 0.0001:
					var rad := angle * TAU / 360.0
					var c := cos(rad)
					var s := sin(rad)
					m = [c * m[0] - s * m[2], c * m[1] - s * m[3],
							s * m[0] + c * m[2], s * m[1] + c * m[3]]
			3:  # SLANT
				if abs(sx) > 0.0001 or abs(sy) > 0.0001:
					m = [m[0] + sx * m[2], m[1] + sx * m[3],
							sy * m[0] + m[2], sy * m[1] + m[3]]
	return m


static func _ident_grid() -> PackedFloat32Array:
	var g := PackedFloat32Array()
	g.resize(32)
	for r in 4:
		for c in 4:
			g[(r * 4 + c) * 2] = c / 3.0
			g[(r * 4 + c) * 2 + 1] = r / 3.0
	return g


static func _bezier_patch(bp: PackedFloat32Array, u: float, v: float) -> Vector2:
	var iu := 1.0 - u
	var iv := 1.0 - v
	var bu0 := iu * iu * iu
	var bu1 := 3.0 * iu * iu * u
	var bu2 := 3.0 * iu * u * u
	var bu3 := u * u * u
	var bv0 := iv * iv * iv
	var bv1 := 3.0 * iv * iv * v
	var bv2 := 3.0 * iv * v * v
	var bv3 := v * v * v
	var x := 0.0
	var y := 0.0
	var w := bv0 * bu0
	x += w * bp[0]
	y += w * bp[1]
	w = bv0 * bu1
	x += w * bp[2]
	y += w * bp[3]
	w = bv0 * bu2
	x += w * bp[4]
	y += w * bp[5]
	w = bv0 * bu3
	x += w * bp[6]
	y += w * bp[7]
	w = bv1 * bu0
	x += w * bp[8]
	y += w * bp[9]
	w = bv1 * bu1
	x += w * bp[10]
	y += w * bp[11]
	w = bv1 * bu2
	x += w * bp[12]
	y += w * bp[13]
	w = bv1 * bu3
	x += w * bp[14]
	y += w * bp[15]
	w = bv2 * bu0
	x += w * bp[16]
	y += w * bp[17]
	w = bv2 * bu1
	x += w * bp[18]
	y += w * bp[19]
	w = bv2 * bu2
	x += w * bp[20]
	y += w * bp[21]
	w = bv2 * bu3
	x += w * bp[22]
	y += w * bp[23]
	w = bv3 * bu0
	x += w * bp[24]
	y += w * bp[25]
	w = bv3 * bu1
	x += w * bp[26]
	y += w * bp[27]
	w = bv3 * bu2
	x += w * bp[28]
	y += w * bp[29]
	w = bv3 * bu3
	x += w * bp[30]
	y += w * bp[31]
	return Vector2(x, y)


## warp = PackedFloat32Array of 36: [bp x32, w, h, ox, oy], expressed
## in the carrying layer's frame space.
static func _warp_point(warp: PackedFloat32Array, p: Vector2) -> Vector2:
	var w := warp[32]
	var h := warp[33]
	var ox := warp[34]
	var oy := warp[35]
	if w <= 0.0 or h <= 0.0:
		return p
	var n := _bezier_patch(warp, (p.x + ox) / w, (p.y + oy) / h)
	return Vector2(n.x * w - ox, n.y * h - oy)


## Push a point through the segment chain (own layer first): at each
## level the warp applies in that level's frame space, then the level's
## local affine maps the point into the parent frame.
static func _chain_point(segs: Array, p: Vector2) -> Vector2:
	var px := p.x
	var py := p.y
	for i in range(segs.size() - 1, -1, -1):
		var seg: Array = segs[i]
		if seg[3] != null:
			var warp: PackedFloat32Array = seg[3]
			var ww := warp[32]
			var wh := warp[33]
			if ww > 0.0 and wh > 0.0:
				var wox := warp[34]
				var woy := warp[35]
				var n := _bezier_patch(warp, (px + wox) / ww, (py + woy) / wh)
				px = n.x * ww - wox
				py = n.y * wh - woy
		var m: Array = seg[2]
		var nx: float = seg[0] + m[0] * px + m[1] * py
		var ny: float = seg[1] + m[2] * px + m[3] * py
		px = nx
		py = ny
	return Vector2(px, py)


static func _parse_blank(icon: Variant) -> Variant:
	# blank icon name "W:H:OX:OY" -> [w, h, ox, oy] or null
	if not (icon is String):
		return null
	var parts: PackedStringArray = icon.split(":")
	if parts.size() != 4:
		return null
	var vals := []
	for s in parts:
		if not s.is_valid_float():
			return null
		vals.append(s.to_float())
	return vals


# ---- frame evaluation ----

static func _num(v: Variant, d: float) -> float:
	if v is int or v is float:
		return float(v)
	return d


static func _read_frame(content: Dictionary) -> Dictionary:
	var coord: Array = content.get("coord", [0, 0, 0])
	var cvals: Array = []
	for v in coord:
		var f := float(v)
		if v is int and f > 180.0 and f <= 255.0:
			# byte-wrapped negative stored as a PSB int (e.g. 234 == -22)
			f -= 256.0
		if f >= 60000.0 and f < 65536.0:
			f -= 65536.0
		cvals.append(f)
	while cvals.size() < 3:
		cvals.append(0.0)
	var raw_angle: Variant = content.get("angle")
	var angle := _num(raw_angle, 0.0)
	if raw_angle is int and angle > 180.0 and angle <= 255.0:
		# proven byte-wrapped storage (int in (180, 255] means angle-256)
		angle -= 256.0
	elif angle > 180.0 or angle <= -180.0:
		# degree-form storage (e.g. float 350.0 means -10 degrees);
		# normalize so tween lerp takes the short arc
		angle = fmod(angle + 180.0, 360.0)
		if angle < 0.0:
			angle += 360.0
		angle -= 180.0
	var mesh_bp: Variant = null
	var mesh: Variant = content.get("mesh")
	if mesh is Dictionary:
		var raw_bp: Variant = mesh.get("bp")
		if raw_bp is Array and raw_bp.size() == 32:
			var ident := _ident_grid()
			var bp := PackedFloat32Array()
			bp.resize(32)
			var is_ident := true
			for i in 32:
				bp[i] = float(raw_bp[i])
				if abs(bp[i] - ident[i]) > 0.000001:
					is_ident = false
			if not is_ident:
				mesh_bp = bp
	var icon_v: Variant = content.get("icon")
	return {
		"src": content.get("src") if content.get("src") is String else "",
		"icon": str(icon_v) if icon_v != null else null,
		"ox": _num(content.get("ox"), 0.0), "oy": _num(content.get("oy"), 0.0),
		"cx": cvals[0], "cy": cvals[1], "cz": cvals[2],
		"opa": _num(content.get("opa"), 255.0),
		"fx": int(_num(content.get("fx"), 0.0)) != 0,
		"fy": int(_num(content.get("fy"), 0.0)) != 0,
		"angle": angle,
		"zx": _num(content.get("zx"), 1.0), "zy": _num(content.get("zy"), 1.0),
		"sx": _num(content.get("sx"), 0.0), "sy": _num(content.get("sy"), 0.0),
		"mesh_bp": mesh_bp,
		"bm": int(_num(content.get("bm"), 0.0)),
	}


func _frame_content(frame_list: Array, time: float) -> Variant:
	var idx := -1
	for i in frame_list.size():
		var fr: Variant = frame_list[i]
		if fr is Dictionary and float(fr.get("time", 0)) <= time:
			idx = i
		else:
			break
	if idx < 0:
		return null
	var fr: Dictionary = frame_list[idx]
	var ftype := int(fr.get("type", FT_NULL))
	if ftype == FT_NULL:
		return null
	if ftype == FT_SINGLE and abs(float(fr.get("time", 0)) - time) >= 0.001:
		return null
	var content: Variant = fr.get("content")
	if not (content is Dictionary):
		return null
	var base := _read_frame(content)
	if ftype == FT_TWEEN and idx + 1 < frame_list.size():
		var nxt: Variant = frame_list[idx + 1]
		if nxt is Dictionary and nxt.get("content") is Dictionary:
			var t0 := float(fr.get("time", 0))
			var t1 := float(nxt.get("time", 0))
			if t1 > t0:
				var u := (time - t0) / (t1 - t0)
				if u > 0.0 and u < 1.0:
					var over := _read_frame(nxt.get("content"))
					for k in LERP_FIELDS:
						base[k] = base[k] + (over[k] - base[k]) * u
					for k in ["cx", "cy", "cz"]:
						base[k] = base[k] + (over[k] - base[k]) * u
					var bp_a: Variant = base["mesh_bp"]
					var bp_b: Variant = over["mesh_bp"]
					if bp_a != null or bp_b != null:
						var ga: PackedFloat32Array = bp_a if bp_a != null else _ident_grid()
						var gb: PackedFloat32Array = bp_b if bp_b != null else _ident_grid()
						var nb := PackedFloat32Array()
						nb.resize(32)
						for i in 32:
							nb[i] = ga[i] + (gb[i] - ga[i]) * u
						base["mesh_bp"] = nb
	return base


## Warp descriptor for a frame, in its own frame space; null when the
## frame carries no mesh or its icon size is unknown (motion references
## have neither).
func _frame_warp(frame: Dictionary) -> Variant:
	var bp: Variant = frame["mesh_bp"]
	if bp == null:
		return null
	var src: String = frame["src"]
	var w := 0.0
	var h := 0.0
	var ox := 0.0
	var oy := 0.0
	if src == "blank":
		var dims: Variant = _parse_blank(frame["icon"])
		if dims == null:
			return null
		w = dims[0]
		h = dims[1]
		ox = frame["ox"] + dims[2]
		oy = frame["oy"] + dims[3]
	elif source.has(src) and frame["icon"] != null:
		var info: Variant = icon_info(src, frame["icon"])
		if info == null:
			return null
		var r: Rect2i = info["rect"]
		w = float(r.size.x)
		h = float(r.size.y)
		ox = frame["ox"] + info["ox"]
		oy = frame["oy"] + info["oy"]
	else:
		return null
	var warp := PackedFloat32Array()
	warp.resize(36)
	for i in 32:
		warp[i] = (bp as PackedFloat32Array)[i]
	warp[32] = w
	warp[33] = h
	warp[34] = ox
	warp[35] = oy
	return warp


func _build_ctx(layer: Dictionary, frame: Dictionary, parent: Ctx) -> Ctx:
	var order: Array = layer.get("transformOrder", [0, 3, 2, 1])
	var local := _calc_affine(order, frame["fx"], frame["fy"], frame["angle"],
			frame["zx"], frame["zy"], frame["sx"], frame["sy"])
	var pm := parent.matrix
	var tx: float = pm[0] * frame["cx"] + pm[1] * frame["cy"]
	var ty: float = pm[2] * frame["cx"] + pm[3] * frame["cy"]
	var inherit_all := true
	for k in ["inheritFlipX", "inheritFlipY", "inheritAngle", "inheritZoomX",
			"inheritZoomY", "inheritSlantX", "inheritSlantY"]:
		if not int(layer.get(k, 1)):
			inherit_all = false
	var opa: int
	if int(layer.get("inheritOpacity", 1)):
		opa = int(round(parent.opacity * frame["opa"] / 255.0))
	else:
		opa = int(frame["opa"])
	var off := Vector2.ZERO
	var lo: Variant = _layer_offsets.get(layer.get("label", ""))
	if lo is Vector2:
		off = lo
	var c := Ctx.new()
	c.x = parent.x + tx + (pm[0] * off.x + pm[1] * off.y)
	c.y = parent.y + ty + (pm[2] * off.x + pm[3] * off.y)
	c.z = parent.z + frame["cz"]
	c.opacity = opa
	c.visible = parent.visible
	c.matrix = _mat_mul(parent.matrix, local) if inherit_all else local
	c.segs = parent.segs + [[frame["cx"] + off.x, frame["cy"] + off.y,
			local, _frame_warp(frame)]]
	c.clip = parent.clip
	return c


func _ctx_copy(src_ctx: Ctx) -> Ctx:
	var c := Ctx.new()
	c.x = src_ctx.x
	c.y = src_ctx.y
	c.z = src_ctx.z
	c.opacity = src_ctx.opacity
	c.visible = src_ctx.visible
	c.matrix = src_ctx.matrix
	c.segs = src_ctx.segs
	c.clip = src_ctx.clip
	return c


# ---- tree walk ----

## layer_offsets: {layer label: Vector2} added to matching layers'
## translations (physics sway hooks for the player).
func collect(chara: String, motion_name: String, raw_vars: Dictionary = {},
		layer_offsets: Dictionary = {}) -> Array:
	_out = []
	_layer_offsets = layer_offsets
	_gid = 0
	_clip_seq = 0
	_stack = {}
	var vars_ := effective_vars(raw_vars)
	var mo: Variant = _motion(chara, motion_name)
	var _tt := Time.get_ticks_usec()
	if mo is Dictionary:
		var inst := Inst.new()
		inst.referenced = referenced_labels(chara, motion_name)
		_travel(mo.get("layer"), chara, mo, vars_, Ctx.new(), [], inst)
	stat_travel_ms += (Time.get_ticks_usec() - _tt) / 1000.0
	stat_parts += _out.size()
	# stable sort by z (Python's sort is stable)
	_tt = Time.get_ticks_usec()
	var decorated: Array = []
	for i in _out.size():
		decorated.append([_out[i]["z"], i, _out[i]])
	decorated.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1])
	var out: Array = []
	for d in decorated:
		out.append(d[2])
	stat_sorts_ms += (Time.get_ticks_usec() - _tt) / 1000.0
	_tt = Time.get_ticks_usec()
	_resolve_clips(out)
	stat_clips_ms += (Time.get_ticks_usec() - _tt) / 1000.0
	return out


func _resolve_clips(out: Array) -> void:
	for part in out:
		var pending: Variant = part.get("_clip_pending")
		part.erase("_clip_pending")
		if pending == null:
			part["clip"] = []
			part["clip_id"] = -1
			continue
		var inst: Inst = pending[0]
		var labels: Array = pending[1]
		var geoms: Array = []
		for label in labels:
			geoms.append_array(inst.registry.get(label, []))
		var filtered: Array = []
		for g in geoms:
			if int(g["_gid"]) != int(part["_gid"]):
				filtered.append(g)
		part["clip"] = filtered
		part["clip_id"] = int(pending[2]) if not filtered.is_empty() else -1


func _travel(node: Variant, chara: String, mo: Variant, vars_: Dictionary,
		ctx: Ctx, label_stack: Array, inst: Inst) -> void:
	if node is Array:
		for item in node:
			_travel(item, chara, mo, vars_, ctx, label_stack, inst)
		return
	if not (node is Dictionary):
		return
	var cur := ctx
	if node.get("frameList") is Array:
		var params: Array = mo.get("parameter", []) if mo is Dictionary else []
		var pk: Variant = node.get("parameterize")
		var t: float
		if pk is int and pk >= 0 and pk < params.size():
			t = _axis_time(params[pk], float(vars_.get(params[pk].get("id"), 0.0)))
		elif mo is Dictionary:
			t = _ambient_time(mo, vars_)
		else:
			t = 0.0
		var frame: Variant = _frame_content(node["frameList"], t)
		var stack2 := label_stack.duplicate()
		stack2.append([inst, node.get("label", "")])
		var clip: Variant = ctx.clip
		var stencil: Variant = node.get("stencilCompositeMaskLayerList")
		if stencil is Array and stencil.size() > 0:
			var labels := []
			for x in stencil:
				if x is String:
					labels.append(x)
			_clip_seq += 1
			clip = [inst, labels, _clip_seq]
		if frame != null:
			cur = _build_ctx(node, frame, ctx)
			cur.clip = clip
			_try_add(node, frame, vars_, cur, stack2, inst)
		else:
			# no frame: children still travel, under the clip if any
			cur = _ctx_copy(ctx)
			cur.clip = clip
		if int(node.get("exportSelf", 1)):
			_travel(node.get("children"), chara, mo, vars_, cur, stack2, inst)
			_travel(node.get("layer"), chara, mo, vars_, cur, stack2, inst)
		return
	if int(node.get("exportSelf", 1)):
		_travel(node.get("children"), chara, mo, vars_, ctx, label_stack, inst)
		_travel(node.get("layer"), chara, mo, vars_, ctx, label_stack, inst)


func _stack_referenced(label_stack: Array) -> bool:
	for pair in label_stack:
		if (pair[0] as Inst).referenced.has(pair[1]):
			return true
	return false


func _grid_for(ctx: Ctx, w: float, h: float, ox: float, oy: float,
		force_flat := false) -> Array:
	stat_grid_calls += 1
	var _tg := Time.get_ticks_usec()
	var warped := false
	if not force_flat:
		for seg in ctx.segs:
			if seg[3] != null:
				warped = true
				break
	var res: Array
	if not warped or not grid_cache:
		# Flat grids are 4 chain points — cheaper than a cache key.
		res = _grid_for_impl(ctx, w, h, ox, oy, force_flat)
	else:
		var key := _grid_key(ctx, w, h, ox, oy)
		if _grid_cache.has(key):
			stat_grid_hits += 1
			_grid_lru.erase(key)
			_grid_lru.append(key)
			res = _grid_cache[key]
		else:
			res = _grid_for_impl(ctx, w, h, ox, oy, force_flat)
			_grid_cache[key] = res
			_grid_lru.append(key)
			var npts: int = (res[0] as Array).size()
			_grid_sizes[key] = npts
			_grid_points += npts
			while _grid_points > GRID_CACHE_POINTS \
					and _grid_lru.size() > 1:
				var victim: String = _grid_lru.pop_front()
				_grid_points -= int(_grid_sizes.get(victim, 0))
				_grid_sizes.erase(victim)
				_grid_cache.erase(victim)
	stat_grid_ms += (Time.get_ticks_usec() - _tg) / 1000.0
	return res


## Quantized cache key for a warped grid: segment translations and
## matrices at 0.005 px steps, warp control data likewise — slow
## driver motion then produces stable keys, and the geometric error
## from a hit is below render resolution.
func _grid_key(ctx: Ctx, w: float, h: float, ox: float, oy: float) -> String:
	var parts := PackedStringArray()
	parts.append(str(int(round(w * 200.0))) + "," + str(int(round(h * 200.0)))
			+ "," + str(int(round(ox * 200.0))) + ","
			+ str(int(round(oy * 200.0))))
	for seg in ctx.segs:
		var m: Array = seg[2]
		var s := str(int(round(float(seg[0]) * 200.0))) + ","
		s += str(int(round(float(seg[1]) * 200.0))) + ","
		for i in 4:
			s += str(int(round(float(m[i]) * 200.0))) + ","
		if seg[3] == null:
			s += "x"
		else:
			var warp: PackedFloat32Array = seg[3]
			for i in warp.size():
				s += str(int(round(warp[i] * 200.0))) + ","
		parts.append(s)
	return "|".join(parts)


func _grid_for_impl(ctx: Ctx, w: float, h: float, ox: float, oy: float,
		force_flat := false) -> Array:
	# [points (row-major), n]: (WARP_SEG+1)^2 points when any warp is in
	# the chain, else the 4 corners with n == 1.
	var warped := false
	if not force_flat:
		for seg in ctx.segs:
			if seg[3] != null:
				warped = true
				break
	var n := WARP_SEG if warped else 1
	var pts := []
	for gy in n + 1:
		for gx in n + 1:
			pts.append(_chain_point(ctx.segs,
					Vector2(w * gx / n - ox, h * gy / n - oy)))
	return [pts, n]


func _try_add(layer: Dictionary, frame: Dictionary, vars_: Dictionary,
		ctx: Ctx, label_stack: Array, inst: Inst) -> void:
	var src: String = frame["src"]
	if src == "" or frame["icon"] == null:
		return
	if src == "blank":
		# Procedural rects are never drawn, but count as mask geometry.
		# Skip the (potentially warped) grid entirely when no enclosing
		# label is stencil-referenced in its instance: the geom would
		# never be registered or used.
		if not _stack_referenced(label_stack):
			return
		var dims: Variant = _parse_blank(frame["icon"])
		if dims == null:
			return
		var g := _grid_for(ctx, dims[0], dims[1],
				frame["ox"] + dims[2], frame["oy"] + dims[3])
		_gid += 1
		_register(label_stack, {"blank": [dims[0], dims[1]], "grid": g[0],
				"grid_n": g[1], "opa": ctx.opacity, "vis": ctx.visible,
				"label": layer.get("label", ""), "_gid": _gid})
		return
	if source.has(src):
		var info: Variant = icon_info(src, frame["icon"])
		if info == null:
			return
		var icon: String = frame["icon"]
		if icon.begins_with("icon") and icon != "icon1":
			return
		var ox: float = frame["ox"] + info["ox"]
		var oy: float = frame["oy"] + info["oy"]
		var r: Rect2i = info["rect"]
		var flat := fast and (not ctx.visible or ctx.opacity <= 0) \
				and not _stack_referenced(label_stack)
		var g := _grid_for(ctx, float(r.size.x), float(r.size.y), ox, oy, flat)
		_gid += 1
		var part := {
			"tex": src, "icon": icon, "rect": r,
			"ox": ox, "oy": oy,
			"x": ctx.x, "y": ctx.y, "z": ctx.z, "m": ctx.matrix,
			"opa": ctx.opacity, "vis": ctx.visible,
			"label": layer.get("label", ""),
			"grid": g[0], "grid_n": g[1], "bm": frame["bm"],
			"_gid": _gid, "_clip_pending": ctx.clip,
		}
		_out.append(part)
		_register(label_stack, part)
	elif objects.has(src):
		var key: String = src + "/" + str(frame["icon"])
		if _stack.has(key):
			return
		var sub: Variant = _motion(src, frame["icon"])
		if sub is Dictionary:
			_stack[key] = true
			var sub_inst := Inst.new()
			sub_inst.referenced = referenced_labels(src, frame["icon"])
			_travel(sub.get("layer"), src, sub, vars_, ctx, label_stack, sub_inst)
			_stack.erase(key)


## The 4 corners (TL, TR, BR, BL) of a part's grid.
static func part_corners(part: Dictionary) -> Array:
	var grid: Array = part["grid"]
	var n: int = part["grid_n"]
	return [grid[0], grid[n], grid[(n + 1) * (n + 1) - 1], grid[n * (n + 1)]]
