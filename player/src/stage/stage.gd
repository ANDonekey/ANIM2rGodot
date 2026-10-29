class_name Stage
extends Node2D
## Stage presentation: BG/CG layer, E-mote slots, transition flashes.
##
## E-mote rendering (v2): unwarped parts are Sprite2D; mesh-warped parts
## are tessellated Polygon2D over the evaluator's Bezier grid; stencil-
## clipped parts are Polygon2D over a CPU-masked copy of their icon
## (mask = union alpha of the clip geoms, sampled through their grids).
## Poses interpolate over the pose's time; blink (eyeControl), lip sync
## (mouthControl talk label driven by the voice bus level) and spring
## physics on the hair/bust/parts control base layers run as drivers
## in _process and re-render a slot only when its evaluated state
## actually changes.
##
## Slot positioning follows the original ops (pinned from the exe's
## interpreter decompilation): 0x53/0x54 write a per-slot anchor (x, y),
## 0x59 moves the slot by a relative offset over a duration, 0x77 sets a
## per-mille scale (normalized per slot: the first value seen after a
## load is the baseline, because the original multiplies by a stage
## float factor whose identity is unresolved). Default anchors are the
## SetPosInit table from the script itself.

const DEFAULT_ANCHOR_X := {0: 280, 1: 426, 2: 640, 3: 852, 4: 1000}
const HC_OFFSET := 100
const BLINK_AMP := 20.0  # face_eye_open delta for a full blink (measured)

var pkg: GamePackage
var define: DefineTable

var _bg: Sprite2D
var _bg_name := ""
var _slots: Dictionary = {}  # slot -> slot state dict (see emote_load)
var _pos: Dictionary = {}  # slot -> {ax, ay, off, sbase, smult, tw_off, tw_scale}
var _model_cache: Dictionary = {}
var _tex_cache: Dictionary = {}
var _img_cache: Dictionary = {}  # model|tex -> atlas Image
var _icon_img_cache: Dictionary = {}  # model|tex|icon -> icon region Image
var _icon_opaque_cache: Dictionary = {}
var _overlay: ColorRect
var _movie_panel: PanelContainer
var _movie_label: Label
var _video: VideoStreamPlayer
var _last_change := false
var _voice_level := 0.0
var _time := 0.0
# Web mode: resources arrive asynchronously. Tokens drop superseded
# fetches; poses addressed to a still-loading slot are buffered and
# the latest one is applied when the model lands.
var _img_req := 0
var _movie_req := 0
var _load_seq := 0
var _loading: Dictionary = {}  # slot -> token
var _pending_pose: Dictionary = {}  # slot -> [label, time_ms]

var stats_blinks := 0
var stats_renders := 0
var stats_render_ms := 0.0
var stats_collect_ms := 0.0
## Aggregated collect() phase profile across all loaded models.
func collect_profile() -> Dictionary:
	var t := 0.0
	var g := 0.0
	var gc := 0
	var c := 0.0
	var s := 0.0
	var n := 0
	var gh := 0
	for mname in _model_cache:
		var m: EmoteModel = _model_cache[mname]
		t += m.stat_travel_ms
		g += m.stat_grid_ms
		gc += m.stat_grid_calls
		c += m.stat_clips_ms
		s += m.stat_sorts_ms
		n += m.stat_parts
		gh += m.stat_grid_hits
	return {"travel_ms": snappedf(t, 0.1), "grid_ms": snappedf(g, 0.1),
			"grid_calls": gc, "clips_ms": snappedf(c, 0.1),
			"sort_ms": snappedf(s, 0.1), "parts": n,
			"grid_hits": gh}


var stats_mask_bakes := 0
var stats_mask_hits := 0
# Baked mask textures (see _masked_texture): byte-budgeted LRU.
var _mask_cache: Dictionary = {}
var _mask_lru: Array[String] = []
var _mask_sizes: Dictionary = {}
var _mask_bytes := 0
const MASK_CACHE_BUDGET := 64 * 1024 * 1024
var stats_fast := 0


func _ready() -> void:
	_bg = Sprite2D.new()
	_bg.centered = false
	_bg.z_index = 0
	add_child(_bg)
	var layer := CanvasLayer.new()
	layer.layer = 40
	add_child(layer)
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_overlay)
	_movie_panel = PanelContainer.new()
	_movie_panel.set_anchors_preset(Control.PRESET_CENTER)
	_movie_panel.position = Vector2(440, 320)
	_movie_panel.custom_minimum_size = Vector2(400, 80)
	_movie_panel.visible = false
	_movie_label = Label.new()
	_movie_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	DialogueUI.apply_font(_movie_label, 20)
	_movie_panel.add_child(_movie_label)
	layer.add_child(_movie_panel)
	_video = VideoStreamPlayer.new()
	_video.set_anchors_preset(Control.PRESET_FULL_RECT)
	_video.expand = true
	_video.visible = false
	_video.finished.connect(func() -> void: _video.visible = false)
	layer.add_child(_video)


func setup(p_pkg: GamePackage, p_define: DefineTable) -> void:
	pkg = p_pkg
	define = p_define


func set_voice_level(v: float) -> void:
	_voice_level = v


# ---- background / CG ----

func show_image(image_name: String) -> void:
	_img_req += 1
	var token := _img_req
	var bytes := pkg.image_bytes(image_name)
	if bytes.is_empty() and pkg.is_web():
		await pkg.ensure_image(image_name)
		if token != _img_req:
			return
		bytes = pkg.image_bytes(image_name)
	if bytes.is_empty():
		push_warning("Stage: image not found: " + image_name)
		return
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK or img.is_empty():
		push_warning("Stage: image decode failed: " + image_name)
		return
	var used: Rect2i = img.get_used_rect()
	if used.size.x > 0 and used.size.y > 0 and used.size != img.get_size():
		img = img.get_region(used)
		_bg.position = Vector2(used.position)
	else:
		_bg.position = Vector2.ZERO
	_bg.texture = ImageTexture.create_from_image(img)
	_bg_name = image_name
	_last_change = true


func note_transition(id: int, value: int, tail: Array) -> void:
	if not _last_change:
		return
	_last_change = false
	if id in [1, 33, 34, 35] and value >= 100:
		_flash(Color(0, 0, 0, 0.85), Color(0, 0, 0, 0), value / 1000.0)
	elif id == 40 and tail.size() == 2 and tail[0] == "u8x5":
		var t: Array = tail[1]
		if t.size() == 5:
			var col := Color(t[0] / 255.0, t[1] / 255.0, t[2] / 255.0, t[3] / 255.0)
			var col2 := Color(t[0] / 255.0, t[1] / 255.0, t[2] / 255.0, t[4] / 255.0)
			_flash(col, col2, maxi(value, 50) / 1000.0)


func _flash(from: Color, to: Color, seconds: float) -> void:
	_overlay.color = from
	var tw := create_tween()
	tw.tween_property(_overlay, "color", to, seconds)


func movie_placeholder(movie_name: String) -> void:
	_movie_label.text = "▶ movie: %s\n(v1: playback not implemented)" % movie_name
	_movie_panel.visible = true
	var tw := create_tween()
	tw.tween_interval(1.5)
	tw.tween_callback(func() -> void: _movie_panel.visible = false)


## Movie entry point: web packages carry a transcoded Theora version
## of every movie, which Godot plays natively — download it and play
## fullscreen. Native packages still have only MPEG-1, so they keep
## the placeholder until the pl_mpeg extension lands.
func play_movie(movie_name: String) -> void:
	if pkg != null and pkg.is_web() and pkg.movie_ogv_rel(movie_name) != "":
		_movie_req += 1
		var token := _movie_req
		var path: String = await pkg.ensure_movie(movie_name)
		if token != _movie_req or path == "":
			return
		var stream := VideoStreamTheora.new()
		stream.file = path
		_video.stream = stream
		_video.visible = true
		_video.play()
		return
	movie_placeholder(movie_name)


func stop_movie() -> void:
	_movie_req += 1
	if _video.visible:
		_video.stop()
		_video.visible = false


## True while a movie (real video or the native placeholder panel)
## is on screen; the gallery uses it to detect playback end.
func movie_playing() -> bool:
	return _video.visible or _movie_panel.visible


## Reset the stage to a blank slate for a fresh VM boot (story
## restart or a recollection entry): movies off, background cleared,
## every loaded E-mote slot unloaded. Model/texture caches stay —
## they are content-addressed and reused across boots.
func clear_stage() -> void:
	stop_movie()
	_movie_panel.visible = false
	_bg.texture = null
	_bg_name = ""
	for slot in _slots.keys():
		emote_unload(slot)
	_pos.clear()


# ---- E-mote slots ----

func _model(model_name: String) -> EmoteModel:
	if _model_cache.has(model_name):
		return _model_cache[model_name]
	var bytes := pkg.psb_bytes(model_name)
	if bytes.is_empty():
		push_warning("Stage: model not found: " + model_name)
		return null
	var model := EmoteModel.from_psb(Psb.parse(bytes))
	model.fast = true
	model.grid_cache = true
	model.pre_swapped = pkg.pre_swapped()
	_model_cache[model_name] = model
	return model


func _atlas(model: EmoteModel, model_name: String, tex_key: String) -> Texture2D:
	var key := model_name + "|" + tex_key
	if _tex_cache.has(key):
		return _tex_cache[key]
	var img := model.texture_image(tex_key)
	var tex: Texture2D = ImageTexture.create_from_image(img) if img else null
	_tex_cache[key] = tex
	if img:
		_img_cache[key] = img
	return tex


func _atlas_image(model: EmoteModel, model_name: String, tex_key: String) -> Image:
	var key := model_name + "|" + tex_key
	if not _img_cache.has(key):
		_atlas(model, model_name, tex_key)
	return _img_cache.get(key)


func _icon_image(st: Dictionary, tex_key: String, icon: String, rect: Rect2i) -> Image:
	var key: String = st["name"] + "|" + tex_key + "|" + icon
	if _icon_img_cache.has(key):
		return _icon_img_cache[key]
	var atlas := _atlas_image(st["model"], st["name"], tex_key)
	var img: Image = null
	if atlas:
		img = atlas.get_region(rect)
	_icon_img_cache[key] = img
	return img


func _icon_fully_opaque(st: Dictionary, tex_key: String, icon: String, rect: Rect2i) -> bool:
	var key: String = st["name"] + "|" + tex_key + "|" + icon
	if _icon_opaque_cache.has(key):
		return _icon_opaque_cache[key]
	var img := _icon_image(st, tex_key, icon, rect)
	var opaque := false
	if img:
		opaque = true
		var data := img.get_data()  # RGBA8: alpha at every 4th byte
		var i := 3
		while i < data.size():
			if data[i] < 254:
				opaque = false
				break
			i += 4
	_icon_opaque_cache[key] = opaque
	return opaque


func emote_load(slot: int, model_name: String) -> void:
	emote_unload(slot)
	if not _model_cache.has(model_name) and pkg.is_web() \
			and pkg.psb_bytes(model_name).is_empty():
		# Web mode and the model is not fetched yet: fetch it, then
		# load for real; poses arriving meanwhile are buffered.
		_load_seq += 1
		var token := _load_seq
		_loading[slot] = token
		await pkg.ensure_psb(model_name)
		if _loading.get(slot, -1) != token:
			return  # superseded or unloaded while fetching
		_loading.erase(slot)
		# Capture the buffered pose BEFORE the recursive load: its
		# emote_unload() call clears the buffer.
		var pp: Variant = _pending_pose.get(slot)
		emote_load(slot, model_name)
		if pp != null:
			emote_pose(slot, pp[0], pp[1])
		return
	var model := _model(model_name)
	if model == null:
		return
	var root := Node2D.new()
	root.z_index = 10 + slot
	add_child(root)
	var parts_root := Node2D.new()
	root.add_child(parts_root)
	var eye := {}
	for e in model.metadata.get("eyeControl", []):
		if e is Dictionary and int(e.get("enabled", 1)) != 0:
			eye = e
			break
	var talk_label := ""
	for mc in model.metadata.get("mouthControl", []):
		if mc is Dictionary and int(mc.get("enabled", 1)) != 0:
			talk_label = mc.get("talkLabel", "")
			break
	var controls := []
	for key in ["hairControl", "bustControl", "partsControl"]:
		for c in model.metadata.get(key, []):
			if c is Dictionary and int(c.get("enabled", 1)) != 0 and c.get("baseLayer", "") != "":
				controls.append(c["baseLayer"])
	var phys := {}
	for base_layer in controls:
		phys[base_layer] = {"p": Vector2.ZERO, "v": Vector2.ZERO}
	_slots[slot] = {"root": root, "parts_root": parts_root, "model": model,
			"name": model_name, "vars": {}, "rvars": {}, "trans": null,
			"eye": eye, "talk_label": talk_label, "phys": phys,
			"blink_next": randf_range(0.4, 2.5), "blink_t": -1.0,
			"talk_v": 0.0, "sig": "", "drv_t": 0.0}
	# A fresh model starts at its anchor (offset/scale reset; the anchor
	# itself is scene setup and persists across loads).
	var ps := _pos_state(slot)
	ps["off"] = Vector2.ZERO
	ps["sbase"] = 0
	ps["smult"] = 1.0
	_render_slot(slot, 0.0, {}, {})
	_layout_slots()


func emote_load_hc(slot: int, model_name: String) -> void:
	emote_load(slot + HC_OFFSET, model_name)


func emote_pose_hc(slot: int, label: String, time_ms: int) -> void:
	emote_pose(slot + HC_OFFSET, label, time_ms)


## Viewer (EmoteRoom) API: set one pose variable directly, effective
## on the next drive tick.
func emote_set_var(slot: int, var_name: String, value: float) -> void:
	if not _slots.has(slot):
		return
	var st: Dictionary = _slots[slot]
	st["vars"][var_name] = value
	st["rvars"][var_name] = value
	st["trans"] = null
	st["sig"] = ""


## Viewer API: toggle the idle drivers (blink) for a slot.
func emote_set_idle(slot: int, on: bool) -> void:
	if not _slots.has(slot):
		return
	var st: Dictionary = _slots[slot]
	if on:
		if st.has("_eye_stash"):
			st["eye"] = st["_eye_stash"]
			st.erase("_eye_stash")
	else:
		if not st.has("_eye_stash"):
			st["_eye_stash"] = st["eye"]
		st["eye"] = {}


func emote_unload(slot: int) -> void:
	_loading.erase(slot)
	_pending_pose.erase(slot)
	if _slots.has(slot):
		_slots[slot]["root"].queue_free()
		_slots.erase(slot)
		_layout_slots()


func emote_pose(slot: int, label: String, time_ms: int) -> void:
	if not _slots.has(slot):
		if _loading.has(slot):
			_pending_pose[slot] = [label, time_ms]
		return
	var pose := define.pose_vars(label)
	if pose.is_empty():
		push_warning("Stage: unknown em label: " + label)
		return
	var st: Dictionary = _slots[slot]
	var cur: Dictionary = st["vars"]
	if pose.size() >= 15:
		st["vars"] = pose.duplicate()
	else:
		for k in pose:
			cur[k] = pose[k]
	var dur := clampi(time_ms, 0, 800) / 1000.0
	_excite(st, Vector2(randf_range(-5.0, 5.0), randf_range(7.0, 13.0)))
	if dur <= 0.0:
		st["trans"] = null
		st["rvars"] = (st["vars"] as Dictionary).duplicate()
		_render_slot(slot, 0.0, st["rvars"], _phys_offsets(st))
	else:
		st["trans"] = {"from": (st["rvars"] as Dictionary).duplicate(),
				"to": (st["vars"] as Dictionary).duplicate(),
				"t": 0.0, "dur": dur}
	_layout_slots()


func _excite(st: Dictionary, impulse: Vector2) -> void:
	for base_layer in st["phys"]:
		var ph: Dictionary = st["phys"][base_layer]
		ph["v"] = (ph["v"] as Vector2) + impulse * randf_range(0.7, 1.3)


func _phys_offsets(st: Dictionary) -> Dictionary:
	var out := {}
	for base_layer in st["phys"]:
		var p: Vector2 = st["phys"][base_layer]["p"]
		if p.length() > 0.01:
			out[base_layer] = p
	return out


## The render plan for one collect() result: visible parts with a
## stable key (label|icon plus an occurrence index — collect() walks
## deterministically, so keys are stable across renders of the same
## structure) and their node kind. The joined structure key changes
## whenever the part set, kinds, textures, rects or grids change.
func _plan_parts(st: Dictionary, parts: Array) -> Dictionary:
	var plan := []
	var seen := {}
	var skey := PackedStringArray()
	for p in parts:
		if not p["vis"] or int(p["opa"]) <= 0:
			continue
		var base := str(p["label"]) + "|" + str(p["icon"])
		var occ := int(seen.get(base, 0))
		seen[base] = occ + 1
		var key := base + "#" + str(occ)
		var kind := 0  # 0 plain sprite, 1 warp polygon, 2 masked polygon
		if not (p["clip"] as Array).is_empty() and not _clip_is_noop(st, p):
			kind = 2
		elif int(p["grid_n"]) > 1:
			kind = 1
		plan.append({"key": key, "kind": kind, "p": p})
		skey.append(key + ":" + str(kind) + ":" + str(p["tex"])
				+ ":" + str(p["rect"]) + ":" + str(p["grid_n"]))
	return {"plan": plan, "skey": "|".join(skey)}


func _render_slot(slot: int, fade_seconds: float, rvars: Dictionary, offsets: Dictionary) -> void:
	stats_renders += 1
	var _t0 := Time.get_ticks_usec()
	var st: Dictionary = _slots[slot]
	var model: EmoteModel = st["model"]
	var _tc := Time.get_ticks_usec()
	var parts := model.collect(model.base_chara(), model.base_motion(), rvars, offsets)
	stats_collect_ms += (Time.get_ticks_usec() - _tc) / 1000.0
	var planned := _plan_parts(st, parts)
	var plan: Array = planned["plan"]
	# Fast path: same model, same structure, no fade — update the
	# persistent part nodes in place instead of rebuilding the tree.
	var cache: Dictionary = st.get("reuse", {})
	if fade_seconds <= 0.0 and not cache.is_empty() \
			and cache.get("skey") == planned["skey"] \
			and cache.get("model") == model \
			and is_instance_valid(cache.get("root")):
		var nodes: Dictionary = cache["nodes"]
		var complete := true
		for item in plan:
			if not nodes.has(item["key"]):
				complete = false
				break
		if complete:
			stats_fast += 1
			var ord2 := 0
			for item in plan:
				var node: CanvasItem = nodes[item["key"]]
				_update_part_node(st, node, item["p"], int(item["kind"]), cache, item["key"])
				node.z_index = ord2
				ord2 += 1
			st["parts"] = parts
			st["sig"] = _signature(rvars, offsets)
			stats_render_ms += (Time.get_ticks_usec() - _t0) / 1000.0
			st["last_ms"] = (Time.get_ticks_usec() - _t0) / 1000.0
			return
	# Full rebuild (structure change, fade, or first render).
	var old_root: Node2D = st["parts_root"]
	var new_root := Node2D.new()
	st["root"].add_child(new_root)
	var order := 0
	var nodes := {}
	var metas := {}
	for item in plan:
		var node := _part_node(st, item["p"], int(item["kind"]))
		if node == null:
			continue
		node.z_index = order
		order += 1
		new_root.add_child(node)
		nodes[item["key"]] = node
		metas[item["key"]] = {"tex": item["p"]["tex"],
				"rect": item["p"]["rect"], "grid_n": item["p"]["grid_n"],
				"ox": item["p"]["ox"], "oy": item["p"]["oy"]}
	st["parts_root"] = new_root
	st["parts"] = parts
	st["sig"] = _signature(rvars, offsets)
	st["reuse"] = {"skey": planned["skey"], "model": model,
			"root": new_root, "nodes": nodes, "meta": metas}
	if fade_seconds > 0.0 and is_inside_tree():
		new_root.modulate.a = 0.0
		var tw := create_tween()
		tw.set_parallel(true)
		tw.tween_property(new_root, "modulate:a", 1.0, fade_seconds)
		if old_root != new_root:
			tw.tween_property(old_root, "modulate:a", 0.0, fade_seconds)
		tw.chain().tween_callback(old_root.queue_free)
	else:
		if old_root != new_root:
			old_root.queue_free()
	stats_render_ms += (Time.get_ticks_usec() - _t0) / 1000.0
	st["last_ms"] = (Time.get_ticks_usec() - _t0) / 1000.0


## In-place update of a persistent part node on the fast path. Only
## per-frame values (transform, grid points, opacity) are touched
## unless the part's static texture/rect/grid changed.
func _update_part_node(st: Dictionary, node: CanvasItem, p: Dictionary, kind: int, cache: Dictionary, key: String) -> void:
	var meta: Dictionary = cache["meta"][key]
	var static_changed: bool = meta.get("tex") != p["tex"] \
			or meta.get("rect") != p["rect"] \
			or int(meta.get("grid_n", -1)) != int(p["grid_n"]) \
			or float(meta.get("ox", 0.0)) != float(p["ox"]) \
			or float(meta.get("oy", 0.0)) != float(p["oy"])
	if kind == 0:
		var spr := node as Sprite2D
		if static_changed:
			spr.texture = _atlas(st["model"], st["name"], p["tex"])
			spr.region_enabled = true
			spr.region_rect = p["rect"]
			spr.centered = false
			spr.offset = Vector2(-p["ox"], -p["oy"])
		var m: Array = p["m"]
		spr.transform = Transform2D(Vector2(m[0], m[2]), Vector2(m[1], m[3]),
				Vector2(p["x"], p["y"]))
		spr.modulate.a = int(p["opa"]) / 255.0
	elif kind == 1:
		var poly := node as Polygon2D
		if static_changed:
			_warp_setup(poly, st, p, null)
		else:
			var grid: Array = p["grid"]
			var pts := PackedVector2Array()
			pts.resize(grid.size())
			for i in grid.size():
				pts[i] = grid[i]
			poly.polygon = pts
			poly.modulate.a = int(p["opa"]) / 255.0
	else:
		# Masked parts still rebake their texture per render (the
		# mask cache is a separate step); only the node is reused.
		var fresh := _masked_polygon(st, p)
		var poly := node as Polygon2D
		if fresh == null:
			poly.visible = false
			return
		poly.visible = true
		poly.polygon = fresh.polygon
		poly.uv = fresh.uv
		poly.polygons = fresh.polygons
		poly.texture = fresh.texture
		poly.modulate.a = fresh.modulate.a
		fresh.queue_free()
	if static_changed:
		meta["tex"] = p["tex"]
		meta["rect"] = p["rect"]
		meta["grid_n"] = p["grid_n"]
		meta["ox"] = p["ox"]
		meta["oy"] = p["oy"]


func _part_node(st: Dictionary, p: Dictionary, kind: int) -> CanvasItem:
	if kind == 2:
		var masked := _masked_polygon(st, p)
		if masked:
			return masked
	if kind == 1:
		return _warp_polygon(st, p, null)
	return _plain_sprite(st, p)


func _plain_sprite(st: Dictionary, p: Dictionary) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.texture = _atlas(st["model"], st["name"], p["tex"])
	spr.region_enabled = true
	spr.region_rect = p["rect"]
	spr.centered = false
	spr.offset = Vector2(-p["ox"], -p["oy"])
	var m: Array = p["m"]
	spr.transform = Transform2D(Vector2(m[0], m[2]), Vector2(m[1], m[3]),
			Vector2(p["x"], p["y"]))
	spr.modulate.a = int(p["opa"]) / 255.0
	return spr


func _warp_polygon(st: Dictionary, p: Dictionary, masked_tex: Texture2D) -> Polygon2D:
	var poly := Polygon2D.new()
	_warp_setup(poly, st, p, masked_tex)
	return poly


## (Re)fill a warp polygon's geometry, UVs, topology and texture —
## used both for fresh nodes and for static changes on the fast path.
func _warp_setup(poly: Polygon2D, st: Dictionary, p: Dictionary, masked_tex: Texture2D) -> void:
	var r: Rect2i = p["rect"]
	var n: int = p["grid_n"]
	var w := float(r.size.x)
	var h := float(r.size.y)
	var grid: Array = p["grid"]
	var pts := PackedVector2Array()
	pts.resize(grid.size())
	for i in grid.size():
		pts[i] = grid[i]
	poly.polygon = pts
	var uvs := PackedVector2Array()
	uvs.resize(grid.size())
	for gy in n + 1:
		for gx in n + 1:
			if masked_tex:
				uvs[gy * (n + 1) + gx] = Vector2(w * gx / n, h * gy / n)
			else:
				uvs[gy * (n + 1) + gx] = Vector2(r.position.x + w * gx / n,
						r.position.y + h * gy / n)
	poly.uv = uvs
	var polys := []
	for gy in n:
		for gx in n:
			var i00 := gy * (n + 1) + gx
			polys.append(PackedInt32Array([i00, i00 + 1, i00 + n + 2, i00 + n + 1]))
	poly.polygons = polys
	poly.texture = masked_tex if masked_tex else _atlas(st["model"], st["name"], p["tex"])
	poly.antialiased = true
	poly.modulate.a = int(p["opa"]) / 255.0


# ---- stencil masking (CPU, icon resolution) ----

func _clip_is_noop(st: Dictionary, p: Dictionary) -> bool:
	# Masking is the identity when every geom's alpha is purely
	# geometric (fully-opaque icon or blank rect) and every grid point
	# of the part samples mask alpha ~1 (the common case: the whole
	# character inside the trimming frame, warped or not).
	for g in p["clip"]:
		if not g.has("blank") and not _icon_fully_opaque(st, g["tex"], g["icon"], g["rect"]):
			return false
	var auxs := []
	for g in p["clip"]:
		auxs.append(_geom_aux(st, g))
	for pt in p["grid"]:
		var inside := false
		for aux in auxs:
			if _geom_alpha_at(aux, pt) > 0.999:
				inside = true
				break
		if not inside:
			return false
	return true


static func _bary(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> Vector3:
	# Barycentric weights, or (-2, -2, -2) when p is outside the
	# triangle (beyond a small edge tolerance).
	var d := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
	if abs(d) < 0.000000001:
		return Vector3(-2, -2, -2)
	var w0 := ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / d
	var w1 := ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / d
	var w2 := 1.0 - w0 - w1
	if w0 < -0.001 or w1 < -0.001 or w2 < -0.001:
		return Vector3(-2, -2, -2)
	return Vector3(w0, w1, w2)


static func _point_in_quad(pt: Vector2, grid4: Array) -> bool:
	# grid order is TL, TR, BL, BR; quad triangles (TL,TR,BR), (TL,BR,BL)
	if _bary(pt, grid4[0], grid4[1], grid4[3]).x > -1.5:
		return true
	return _bary(pt, grid4[0], grid4[3], grid4[2]).x > -1.5


func _geom_aux(st: Dictionary, g: Dictionary) -> Dictionary:
	var grid: Array = g["grid"]
	var n := int(g["grid_n"])
	var box := Rect2(grid[0], Vector2.ZERO)
	for pt in grid:
		box = box.expand(pt)
	var cells := []
	for gy in n:
		for gx in n:
			var i00 := gy * (n + 1) + gx
			var cb := Rect2(grid[i00], Vector2.ZERO)
			cb = cb.expand(grid[i00 + 1])
			cb = cb.expand(grid[i00 + n + 1])
			cb = cb.expand(grid[i00 + n + 2])
			cells.append(cb)
	var aux := {"grid": grid, "n": n, "bbox": box, "cells": cells,
			"blank": g.has("blank"), "img": null, "w": 0.0, "h": 0.0}
	if g.has("blank"):
		aux["w"] = float(g["blank"][0])
		aux["h"] = float(g["blank"][1])
	else:
		var r: Rect2i = g["rect"]
		aux["w"] = float(r.size.x)
		aux["h"] = float(r.size.y)
		aux["img"] = _icon_image(st, g["tex"], g["icon"], r)
	return aux


func _geom_alpha_at(aux: Dictionary, pos: Vector2) -> float:
	if not (aux["bbox"] as Rect2).has_point(pos):
		return 0.0
	var grid: Array = aux["grid"]
	var n: int = aux["n"]
	var w: float = aux["w"]
	var h: float = aux["h"]
	var cells: Array = aux["cells"]
	for gy in n:
		for gx in n:
			if not (cells[gy * n + gx] as Rect2).has_point(pos):
				continue
			var i00 := gy * (n + 1) + gx
			var p00: Vector2 = grid[i00]
			var p10: Vector2 = grid[i00 + 1]
			var p01: Vector2 = grid[i00 + n + 1]
			var p11: Vector2 = grid[i00 + n + 2]
			var uv00 := Vector2(w * gx / n, h * gy / n)
			var uv10 := Vector2(w * (gx + 1) / n, h * gy / n)
			var uv01 := Vector2(w * gx / n, h * (gy + 1) / n)
			var uv11 := Vector2(w * (gx + 1) / n, h * (gy + 1) / n)
			var b := _bary(pos, p00, p10, p11)
			var uv := Vector2.ZERO
			if b.x > -1.5:
				uv = b.x * uv00 + b.y * uv10 + b.z * uv11
			else:
				b = _bary(pos, p00, p11, p01)
				if b.x <= -1.5:
					continue
				uv = b.x * uv00 + b.y * uv11 + b.z * uv01
			if aux["blank"]:
				return 1.0
			var img: Image = aux["img"]
			if img == null:
				return 0.0
			var px := clampi(int(uv.x), 0, img.get_width() - 1)
			var py := clampi(int(uv.y), 0, img.get_height() - 1)
			return img.get_pixel(px, py).a
	return 0.0


func _masked_polygon(st: Dictionary, p: Dictionary) -> Polygon2D:
	var tex := _masked_texture(st, p)
	if tex == null:
		return null
	return _warp_polygon(st, p, tex)


## Quantized grid dump for cache keys: 0.5 px steps — the same
## tolerance the render signature uses for offsets. Mask alpha
## sampled at icon resolution cannot tell the difference.
func _quant_grid(grid: Array) -> String:
	var parts := PackedStringArray()
	for pt in grid:
		var v: Vector2 = pt
		parts.append(str(int(round(v.x * 2.0))) + ","
				+ str(int(round(v.y * 2.0))))
	return ";".join(parts)


## The baked texture of a masked part is a pure function of the
## part's icon, its own grid, and its clip geoms (each: blank dims
## or icon + grid). During driver animation the whole character
## usually moves together, so the quantized key stays stable for
## long stretches and the per-pixel bake runs once, not per render.
func _mask_key(st: Dictionary, p: Dictionary) -> String:
	var sb := PackedStringArray()
	sb.append(str(st["name"]) + "|" + str(p["tex"]) + "|"
			+ str(p["icon"]) + "|" + str(p["rect"]) + "|"
			+ str(p["grid_n"]))
	sb.append(_quant_grid(p["grid"]))
	for g in p["clip"]:
		if g.has("blank"):
			sb.append("B" + str(g["blank"][0]) + "x" + str(g["blank"][1]))
		else:
			sb.append(str(g["tex"]) + "|" + str(g["icon"]) + "|"
					+ str(g["rect"]))
		sb.append(str(g["grid_n"]) + ":" + _quant_grid(g["grid"]))
	return "\n".join(sb)


func _masked_texture(st: Dictionary, p: Dictionary) -> Texture2D:
	var key := _mask_key(st, p)
	if _mask_cache.has(key):
		stats_mask_hits += 1
		_mask_lru.erase(key)
		_mask_lru.append(key)
		return _mask_cache[key]
	stats_mask_bakes += 1
	var tex := _bake_masked_texture(st, p)
	if tex == null:
		return null
	_mask_cache[key] = tex
	_mask_lru.append(key)
	var r: Rect2i = p["rect"]
	var nbytes := r.size.x * r.size.y * 4
	_mask_sizes[key] = nbytes
	_mask_bytes += nbytes
	while _mask_bytes > MASK_CACHE_BUDGET and _mask_lru.size() > 1:
		var victim: String = _mask_lru.pop_front()
		_mask_bytes -= int(_mask_sizes.get(victim, 0))
		_mask_sizes.erase(victim)
		_mask_cache.erase(victim)
	return tex


func _bake_masked_texture(st: Dictionary, p: Dictionary) -> Texture2D:
	var base := _icon_image(st, p["tex"], p["icon"], p["rect"])
	if base == null:
		return null
	var img := base.duplicate() as Image
	var w := img.get_width()
	var h := img.get_height()
	var n: int = p["grid_n"]
	var grid: Array = p["grid"]
	var auxs := []
	for g in p["clip"]:
		auxs.append(_geom_aux(st, g))
	for py in h:
		for px in w:
			var fx := (px + 0.5) / w * n
			var fy := (py + 0.5) / h * n
			var gx := mini(int(fx), n - 1)
			var gy := mini(int(fy), n - 1)
			var lx := fx - gx
			var ly := fy - gy
			var i00 := gy * (n + 1) + gx
			var pos: Vector2 = (grid[i00] * (1.0 - lx) * (1.0 - ly)
					+ grid[i00 + 1] * lx * (1.0 - ly)
					+ grid[i00 + n + 1] * (1.0 - lx) * ly
					+ grid[i00 + n + 2] * lx * ly)
			var acc := 0.0
			for aux in auxs:
				var a := _geom_alpha_at(aux, pos)
				acc = a + acc * (1.0 - a)
				if acc >= 0.999:
					break
			if acc < 0.999:
				var col := img.get_pixel(px, py)
				if col.a > 0.0:
					col.a *= acc
					img.set_pixel(px, py, col)
	return ImageTexture.create_from_image(img)


# ---- drivers: pose transitions, blink, lip sync, physics ----

func _signature(rvars: Dictionary, offsets: Dictionary) -> String:
	var keys := rvars.keys()
	keys.sort()
	var parts := []
	for k in keys:
		parts.append("%s=%.2f" % [k, float(rvars[k])])
	for k in offsets:
		var v: Vector2 = offsets[k]
		parts.append("@%s=%.1f,%.1f" % [k, round(v.x * 2.0) / 2.0,
				round(v.y * 2.0) / 2.0])
	return "|".join(parts)


func _process(delta: float) -> void:
	if _slots.is_empty():
		return
	_time += delta
	var any := false
	for slot in _slots.keys():
		if _drive_slot(slot, delta):
			any = true
	if any:
		_layout_slots()


func _drive_slot(slot: int, delta: float) -> bool:
	var st: Dictionary = _slots[slot]
	# pose transition: interpolate the variable dict
	var tr: Variant = st["trans"]
	if tr != null:
		tr["t"] = float(tr["t"]) + delta
		var u := clampf(float(tr["t"]) / maxf(float(tr["dur"]), 0.001), 0.0, 1.0)
		var from: Dictionary = tr["from"]
		var to: Dictionary = tr["to"]
		var rv := {}
		for k in to:
			rv[k] = lerpf(float(from.get(k, to[k])), float(to[k]), u)
		for k in from:
			if not to.has(k):
				rv[k] = from[k]
		st["rvars"] = rv
		if u >= 1.0:
			st["trans"] = null
	# blink: eyeControl timers (@60fps frame counts in the metadata)
	var blink_off := 0.0
	var eye: Dictionary = st["eye"]
	if not eye.is_empty() and int(eye.get("blinkEnabled", 0)) == 1:
		if float(st["blink_t"]) >= 0.0:
			st["blink_t"] = float(st["blink_t"]) + delta
			var cycle := float(eye.get("blinkFrameCount", 16)) / 60.0
			var phase := float(st["blink_t"]) / cycle
			if phase >= 1.0:
				st["blink_t"] = -1.0
				st["blink_next"] = randf_range(
						float(eye.get("blinkIntervalMin", 30)),
						float(eye.get("blinkIntervalMax", 180))) / 60.0
			else:
				blink_off = sin(phase * PI) * BLINK_AMP
		else:
			st["blink_next"] = float(st["blink_next"]) - delta
			if float(st["blink_next"]) <= 0.0:
				st["blink_t"] = 0.0
				stats_blinks += 1
	# lip sync: talk label driven by the voice bus level
	var talk_label: String = st["talk_label"]
	var talk_target := 0.0
	if talk_label != "":
		if _voice_level > 0.02:
			talk_target = clampf(_voice_level * 1.5, 0.0, 1.0) * 5.0 \
					* (0.55 + 0.45 * sin(_time * 23.0))
		st["talk_v"] = lerpf(float(st["talk_v"]), talk_target,
				clampf(delta * 16.0, 0.0, 1.0))
	# physics: damped springs on the control base layers
	var dt := minf(delta, 0.033)
	var phys_settled := true
	for base_layer in st["phys"]:
		var ph: Dictionary = st["phys"][base_layer]
		var p: Vector2 = ph["p"]
		var v: Vector2 = ph["v"]
		if p.length() > 0.005 or v.length() > 0.005:
			var acc := -120.0 * p - 10.0 * v
			v += acc * dt
			p += v * dt
			ph["p"] = p
			ph["v"] = v
		if p.length() > 0.05 or v.length() > 0.2:
			phys_settled = false
	# Compose and render only on real change; while drivers are active,
	# coalesce re-renders (each is a full pose re-evaluation), but
	# always render the settled state. The coalesce interval adapts to
	# the measured cost of the slot's last render: on fast platforms it
	# stays at the 0.05 s floor (smooth), on the single-threaded Web
	# build a 300 ms evaluation stretches it so rendering cannot starve
	# everything else.
	st["drv_t"] = float(st["drv_t"]) + delta
	# The coalesce cap doubles when no pose transition is running:
	# talk-level and blink re-renders are then spread further apart so
	# a 100-300 ms evaluation cannot eat most of the frame budget.
	# Transitions stay tight to keep pose changes smooth.
	var drv_cap := 0.15 if st["trans"] != null else 0.45
	var drv_interval := clampf(2.0 * float(st.get("last_ms", 0.0)) / 1000.0,
			0.08, drv_cap)
	var rv: Dictionary = (st["rvars"] as Dictionary).duplicate()
	if blink_off > 0.0:
		var label: String = eye.get("label", "face_eye_open")
		rv[label] = float(rv.get(label, 0.0)) + round(blink_off / 2.0) * 2.0
	if talk_label != "" and float(st["talk_v"]) > 0.02:
		# Mouth shapes are discrete levels (talk_v lives on a 0..5
		# scale): quantize before the value reaches the render
		# signature, or level jitter re-renders the slot every tick.
		rv[talk_label] = float(rv.get(talk_label, 0.0)) \
				+ roundf(float(st["talk_v"]))
	var offsets := _phys_offsets(st)
	if _signature(rv, offsets) == st["sig"]:
		return false
	var idle := st["trans"] == null and float(st["blink_t"]) < 0.0 \
			and absf(float(st["talk_v"]) - talk_target) < 0.02 and phys_settled
	if not idle and float(st["drv_t"]) < drv_interval:
		return false
	st["drv_t"] = 0.0
	_render_slot(slot, 0.0, rv, offsets)
	return true


func _slot_bbox(st: Dictionary) -> Rect2:
	var parts: Array = st.get("parts", [])
	var first := true
	var box := Rect2()
	for p in parts:
		if not p["vis"] or int(p["opa"]) <= 0:
			continue
		for pt in p["grid"]:
			if first:
				box = Rect2(pt, Vector2.ZERO)
				first = false
			else:
				box = box.expand(pt)
	return box


func _pos_state(slot: int) -> Dictionary:
	if not _pos.has(slot):
		_pos[slot] = {"ax": float(DEFAULT_ANCHOR_X.get(slot, 640)), "ay": 0.0,
				"off": Vector2.ZERO, "sbase": 0, "smult": 1.0,
				"tw_off": null, "tw_scale": null}
	return _pos[slot]


func pos_set(_pair: String, slot: int, x: int, y: int) -> void:
	var ps := _pos_state(slot)
	ps["ax"] = float(x)
	ps["ay"] = float(y)
	_layout_slots()


func pos_move(slot: int, dx: int, dy: int, ms: int) -> void:
	var ps := _pos_state(slot)
	if _slots.has(slot):
		_excite(_slots[slot], Vector2(dx * 0.15, dy * 0.15 + 6.0))
	if ps["tw_off"] != null and (ps["tw_off"] as Tween).is_valid():
		(ps["tw_off"] as Tween).kill()
	var from: Vector2 = ps["off"]
	var to := from + Vector2(dx, dy)
	if ms <= 0 or not is_inside_tree():
		ps["off"] = to
		_layout_slots()
		return
	var tw := create_tween()
	ps["tw_off"] = tw
	tw.tween_method(func(v: Vector2) -> void:
			ps["off"] = v
			_layout_slots(), from, to, ms / 1000.0)


func chara_scale(slot: int, raw: int, ms: int) -> void:
	var ps := _pos_state(slot)
	if int(ps["sbase"]) == 0:
		ps["sbase"] = raw
		ps["smult"] = 1.0
		_layout_slots()
		return
	if ps["tw_scale"] != null and (ps["tw_scale"] as Tween).is_valid():
		(ps["tw_scale"] as Tween).kill()
	var from: float = ps["smult"]
	var to := raw / float(ps["sbase"])
	if ms <= 0 or not is_inside_tree():
		ps["smult"] = to
		_layout_slots()
		return
	var tw := create_tween()
	ps["tw_scale"] = tw
	tw.tween_method(func(v: float) -> void:
			ps["smult"] = v
			_layout_slots(), from, to, ms / 1000.0)


func _layout_slots() -> void:
	for slot in _slots.keys():
		var st: Dictionary = _slots[slot]
		var box := _slot_bbox(st)
		if box.size == Vector2.ZERO:
			continue
		# Fit the model's visible height to the stage (native model
		# coordinates are ~2x stage height for full-body models).
		var fit := minf(1.0, 700.0 / box.size.y) if box.size.y > 0.0 else 1.0
		var cx := 640.0
		var by := 716.0
		var smult := 1.0
		if slot < HC_OFFSET:
			var ps := _pos_state(slot)
			cx = ps["ax"] + (ps["off"] as Vector2).x
			by = 716.0 + ps["ay"] + (ps["off"] as Vector2).y
			smult = ps["smult"]
		var scale := fit * smult
		st["root"].scale = Vector2(scale, scale)
		st["root"].position = Vector2(
				cx - (box.position.x + box.size.x / 2.0) * scale,
				by - (box.position.y + box.size.y) * scale)


# ---- save state ----

func get_state() -> Dictionary:
	var slots := {}
	for slot in _slots:
		slots[str(slot)] = {"name": _slots[slot]["name"], "vars": _slots[slot]["vars"]}
	var pos := {}
	for slot in _pos:
		var ps: Dictionary = _pos[slot]
		pos[str(slot)] = {"ax": ps["ax"], "ay": ps["ay"],
				"off": [(ps["off"] as Vector2).x, (ps["off"] as Vector2).y],
				"sbase": ps["sbase"], "smult": ps["smult"]}
	return {"bg": _bg_name, "slots": slots, "pos": pos}


func apply_state(state: Dictionary) -> void:
	for slot in _slots.keys():
		emote_unload(slot)
	if state.get("bg", "") != "":
		show_image(state["bg"])
	for slot_key in state.get("slots", {}):
		var sd: Dictionary = state["slots"][slot_key]
		emote_load(int(slot_key), sd["name"])
		_slots[int(slot_key)]["vars"] = sd["vars"]
		_slots[int(slot_key)]["rvars"] = (sd["vars"] as Dictionary).duplicate()
		_render_slot(int(slot_key), 0.0, sd["vars"], {})
	for slot_key in state.get("pos", {}):
		var pd: Dictionary = state["pos"][slot_key]
		var ps := _pos_state(int(slot_key))
		ps["ax"] = float(pd.get("ax", ps["ax"]))
		ps["ay"] = float(pd.get("ay", 0.0))
		var off: Array = pd.get("off", [0, 0])
		ps["off"] = Vector2(float(off[0]), float(off[1]))
		ps["sbase"] = int(pd.get("sbase", 0))
		ps["smult"] = float(pd.get("smult", 1.0))
	_layout_slots()
