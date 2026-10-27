class_name Stage
extends Node2D
## Stage presentation: BG/CG layer, E-mote slots, transition flashes.
##
## Approximations (v1, see docs/architecture.md): transitions 1/33/34/35
## render as a fade-from-black of the given duration (the reference
## converter did the equivalent with Dissolve); slot screen positions use
## a bottom-center anchor heuristic (the original positions characters
## through ops 0x53/0x54/0x59 whose full semantics are still open);
## E-mote poses are static evaluated frames (no blink/lip timelines yet).

const SLOT_X := {0: 640, 1: 320, 2: 960, 3: 150, 4: 1130}
const HC_OFFSET := 100

var pkg: GamePackage
var define: DefineTable

var _bg: Sprite2D
var _bg_name := ""
var _slots: Dictionary = {}  # slot -> {root, parts_root, model, name, vars}
var _model_cache: Dictionary = {}
var _tex_cache: Dictionary = {}
var _overlay: ColorRect
var _movie_panel: PanelContainer
var _movie_label: Label
var _last_change := false


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
	_movie_panel.add_child(_movie_label)
	layer.add_child(_movie_panel)


func setup(p_pkg: GamePackage, p_define: DefineTable) -> void:
	pkg = p_pkg
	define = p_define


# ---- background / CG ----

func show_image(image_name: String) -> void:
	var bytes := pkg.image_bytes(image_name)
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


# ---- E-mote slots ----

func _model(model_name: String) -> EmoteModel:
	if _model_cache.has(model_name):
		return _model_cache[model_name]
	var bytes := pkg.psb_bytes(model_name)
	if bytes.is_empty():
		push_warning("Stage: model not found: " + model_name)
		return null
	var model := EmoteModel.from_psb(Psb.parse(bytes))
	_model_cache[model_name] = model
	return model


func _atlas(model: EmoteModel, model_name: String, tex_key: String) -> Texture2D:
	var key := model_name + "|" + tex_key
	if _tex_cache.has(key):
		return _tex_cache[key]
	var img := model.texture_image(tex_key)
	var tex: Texture2D = ImageTexture.create_from_image(img) if img else null
	_tex_cache[key] = tex
	return tex


func emote_load(slot: int, model_name: String) -> void:
	emote_unload(slot)
	var model := _model(model_name)
	if model == null:
		return
	var root := Node2D.new()
	root.z_index = 10 + slot
	add_child(root)
	var parts_root := Node2D.new()
	root.add_child(parts_root)
	_slots[slot] = {"root": root, "parts_root": parts_root, "model": model,
			"name": model_name, "vars": {}}
	_render_slot(slot, 0.0)
	_layout_slots()


func emote_load_hc(slot: int, model_name: String) -> void:
	emote_load(slot + HC_OFFSET, model_name)


func emote_unload(slot: int) -> void:
	if _slots.has(slot):
		_slots[slot]["root"].queue_free()
		_slots.erase(slot)
		_layout_slots()


func emote_pose(slot: int, label: String, time_ms: int) -> void:
	if not _slots.has(slot):
		return
	var pose := define.pose_vars(label)
	if pose.is_empty():
		push_warning("Stage: unknown em label: " + label)
		return
	var cur: Dictionary = _slots[slot]["vars"]
	if pose.size() >= 15:
		_slots[slot]["vars"] = pose.duplicate()
	else:
		for k in pose:
			cur[k] = pose[k]
	_render_slot(slot, clampi(time_ms, 0, 800) / 1000.0)
	_layout_slots()


func _render_slot(slot: int, fade_seconds: float) -> void:
	var st: Dictionary = _slots[slot]
	var model: EmoteModel = st["model"]
	var parts := model.collect(model.base_chara(), model.base_motion(), st["vars"])
	var old_root: Node2D = st["parts_root"]
	var new_root := Node2D.new()
	st["root"].add_child(new_root)
	var order := 0
	for p in parts:
		if not p["vis"] or int(p["opa"]) <= 0:
			continue
		var spr := Sprite2D.new()
		spr.texture = _atlas(model, st["name"], p["tex"])
		spr.region_enabled = true
		spr.region_rect = p["rect"]
		spr.centered = false
		spr.offset = Vector2(-p["ox"], -p["oy"])
		var m: Array = p["m"]
		spr.transform = Transform2D(Vector2(m[0], m[2]), Vector2(m[1], m[3]),
				Vector2(p["x"], p["y"]))
		spr.modulate.a = int(p["opa"]) / 255.0
		spr.z_index = order
		order += 1
		new_root.add_child(spr)
	st["parts_root"] = new_root
	st["parts"] = parts
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


func _slot_bbox(st: Dictionary) -> Rect2:
	var parts: Array = st.get("parts", [])
	var first := true
	var box := Rect2()
	for p in parts:
		if not p["vis"] or int(p["opa"]) <= 0:
			continue
		var m: Array = p["m"]
		var size: Vector2 = (p["rect"] as Rect2i).size
		for corner in [Vector2.ZERO, Vector2(size.x, 0), size, Vector2(0, size.y)]:
			var d: Vector2 = corner - Vector2(float(p["ox"]), float(p["oy"]))
			var pt: Vector2 = Vector2(float(p["x"]), float(p["y"])) + Vector2(
					float(m[0]) * d.x + float(m[1]) * d.y,
					float(m[2]) * d.x + float(m[3]) * d.y)
			if first:
				box = Rect2(pt, Vector2.ZERO)
				first = false
			else:
				box = box.expand(pt)
	return box


func _layout_slots() -> void:
	var active: Array = _slots.keys()
	for slot in active:
		var st: Dictionary = _slots[slot]
		var box := _slot_bbox(st)
		if box.size == Vector2.ZERO:
			continue
		var cx := 640.0
		if active.size() > 1:
			cx = SLOT_X.get(slot % HC_OFFSET, 640)
		# Fit the model's visible height to the stage (native model
		# coordinates are ~2x stage height for full-body models).
		var fit := minf(1.0, 700.0 / box.size.y) if box.size.y > 0.0 else 1.0
		st["root"].scale = Vector2(fit, fit)
		st["root"].position = Vector2(
				cx - (box.position.x + box.size.x / 2.0) * fit,
				716.0 - (box.position.y + box.size.y) * fit)


# ---- save state ----

func get_state() -> Dictionary:
	var slots := {}
	for slot in _slots:
		slots[str(slot)] = {"name": _slots[slot]["name"], "vars": _slots[slot]["vars"]}
	return {"bg": _bg_name, "slots": slots}


func apply_state(state: Dictionary) -> void:
	for slot in _slots.keys():
		emote_unload(slot)
	if state.get("bg", "") != "":
		show_image(state["bg"])
	for slot_key in state.get("slots", {}):
		var sd: Dictionary = state["slots"][slot_key]
		emote_load(int(slot_key), sd["name"])
		_slots[int(slot_key)]["vars"] = sd["vars"]
		_render_slot(int(slot_key), 0.0)
	_layout_slots()
