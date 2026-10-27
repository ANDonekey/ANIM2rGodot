class_name EmoteModel
extends RefCounted
## E-mote pose evaluator - port of reference/python/emote_render.py
## (itself a port of FreeMote's StaticMotionPainterCore + variable
## evaluation). collect() returns draw parts in z order:
##   {tex, icon, rect (in atlas), ox, oy, x, y, z, m [a,b,c,d], opa, label}
## where the part's local point p maps to (x, y) + M * (p - (ox, oy)).
## Storage quirks (measured, mirrored from the Python evaluator):
## coord components are int16-wrapped; int angles / parameter ranges in
## (180, 255] are byte-wrapped negatives; icon origins in (180, 255] that
## exceed the icon's own size are byte-wrapped negatives.

const FT_NULL := 0
const FT_SINGLE := 1
const FT_TWEEN := 3
const IDENT := [1.0, 0.0, 0.0, 1.0]
const LERP_FIELDS := ["ox", "oy", "angle", "zx", "zy", "sx", "sy", "opa"]

var tree: Dictionary
var objects: Dictionary
var source: Dictionary
var metadata: Dictionary
var psb: Psb

var _out: Array = []


class Ctx:
	var x := 0.0
	var y := 0.0
	var z := 0.0
	var opacity := 255
	var visible := true
	var matrix: Array = [1.0, 0.0, 0.0, 1.0]


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


## Atlas texture (RGBA8 raw chunk) for a source texture key.
func texture_image(tex_key: String) -> Image:
	var tex: Dictionary = source.get(tex_key, {})
	var td: Dictionary = tex.get("texture", {})
	var w := int(td.get("width", 0))
	var h := int(td.get("height", 0))
	if w <= 0 or h <= 0:
		return null
	var pix: Dictionary = td.get("pixel", {})
	var bytes := psb.chunk_bytes(int(pix.get("$res", -1)))
	if bytes.size() < w * h * 4:
		var padded := PackedByteArray()
		padded.resize(w * h * 4)
		for i in bytes.size():
			padded[i] = bytes[i]
		bytes = padded
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)


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


static func _num(v: Variant, d: float) -> float:
	if v is int or v is float:
		return float(v)
	return d


static func _read_frame(content: Dictionary) -> Dictionary:
	var coord: Array = content.get("coord", [0, 0, 0])
	var cvals: Array = []
	for v in coord:
		var f := float(v)
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
	return base


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
	var c := Ctx.new()
	c.x = parent.x + tx
	c.y = parent.y + ty
	c.z = parent.z + frame["cz"]
	c.opacity = opa
	c.visible = parent.visible
	c.matrix = _mat_mul(parent.matrix, local) if inherit_all else local
	return c


func collect(chara: String, motion_name: String, raw_vars: Dictionary = {}) -> Array:
	_out = []
	var vars_ := effective_vars(raw_vars)
	var mo: Variant = _motion(chara, motion_name)
	if mo is Dictionary:
		_travel(mo.get("layer"), chara, mo, vars_, Ctx.new(), {})
	# stable sort by z (Python's sort is stable)
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
	return out


func _travel(node: Variant, chara: String, mo: Variant, vars_: Dictionary,
		ctx: Ctx, stack: Dictionary) -> void:
	if node is Array:
		for item in node:
			_travel(item, chara, mo, vars_, ctx, stack)
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
		if frame != null:
			cur = _build_ctx(node, frame, ctx)
			_try_add(node, frame, vars_, cur, stack)
		if int(node.get("exportSelf", 1)):
			_travel(node.get("children"), chara, mo, vars_, cur, stack)
			_travel(node.get("layer"), chara, mo, vars_, cur, stack)
		return
	if int(node.get("exportSelf", 1)):
		_travel(node.get("children"), chara, mo, vars_, ctx, stack)
		_travel(node.get("layer"), chara, mo, vars_, ctx, stack)


func _try_add(layer: Dictionary, frame: Dictionary, vars_: Dictionary,
		ctx: Ctx, stack: Dictionary) -> void:
	var src: String = frame["src"]
	if src == "":
		return
	if source.has(src) and frame["icon"] != null:
		var info: Variant = icon_info(src, frame["icon"])
		if info != null:
			var icon: String = frame["icon"]
			if icon.begins_with("icon") and icon != "icon1":
				return
			_out.append({
				"tex": src, "icon": icon, "rect": info["rect"],
				"ox": frame["ox"] + info["ox"], "oy": frame["oy"] + info["oy"],
				"x": ctx.x, "y": ctx.y, "z": ctx.z, "m": ctx.matrix,
				"opa": ctx.opacity, "vis": ctx.visible,
				"label": layer.get("label", ""),
			})
	elif objects.has(src) and frame["icon"] != null:
		var key: String = src + "/" + str(frame["icon"])
		if stack.has(key):
			return
		var sub: Variant = _motion(src, frame["icon"])
		if sub is Dictionary:
			stack[key] = true
			_travel(sub.get("layer"), src, sub, vars_, ctx, stack)
			stack.erase(key)
