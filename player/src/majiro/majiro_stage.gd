class_name MajiroStage
extends CanvasLayer
## Presentation host for MajiroVm (docs/majiro-presentation-design.md):
## page pool with alfa companions, sprite list in engine link order,
## grp_* pixel ops on page Images with frame-end texture flush, and the
## input/timing waits (mk_wait / wait / draw_wait) built on the VM's
## thread "wait" flag + pc rewind suspension.
##
## Value dicts use MajiroVm's shape {"k": kind, "v": payload}.
## Handles are plain ints; pages and sprites share one id space.
## alfa polarity everywhere: 0 = opaque, 255 = fully transparent.

const K_INT := 0
const K_FLOAT := 1
const K_STRING := 2

const FRONT := 0xF0000001
const CLIENT_W := 1024
const CLIENT_H := 768

var vm: MajiroVm
var vfs: MajiroVfs

var _pages := {}        # id -> {img, tex, alfa, format, drawmode, dirty, mat}
var _sprites := {}      # id -> record (see _sprite_create)
var _order: Array = []  # sprite ids: head = bottom, tail = top
var _order_stack: Array = []
var _next_id := 0x10000
var _front_rect: TextureRect
var _sprite_root: Node2D
var _alfa_shader: Shader

var time_ms := 0
## Test-harness speed multiplier for stage time (set by the player's
## --tscale flag; 1.0 = real time). Timed waits, transitions, fades
## and menu timeouts all read time_ms, so this compresses them
## uniformly without touching frame-sync waits.
var time_scale := 1.0
var _frame_no := 0
var effect_speed := 1000
var invalidate_enabled := true
var click_bits := 0     # pending mk_wait result: 1=L, 2=R, 4=M
var area_click_bits := 0   # areaevent's own click latch (mk_unwait
var area_click_pos := Vector2.ZERO  # must not starve area clicks)
var mouse_pos := Vector2.ZERO
var unhandled := {}     # stage-side recorded stubs: hash -> count

var _console = null  # MajiroConsole, set by the player (phase 2)
var _audio: Node = null          # MajiroAudio, set by the player (phase 4)
var _areas: Array = []           # areaevent records (phase 3)
var _area_defaults := {}


static func _ai(v: Dictionary) -> int:
	match int(v["k"]):
		K_INT:
			return int(v["v"])
		K_FLOAT:
			return int(float(v["v"]))
		K_STRING:
			return (v["v"] as PackedByteArray).get_string_from_ascii().to_int()
	return 0


static func _af(v: Dictionary) -> float:
	match int(v["k"]):
		K_FLOAT:
			return float(v["v"])
		K_INT:
			return float(int(v["v"]))
	return 0.0


static func _ab(v: Dictionary) -> PackedByteArray:
	if int(v["k"]) == K_STRING:
		return v["v"]
	if int(v["k"]) == K_INT:
		return str(int(v["v"])).to_ascii_buffer()
	return PackedByteArray()


func _ready() -> void:
	_alfa_shader = Shader.new()
	_alfa_shader.code = """shader_type canvas_item;
uniform sampler2D alfa_tex : filter_nearest;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float m = texture(alfa_tex, UV).r;
	COLOR = vec4(c.rgb, COLOR.a * (1.0 - m));
}
"""
	_front_rect = TextureRect.new()
	_front_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_front_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_front_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_front_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_front_rect)
	_sprite_root = Node2D.new()
	add_child(_sprite_root)
	_new_page_rec(FRONT, CLIENT_W, CLIENT_H, 0)
	_front_rect.texture = _pages[FRONT]["tex"]


func bind(p_vm: MajiroVm, p_vfs: MajiroVfs) -> void:
	vm = p_vm
	vfs = p_vfs


# ------------------------------------------------------------ suspension

## Suspend the calling thread: flag it waited and rewind its pc over
## the syscall instruction (8 bytes) so it re-executes on wake.
func _suspend() -> void:
	var t: Dictionary = vm._cur
	t["wait"] = 1
	t["syscall_restore"] = true
	var frames: Array = t["frames"]
	if not frames.is_empty():
		var fr: Dictionary = frames[frames.size() - 1]
		fr["pc"] = int(fr["pc"]) - 8


func _wake(t: Dictionary) -> void:
	t["wait"] = 0


func _thread_by_tid(tid: int) -> Variant:
	for t in vm._threads:
		if int(t.get("tid", -1)) == tid:
			return t
	return null


## True when every thread in the caller's join set has finished
## (do_event_single: the transition workers ran to completion).
func _join_finished(t: Dictionary) -> bool:
	for tid in t["join_tids"]:
		var wt: Variant = _thread_by_tid(int(tid))
		if wt != null and not bool((wt as Dictionary).get("done", false)):
			return false
	return true


var _trans_rect: TextureRect = null
var _trans_page := 0
var _trans_start := 0
var _trans_dur := 1


func _process(delta: float) -> void:
	time_ms += int(delta * 1000.0 * time_scale)
	_frame_no += 1
	_tick_waits()
	_tick_anims(delta)
	_tick_trans()
	_flush_dirty()


## Visual side of DO_TRANSITION: crossfade the front buffer toward the
## transition page over the event duration; on completion the front
## page takes the target's pixels. (Effect types beyond the plain
## crossfade belong to the phase-5 pass.)
func _tick_trans() -> void:
	if _trans_rect == null:
		return
	var t := 1.0
	if _trans_dur > 0:
		t = clampf(float(time_ms - _trans_start) / float(_trans_dur), 0.0, 1.0)
	_trans_rect.modulate.a = t
	if t >= 1.0:
		_finish_trans()


func _begin_trans(page_id: int, dur: int) -> void:
	if _trans_rect != null:
		_finish_trans()
	if not _pages.has(page_id) or page_id == FRONT:
		return
	_trans_page = page_id
	_trans_start = time_ms
	_trans_dur = maxi(1, dur)
	_trans_rect = TextureRect.new()
	_trans_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_trans_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_trans_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_trans_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_trans_rect.texture = _pages[page_id]["tex"]
	_trans_rect.modulate.a = 0.0
	add_child(_trans_rect)
	move_child(_trans_rect, _sprite_root.get_index())


func _finish_trans() -> void:
	if _trans_rect == null:
		return
	if not _pages.has(_trans_page) or not _pages.has(FRONT):
		# Transition page already gone: tear the overlay down instead
		# of throwing every frame and wedging the transition state.
		remove_child(_trans_rect)
		_trans_rect.queue_free()
		_trans_rect = null
		return
	var src: Dictionary = _pages[_trans_page]
	var front: Dictionary = _pages[FRONT]
	_px_flush(src)
	_px_invalidate(front)
	var simg: Image = src["img"]
	var fimg: Image = front["img"]
	if simg.get_width() <= fimg.get_width() and simg.get_height() <= fimg.get_height():
		fimg.blit_rect(simg, Rect2i(0, 0, simg.get_width(), simg.get_height()), Vector2i.ZERO)
	else:
		front["img"] = simg.duplicate()
		front["tex"] = ImageTexture.create_from_image(front["img"])
		_front_rect.texture = front["tex"]
	var sa := int(src["alfa"])
	if sa != 0 and _pages.has(sa):
		var dsta := int(front["alfa"])
		if dsta != 0 and _pages.has(dsta):
			var dimg: Image = _pages[dsta]["img"]
			var aimg: Image = _pages[sa]["img"]
			if dimg.get_size() == aimg.get_size():
				dimg.blit_rect(aimg, Rect2i(0, 0, aimg.get_width(), aimg.get_height()), Vector2i.ZERO)
				_pages[dsta]["dirty"] = true
	front["dirty"] = true
	remove_child(_trans_rect)
	_trans_rect.queue_free()
	_trans_rect = null


func _tick_waits() -> void:
	for t in vm._threads:
		if int(t.get("wait", 0)) == 0:
			continue
		if t.has("join_tids"):
			if _join_finished(t):
				t.erase("join_tids")
				t["join_done"] = true
				_wake(t)
				continue
			if click_bits != 0:
				# Click-skip: kill the joined workers (their bsel.5
				# destructors run), then fall through to the generic
				# click-skip below, which moves the caller itself to
				# its armed destructor.
				for tid in t["join_tids"]:
					var wt: Variant = _thread_by_tid(int(tid))
					if wt != null and not bool((wt as Dictionary).get("done", false)):
						vm._kill_thread(wt)
				t.erase("join_tids")
			else:
				continue
		if click_bits != 0 and not t.has("stage_trans_until"):
			# Click-skip: abandon the suspended syscall and run the
			# top frame's bsel.5 destructor (the engine's skip path
			# for pic/transit/yazlib workers).
			var frames: Array = t["frames"]
			if not frames.is_empty():
				var fr: Dictionary = frames[frames.size() - 1]
				var dtor := int(fr.get("dtor", 0))
				if dtor != 0 and not bool(fr.get("in_dtor", false)):
					fr["pc"] = dtor
					fr["in_dtor"] = true
					t.erase("stage_wait_until")
					t.erase("stage_wait_frame")
					t.erase("ts_until")
					t.erase("ts_ret")
					t.erase("dw_armed")
					t.erase("mk_armed")
					t.erase("poll_armed")
					_wake(t)
					continue
		if t.has("stage_trans_until"):
			if time_ms >= int(t["stage_trans_until"]) or click_bits != 0:
				t.erase("stage_trans_until")
				t["trans_done"] = true
				_wake(t)
			continue
		if bool(t.get("dw_armed", false)):
			_wake(t)
		elif t.has("stage_wait_until") and time_ms >= int(t["stage_wait_until"]):
			# Do NOT erase: _sc_wait owns the key and checks it on
			# re-execution to decide the wait is over. Erasing here
			# made every wait() re-arm forever (deadlock, found via
			# pic's transition-flag wait loop).
			_wake(t)
		elif t.has("stage_wait_frame") and _frame_no >= int(t["stage_wait_frame"]):
			_wake(t)
		elif t.has("ts_until") and time_ms >= int(t["ts_until"]):
			_wake(t)
		elif bool(t.get("text_wait", false)) and _console != null and not bool(_console.get("waiting")):
			t.erase("text_wait")
			_wake(t)
		elif bool(t.get("mk_armed", false)) and click_bits != 0:
			_wake(t)
		elif bool(t.get("poll_armed", false)):
			_wake(t)


# ---------------------------------------------------------------- pages

func _alloc_id() -> int:
	var id := _next_id
	_next_id += 1
	return id


func _new_page_rec(id: int, w: int, h: int, format: int) -> Dictionary:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 1))
	var rec := {
		"id": id,
		"img": img, "tex": ImageTexture.create_from_image(img),
		"alfa": 0, "format": format, "drawmode": 0, "dirty": false,
		"mat": null,
	}
	_pages[id] = rec
	return rec


func _page(id: int) -> Variant:
	return _pages.get(id, null)


func _set_page_image(rec: Dictionary, img: Image) -> void:
	rec.erase("px")
	rec["px_dirty"] = false
	rec["img"] = img
	rec["tex"] = ImageTexture.create_from_image(img)
	rec["dirty"] = false
	# re-point sprites and materials that used the old texture
	for sid in _order:
		var spr: Dictionary = _sprites[sid]
		if int(spr["page"]) == int(rec["id"]):
			(spr["node"] as Sprite2D).texture = rec["tex"]
	_update_material(rec)
	if int(rec["id"]) == FRONT:
		_front_rect.texture = rec["tex"]


func _update_material(rec: Dictionary) -> void:
	var alfa_id := int(rec["alfa"])
	if alfa_id == 0 or not _pages.has(alfa_id):
		rec["mat"] = null
		return
	var mat := ShaderMaterial.new()
	mat.shader = _alfa_shader
	mat.set_shader_parameter("alfa_tex", _pages[alfa_id]["tex"])
	rec["mat"] = mat


func _attach_alfa(rec: Dictionary, alfa_id: int) -> void:
	rec["alfa"] = alfa_id
	_update_material(rec)
	for sid in _order:
		var spr: Dictionary = _sprites[sid]
		if int(spr["page"]) == int(rec["id"]):
			(spr["node"] as Sprite2D).material = rec["mat"]


func _release_page(id: int) -> void:
	if id == FRONT or not _pages.has(id):
		return
	if id == _trans_page and _trans_rect != null:
		# The page under an active transition is being released:
		# snap the transition to completion first (the engine blocks
		# inside do_event_single, so scripts never see a half state).
		_finish_trans()
	var rec: Dictionary = _pages[id]
	var alfa_id := int(rec["alfa"])
	_pages.erase(id)
	if alfa_id != 0:
		_release_page(alfa_id)


func _flush_dirty() -> void:
	if not invalidate_enabled:
		return
	for id in _pages:
		var rec: Dictionary = _pages[id]
		if bool(rec["dirty"]):
			_px_flush(rec)
			(rec["tex"] as ImageTexture).update(rec["img"])
			rec["dirty"] = false


## Pixel-data cache: pixel-editing grp ops keep the page's byte array
## in the record instead of copying the whole image in and out per
## call (a full-screen get_data/set_data round-trip per row made
## script-side fade loops minutes slow). Writers reassign rec["px"]
## at the end (PackedByteArray is copy-on-write). Direct Image-space
## writes flush and drop the cache first so the two never desync.
func _px(rec: Dictionary) -> PackedByteArray:
	if rec.has("px"):
		return rec["px"]
	var data: PackedByteArray = (rec["img"] as Image).get_data()
	rec["px"] = data
	return data


func _px_flush(rec: Dictionary) -> void:
	if bool(rec.get("px_dirty", false)) and rec.has("px"):
		var img: Image = rec["img"]
		img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, rec["px"])
		rec["px_dirty"] = false


func _px_invalidate(rec: Dictionary) -> void:
	_px_flush(rec)
	rec.erase("px")
	rec["px_dirty"] = false


var _decode_cache := {}

## Decode an image file from the VFS (cached). Returns {w, h, rgb,
## kind} or {}.
func _decode_file(raw_name: PackedByteArray) -> Dictionary:
	var key := raw_name.get_string_from_ascii()
	if _decode_cache.has(key):
		return _decode_cache[key]
	var bytes := vfs.read_file_bytes(raw_name)
	if bytes.is_empty():
		# The engine completes image names with the .rct / .rc8
		# extension (scripts pass e.g. ブランドロゴ for ブランドロゴ.rct).
		for ext in [".rct", ".rc8"]:
			var cand: PackedByteArray = raw_name + ext.to_ascii_buffer()
			bytes = vfs.read_file_bytes(cand)
			if not bytes.is_empty():
				break
	if bytes.is_empty():
		_decode_cache[key] = {}
		return {}
	var rct := MajiroRct.decode(bytes)
	if rct == null:
		_decode_cache[key] = {}
		return {}
	var rgb := rct.rgb
	if rct.kind == "TC01" and rct.base_name != "":
		var base := MajiroRct.decode(vfs.read_file(rct.base_name))
		if base != null:
			rgb = MajiroRct.composite(rgb, base.rgb)
	var out := {"w": rct.width, "h": rct.height, "rgb": rgb, "kind": rct.kind}
	_decode_cache[key] = out
	return out


func _img_from_rgb(d: Dictionary) -> Image:
	var img := Image.create(int(d["w"]), int(d["h"]), false, Image.FORMAT_RGBA8)
	var rgb: PackedByteArray = d["rgb"]
	var data := PackedByteArray()
	data.resize(int(d["w"]) * int(d["h"]) * 4)
	for i in range(0, rgb.size(), 3):
		var o := (i / 3) * 4
		data[o] = rgb[i]
		data[o + 1] = rgb[i + 1]
		data[o + 2] = rgb[i + 2]
		data[o + 3] = 255
	img.set_data(int(d["w"]), int(d["h"]), false, Image.FORMAT_RGBA8, data)
	return img


## The alfa companion name for an image file: strip the extension and
## append the constant suffix (format spec 12.1: `_.rc8` rule).
static func _alfa_name(raw_name: PackedByteArray) -> String:
	var name := MajiroText.decode_cp932(raw_name)
	var dot := name.rfind(".")
	if dot > 0:
		name = name.substr(0, dot)
	return name + "_.rc8"


## Load a file into a fresh page record. with_alfa attaches the _.rc8
## companion as an 8bpp alfa page when present.
func _page_from_file(raw_name: PackedByteArray, with_alfa: bool) -> int:
	var d := _decode_file(raw_name)
	if d.is_empty():
		var id0 := _alloc_id()
		_new_page_rec(id0, 1, 1, 0)
		return id0
	var id := _alloc_id()
	var kind: String = d["kind"]
	var rec := _new_page_rec(id, int(d["w"]), int(d["h"]), 1 if kind == "8_00" else 0)
	_set_page_image(rec, _img_from_rgb(d))
	if with_alfa:
		var alfa_bytes := vfs.read_file(_alfa_name(raw_name))
		if not alfa_bytes.is_empty():
			var mask := MajiroRct.decode(alfa_bytes)
			if mask != null and mask.width == int(d["w"]) and mask.height == int(d["h"]):
				var alfa_id := _alloc_id()
				var arec := _new_page_rec(alfa_id, mask.width, mask.height, 1)
				_set_page_image(arec, _img_from_rgb({"w": mask.width, "h": mask.height, "rgb": mask.rgb}))
				_attach_alfa(rec, alfa_id)
	return id


# ---------------------------------------------------------------- grp ops

## Clip a blit: returns [sx, sy, dx, dy, w, h] or [] when empty.
static func _clip_blit(sx: int, sy: int, w: int, h: int,
		sw: int, sh: int, dx: int, dy: int, dw: int, dh: int) -> Array:
	if dx < 0:
		sx -= dx
		w += dx
		dx = 0
	if dy < 0:
		sy -= dy
		h += dy
		dy = 0
	if sx < 0:
		dx -= sx
		w += sx
		sx = 0
	if sy < 0:
		dy -= sy
		h += sy
		sy = 0
	w = mini(w, mini(sw - sx, dw - dx))
	h = mini(h, mini(sh - sy, dh - dy))
	if w <= 0 or h <= 0:
		return []
	return [sx, sy, dx, dy, w, h]


## The native frontbuffer is the fully composited screen,
## sprites included (a software renderer); our FRONT page only
## holds direct blits, so a script copy FROM the frontbuffer
## (config / loadsave / help snapshot it as their backdrop)
## must capture the SubViewport first. The capture is the last
## completed frame -- visually identical to what is on screen.
func _refresh_front() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	var vtex := vp.get_texture()
	if vtex == null:
		return
	var img := vtex.get_image()
	if img == null or img.is_empty():
		return
	if img.get_width() != CLIENT_W or img.get_height() != CLIENT_H:
		img.resize(CLIENT_W, CLIENT_H)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var rec: Dictionary = _pages[FRONT]
	rec.erase("px")
	rec["px_dirty"] = false
	rec["img"] = img
	rec["dirty"] = true


func _blit_pair(src: Dictionary, dst: Dictionary, sx: int, sy: int,
		w: int, h: int, dx: int, dy: int) -> void:
	if int(src["id"]) == FRONT:
		_refresh_front()
	var c := _clip_blit(sx, sy, w, h,
			(src["img"] as Image).get_width(), (src["img"] as Image).get_height(),
			dx, dy, (dst["img"] as Image).get_width(), (dst["img"] as Image).get_height())
	if c.is_empty():
		return
	_px_flush(src)
	_px_invalidate(dst)
	(dst["img"] as Image).blit_rect(src["img"], Rect2i(c[0], c[1], c[4], c[5]), Vector2i(c[2], c[3]))
	dst["dirty"] = true
	var sa := int(src["alfa"])
	var da := int(dst["alfa"])
	if sa != 0 and da != 0 and _pages.has(sa) and _pages.has(da):
		_px_flush(_pages[sa])
		_px_invalidate(_pages[da])
		var simg: Image = _pages[sa]["img"]
		var dimg: Image = _pages[da]["img"]
		dimg.blit_rect(simg, Rect2i(c[0], c[1], c[4], c[5]), Vector2i(c[2], c[3]))
		_pages[da]["dirty"] = true


func _extcopy_pair(src: Dictionary, dst: Dictionary, sx: int, sy: int,
		w: int, h: int, dx: int, dy: int, fade: int) -> void:
	if fade >= 255:
		return
	if int(src["id"]) == FRONT:
		_refresh_front()
	var simg: Image = src["img"]
	var dimg: Image = dst["img"]
	var c := _clip_blit(sx, sy, w, h, simg.get_width(), simg.get_height(),
			dx, dy, dimg.get_width(), dimg.get_height())
	if c.is_empty():
		return
	var sa_rec: Variant = null
	if int(src["alfa"]) != 0 and _pages.has(int(src["alfa"])):
		sa_rec = _pages[int(src["alfa"])]
	var da_rec: Variant = null
	if int(dst["alfa"]) != 0 and _pages.has(int(dst["alfa"])):
		da_rec = _pages[int(dst["alfa"])]
	var sdata := _px(src)
	var ddata := _px(dst)
	var sw4 := simg.get_width() * 4
	var dw4 := dimg.get_width() * 4
	var sadata := PackedByteArray()
	if sa_rec != null:
		sadata = _px(sa_rec)
	var dadata := PackedByteArray()
	if da_rec != null:
		dadata = _px(da_rec)
	for row in range(c[5]):
		var soff: int = (int(c[1]) + row) * sw4 + int(c[0]) * 4
		var doff: int = (int(c[3]) + row) * dw4 + int(c[2]) * 4
		for col in range(c[4]):
			var sa := 0
			if sa_rec != null:
				sa = sadata[soff + col * 4]
			var weight := sa + fade + 1
			if weight >= 255:
				continue
			var inv := 256 - weight
			var so: int = soff + col * 4
			var do: int = doff + col * 4
			ddata[do] = (sdata[so] * inv + ddata[do] * weight) >> 8
			ddata[do + 1] = (sdata[so + 1] * inv + ddata[do + 1] * weight) >> 8
			ddata[do + 2] = (sdata[so + 2] * inv + ddata[do + 2] * weight) >> 8
			if da_rec != null:
				var cur := dadata[do]
				dadata[do] = ((sa + 1) * cur) >> 8
				dadata[do + 1] = dadata[do]
				dadata[do + 2] = dadata[do]
	dst["px"] = ddata
	dst["px_dirty"] = true
	dst["dirty"] = true
	if da_rec != null:
		da_rec["px"] = dadata
		da_rec["px_dirty"] = true
		da_rec["dirty"] = true


static func _unpack_color(v: int) -> Color:
	return Color8(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, 255)


func _fill_rect(rec: Dictionary, x: int, y: int, w: int, h: int, col: Color) -> void:
	_px_invalidate(rec)
	var img: Image = rec["img"]
	var r := Rect2i(x, y, w, h).intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	if r.size.x <= 0 or r.size.y <= 0:
		return
	img.fill_rect(r, col)
	rec["dirty"] = true
	var alfa_id := int(rec["alfa"])
	if alfa_id != 0 and _pages.has(alfa_id):
		var aimg: Image = _pages[alfa_id]["img"]
		aimg.fill_rect(r, Color(0, 0, 0, 1))
		_pages[alfa_id]["dirty"] = true


# -------------------------------------------------------------- sprites

func _sprite_create(page_id: int, sx: int, sy: int, xl: int, yl: int,
		page6: int, ext: bool) -> int:
	var prec: Variant = _page(page_id)
	if prec == null:
		return 0
	var pimg: Image = prec["img"]
	if xl <= 0:
		xl = pimg.get_width() - sx
	if yl <= 0:
		yl = pimg.get_height() - sy
	var node := Sprite2D.new()
	# Engine sprite x/y is the region's top-left corner: the title
	# logo and menu pages are full-screen art placed at (0, 0) and
	# their in-page layout matches the original screen pixel-for-pixel.
	# Plain sprites anchor at the region's top-left corner; ext
	# sprites anchor at their center (the engine's sprite_paste
	# applies the same -size/2 adjustment for them, FUN_0044C5E0).
	node.centered = ext
	node.texture = prec["tex"]
	node.region_enabled = true
	node.region_rect = Rect2(sx, sy, xl, yl)
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	node.material = prec["mat"]
	node.z_index = _order.size()
	_sprite_root.add_child(node)
	var id := _alloc_id()
	_sprites[id] = {
		"id": id, "page": page_id, "page6": page6,
		"sx": sx, "sy": sy, "xl": xl, "yl": yl,
		"x": 0, "y": 0, "alfa": 0, "group": id,
		"xmod": 1.0, "ymod": 1.0, "rot": 0.0, "ext": ext,
		"auto_rel": false, "node": node,
		"move": {}, "alfa_anim": {}, "frame_anim": {}, "mod_anim": {},
		"mod_anim_x": {}, "mod_anim_y": {},
	}
	_order.append(id)
	return id


func _sprite(id: int) -> Variant:
	return _sprites.get(id, null)


func _apply_sprite(spr: Dictionary) -> void:
	var node: Sprite2D = spr["node"]
	node.position = Vector2(float(spr["x"]), float(spr["y"]))
	node.scale = Vector2(float(spr["xmod"]), float(spr["ymod"]))
	node.rotation_degrees = float(spr["rot"])
	node.modulate = Color(1, 1, 1, float(255 - int(spr["alfa"])) / 255.0)
	node.region_rect = Rect2(float(spr["sx"]), float(spr["sy"]), float(spr["xl"]), float(spr["yl"]))


func _reindex() -> void:
	for i in range(_order.size()):
		(_sprites[_order[i]]["node"] as Sprite2D).z_index = i


func _sprite_release(id: int) -> void:
	var spr: Variant = _sprite(id)
	if spr == null:
		return
	(spr["node"] as Sprite2D).queue_free()
	_sprites.erase(id)
	_order.erase(id)
	_reindex()
	if bool(spr["auto_rel"]):
		_release_page(int(spr["page"]))


func _priority_insert(spr_id: int, ref_id: int, high: bool, single: bool) -> void:
	if spr_id == ref_id or not _sprites.has(spr_id) or not _sprites.has(ref_id):
		return
	_order.erase(spr_id)
	var idx := _order.find(ref_id)
	if idx < 0:
		_order.append(spr_id)
		_reindex()
		return
	var ref_group := int(_sprites[ref_id]["group"])
	if single:
		_order.insert(idx + 1 if high else idx, spr_id)
	else:
		_sprites[spr_id]["group"] = ref_group
		if high:
			var j := idx
			while j + 1 < _order.size() and int(_sprites[_order[j + 1]]["group"]) == ref_group:
				j += 1
			_order.insert(j + 1, spr_id)
		else:
			var j := idx
			while j - 1 >= 0 and int(_sprites[_order[j - 1]]["group"]) == ref_group:
				j -= 1
			_order.insert(j, spr_id)
	_reindex()


func _tick_anims(delta: float) -> void:
	var now := time_ms
	for id in _order:
		var spr: Dictionary = _sprites[id]
		var changed := false
		var mv: Dictionary = spr["move"]
		if not mv.is_empty():
			var t := 1.0
			if int(mv["dur"]) > 0:
				t = clampf(float(now - int(mv["start"])) / float(mv["dur"]), 0.0, 1.0)
			spr["x"] = int(round(lerpf(float(mv["fx"]), float(mv["tx"]), t)))
			spr["y"] = int(round(lerpf(float(mv["fy"]), float(mv["ty"]), t)))
			if t >= 1.0:
				spr["move"] = {}
			changed = true
		var aa: Dictionary = spr["alfa_anim"]
		if not aa.is_empty():
			if aa.has("keys"):
				changed = _tick_keys(aa, now, func(v: float) -> void: spr["alfa"] = int(v)) or changed
				if aa.is_empty():
					spr["alfa_anim"] = {}
			else:
				var t2 := 1.0
				if int(aa["dur"]) > 0:
					t2 = clampf(float(now - int(aa["start"])) / float(aa["dur"]), 0.0, 1.0)
				spr["alfa"] = int(round(lerpf(float(aa["from"]), float(aa["to"]), t2)))
				if t2 >= 1.0:
					spr["alfa_anim"] = {}
				changed = true
		var fa: Dictionary = spr["frame_anim"]
		if not fa.is_empty():
			var frames: Array = fa["frames"]
			if not frames.is_empty():
				var total := 0
				for p in frames:
					total += int(p[1])
				if total > 0:
					var tt := (now - int(fa["start"])) % total
					var acc := 0
					for p in frames:
						acc += int(p[1])
						if tt < acc:
							var nsx := int(fa["base_sx"]) + int(p[0]) * int(spr["xl"])
							if int(spr["sx"]) != nsx:
								spr["sx"] = nsx
								changed = true
							break
		for axis in ["x", "y"]:
			var ma: Dictionary = spr["mod_anim_" + axis]
			if not ma.is_empty():
				var tm := 1.0
				if int(ma["dur"]) > 0:
					tm = clampf(float(now - int(ma["start"])) / float(ma["dur"]), 0.0, 1.0)
				spr[axis + "mod"] = lerpf(float(ma["from"]), float(ma["to"]), tm)
				if tm >= 1.0:
					spr["mod_anim_" + axis] = {}
				changed = true
		if changed:
			_apply_sprite(spr)


## Advance a keyframe list stored in `anim` ({keys: [[value, ms], ...],
## start, idx, seg_start}); returns true when a value was applied.
## On completion the dict is cleared by the caller via anim.is_empty()
## after this returns the finished flag in anim["done"].
func _tick_keys(anim: Dictionary, now: int, apply: Callable) -> bool:
	var keys: Array = anim["keys"]
	var idx := int(anim.get("idx", 0))
	if idx >= keys.size():
		anim.clear()
		return false
	var seg_start := int(anim.get("seg_start", int(anim["start"])))
	var from_v := float(anim.get("from", keys[idx][0]))
	var to_v := float(keys[idx][0])
	var dur := int(keys[idx][1])
	var t := 1.0
	if dur > 0:
		t = clampf(float(now - seg_start) / float(dur), 0.0, 1.0)
	apply.call(lerpf(from_v, to_v, t))
	if t >= 1.0:
		idx += 1
		if idx >= keys.size():
			anim.clear()
			return true
		anim["idx"] = idx
		anim["seg_start"] = now
		anim["from"] = to_v
	return true


# ---------------------------------------------------------------- input

func inject_click(button: int, pos: Vector2) -> void:
	mouse_pos = pos
	var bit := 0
	var slot := 0
	match button:
		MOUSE_BUTTON_LEFT:
			bit = 1
			slot = 0
		MOUSE_BUTTON_RIGHT:
			bit = 2
			slot = 1
		MOUSE_BUTTON_MIDDLE:
			bit = 4
			slot = 2
	if bit == 0:
		return
	click_bits |= bit
	area_click_bits |= bit
	area_click_pos = pos
	for t in vm._threads:
		var latch: Array = t.get("bsel_latch", [false, false, false])
		latch[slot] = true
		t["bsel_latch"] = latch


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_pos = (event as InputEventMouseMotion).position
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		mouse_pos = mb.position
		if mb.pressed:
			inject_click(mb.button_index, mb.position)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and (k.keycode == KEY_ENTER or k.keycode == KEY_SPACE):
			inject_click(MOUSE_BUTTON_LEFT, mouse_pos)


# ------------------------------------------------------------- syscalls

func _record(hash: int) -> Callable:
	return func(_a: Array) -> Dictionary:
		unhandled[hash] = int(unhandled.get(hash, 0)) + 1
		return MajiroVm.vint(0)


func attach() -> void:
	vm.event_sink = Callable(self, "fire_event")
	var s := vm.syscalls
	# pages
	s[0x83D81F59] = _sc_page_create          # page_create
	s[0xF94B3586] = _sc_page_create_withalfa # page_create_withalfa
	s[0xDAD96289] = func(a: Array) -> Dictionary: return MajiroVm.vint(_page_from_file(_ab(a[0]), false))  # page_create_file
	s[0x57EFA275] = func(a: Array) -> Dictionary: return MajiroVm.vint(_page_from_file(_ab(a[0]), true))   # page_create_file_withalfa
	s[0xC50DFD06] = func(a: Array) -> Dictionary: _release_page(_ai(a[0])); return MajiroVm.vint(0)  # page_release
	s[0x8D84B83F] = func(a: Array) -> Dictionary: return MajiroVm.vint(1 if _page(_ai(a[0])) != null else 0)  # page_is_exist
	s[0xF8FD08F6] = func(a: Array) -> Dictionary: var p: Variant = _page(_ai(a[0])); return MajiroVm.vint(0 if p == null else (p["img"] as Image).get_width())   # page_len_x
	s[0x65F2E980] = func(a: Array) -> Dictionary: var p: Variant = _page(_ai(a[0])); return MajiroVm.vint(0 if p == null else (p["img"] as Image).get_height())  # page_len_y
	s[0x5E4E3063] = _sc_page_drawmode        # page_drawmode
	s[0x70612DB5] = _sc_get_alfapage         # get_alfapage
	s[0x3E11F2C5] = func(_a: Array) -> Dictionary: return MajiroVm.vint(FRONT)  # get_frontbuffer
	s[0xF9705332] = _sc_page_set_antidata    # page_set_antidata
	# grp
	s[0x56BBBA3A] = _sc_grp_copy             # grp_copy
	s[0x30636D6E] = _sc_grp_extcopy          # grp_extcopy
	s[0xD01BE374] = _sc_grp_boxfill          # grp_boxfill
	s[0xFDDF6C40] = _sc_grp_extboxfill       # grp_extboxfill
	s[0x61BAE53C] = _sc_grp_mulboxfill       # grp_mulboxfill
	s[0x3CAD3884] = _sc_make_alfa_table      # make_alfa_table       # grp_mulboxfill
	s[0x4C310B4B] = _sc_grp_point_get        # grp_point_get
	s[0x7E277952] = _sc_grp_point_set        # grp_point_set
	for h in [0x171AEE22, 0x053FAC99, 0xFD128A61, 0xDA675785, 0xAC796720,
			0x89B59D02, 0x4FA8483F, 0x87113971, 0xE5E4E2FF]:
		s[h] = _record(h)  # grp_home/reverse/sepia/modcopy/modify_copy/overlayboxfill/zoom/swap/alfa_tabled_copy
	# pic
	s[0x5EB974F7] = _sc_pic_unpack           # pic_unpack
	s[0x539B07BC] = func(a: Array) -> Dictionary: var d := _decode_file(_ab(a[0])); return MajiroVm.vint(0 if d.is_empty() else int(d["w"]))  # pic_len_x
	s[0xCE94E6CA] = func(a: Array) -> Dictionary: var d := _decode_file(_ab(a[0])); return MajiroVm.vint(0 if d.is_empty() else int(d["h"]))  # pic_len_y
	# sprites
	s[0xEF4581DC] = func(a: Array) -> Dictionary: return MajiroVm.vint(_sc_sprite_create(a, false))  # sprite_create
	s[0xF6A05538] = func(a: Array) -> Dictionary: return MajiroVm.vint(_sc_sprite_create(a, true))   # sprite_create_ext
	s[0xC2C3C4F4] = func(a: Array) -> Dictionary: return MajiroVm.vint(_sc_sprite_create_file(a, false))  # sprite_create_file
	s[0xCD71FE7A] = func(a: Array) -> Dictionary: return MajiroVm.vint(_sc_sprite_create_file(a, true))   # sprite_create_file_ext
	s[0x58B31737] = func(a: Array) -> Dictionary: _sprite_release(_ai(a[0])); return MajiroVm.vint(0)  # sprite_release
	s[0xDCC706EF] = func(a: Array) -> Dictionary: return MajiroVm.vint(1 if _sprite(_ai(a[0])) != null else 0)  # sprite_is_exist
	s[0x265E07D7] = func(a: Array) -> Dictionary: var sp: Variant = _sprite(_ai(a[0])); return MajiroVm.vint(0 if sp == null else int(sp["page"]))  # sprite_get_page
	s[0x63F660A2] = func(a: Array) -> Dictionary: var sp: Variant = _sprite(_ai(a[0])); return MajiroVm.vint(0 if sp == null else int(sp["xl"]))  # sprite_len_x
	s[0xFEF981D4] = func(a: Array) -> Dictionary: var sp: Variant = _sprite(_ai(a[0])); return MajiroVm.vint(0 if sp == null else int(sp["yl"]))  # sprite_len_y
	s[0x6B4A7873] = func(a: Array) -> Dictionary: var sp: Variant = _sprite(_ai(a[0])); return MajiroVm.vint(0 if sp == null else int(sp["x"]))  # sprite_get_pos_x
	s[0xF6459905] = func(a: Array) -> Dictionary: var sp: Variant = _sprite(_ai(a[0])); return MajiroVm.vint(0 if sp == null else int(sp["y"]))  # sprite_get_pos_y
	s[0xE119D5BA] = _sc_sprite_move          # sprite_move
	s[0x40258A56] = _sc_sprite_move_wait     # sprite_move_wait
	s[0x68EF2987] = func(a: Array) -> Dictionary: var sp: Variant = _sprite(_ai(a[0])); return MajiroVm.vint(0 if sp == null or (sp["move"] as Dictionary).is_empty() else 1)  # sprite_is_move
	s[0xFF7C52E6] = _sc_sprite_alfa_set      # sprite_alfa_set
	s[0xF80BC9B6] = _sc_sprite_alfa_define   # sprite_alfa_define
	s[0xA30A7D75] = _sc_sprite_alfa_define   # sprite_alfa_define_abs
	s[0xD7771B72] = _sc_sprite_alfa_wait     # sprite_alfa_wait
	s[0xC29B30E3] = _sc_sprite_animate_define  # sprite_animate_define
	s[0x52819912] = _sc_sprite_animate_define  # sprite_animate_define_abs
	s[0xDFDBA8E4] = _sc_sprite_animate_add   # sprite_animate_add
	s[0x103EDAC0] = _sc_sprite_animate_wait  # sprite_animate_wait
	s[0x3B1D5537] = _sc_sprite_xmodify_set   # sprite_xmodify_set
	s[0xBA383010] = _sc_sprite_ymodify_set   # sprite_ymodify_set
	s[0xE76F8A65] = func(a: Array) -> Dictionary: var sp: Variant = _sprite(_ai(a[0])); return MajiroVm.vfloat(0.0 if sp == null else float(sp["xmod"]) * 100.0)  # sprite_xmodify_get%
	s[0x42E41A6B] = func(a: Array) -> Dictionary: var sp: Variant = _sprite(_ai(a[0])); return MajiroVm.vfloat(0.0 if sp == null else float(sp["ymod"]) * 100.0)  # sprite_ymodify_get%
	s[0x01B4517C] = _record(0x01B4517C)      # sprite_xmodify_define (phase 5)
	s[0x6F384A3D] = _record(0x6F384A3D)      # sprite_ymodify_define (phase 5)
	s[0x661AFB43] = _sc_sprite_rotate        # sprite_rotate
	s[0x4A02D664] = func(a: Array) -> Dictionary: _sc_priority(a, true, false); return MajiroVm.vint(0)   # sprite_priority_high
	s[0x69073588] = func(a: Array) -> Dictionary: _sc_priority(a, false, false); return MajiroVm.vint(0)  # sprite_priority_low
	s[0x5548EF5E] = func(a: Array) -> Dictionary: _sc_priority(a, true, true); return MajiroVm.vint(0)    # sprite_priority_high_single
	s[0x7BFFC5B1] = func(a: Array) -> Dictionary: _sc_priority(a, false, true); return MajiroVm.vint(0)   # sprite_priority_low_single
	s[0x721FA5B7] = _sc_sprite_push          # sprite_push
	s[0x63C341B1] = _sc_sprite_pop           # sprite_pop
	s[0x8838FD56] = _sc_page_auto_release    # sprite_page_auto_release
	s[0x4AB0CAEF] = _sc_sprite_paste         # sprite_paste
	s[0x7B0E970D] = _record(0x7B0E970D)      # sprite_clip
	s[0x3F34D519] = _record(0x3F34D519)      # sprite_set_smooth_animation
	s[0xEDCA8992] = _record(0xEDCA8992)      # sprite_tl_set
	# input / timing
	s[0x008ACBC0] = _sc_mk_wait              # mk_wait
	s[0xF8D18340] = _sc_areaevent_set        # areaevent_set (9 args)
	s[0xA7C6E918] = _sc_areaevent_set        # areaevent_set (variant)
	s[0x3A3BFB29] = _sc_areaevent_check      # areaevent_check
	s[0x1204D7E8] = func(_a: Array) -> Dictionary: click_bits = 0; return MajiroVm.vint(0)  # mk_unwait
	s[0x892E9B20] = func(_a: Array) -> Dictionary: return MajiroVm.vint(_mouse_bits())  # mk_read
	s[0x2075C300] = func(_a: Array) -> Dictionary: return MajiroVm.vint(_mouse_bits())  # mk_stat
	s[0xEFD49BC9] = func(_a: Array) -> Dictionary: return MajiroVm.vint(int(mouse_pos.x))  # curpos_x
	s[0x72DB7ABF] = func(_a: Array) -> Dictionary: return MajiroVm.vint(int(mouse_pos.y))  # curpos_y
	s[0xCF35F0E3] = _sc_wait                 # wait
	s[0xFF75CD29] = _sc_timer_sync           # timer_sync
	s[0x4662E95D] = _sc_draw_wait            # draw_wait
	s[0x76EE6C90] = _sc_do_event              # do_event
	s[0x078A756E] = _sc_event_hook            # event_hook
	s[0x1295BBDA] = _sc_event_hook_after      # event_hook_after
	s[0xA93C9856] = _sc_event_release         # event_release
	s[0xDFD5599E] = func(_a: Array) -> Dictionary: return MajiroVm.vint(0)  # invalidate_rect (we flush dirty pages every frame)
	s[0x29F1AC40] = _sc_do_event_single      # do_event_single
	s[0x111BD910] = func(_a: Array) -> Dictionary: return MajiroVm.vint(effect_speed)  # get_effectspeed
	s[0x6584F13E] = func(_a: Array) -> Dictionary: return MajiroVm.vint(time_ms)  # timer
	s[0xEE6B328D] = _sc_timer_progress     # timer_progress
	s[0x8CD709F9] = func(_a: Array) -> Dictionary: return MajiroVm.vint(time_ms)  # get_current_time$
	s[0x619DE833] = func(_a: Array) -> Dictionary: return MajiroVm.vint(time_ms)  # global timer read (FUN_0042BE30)
	s[0x4B5AC64B] = func(_a: Array) -> Dictionary: return MajiroVm.vint(time_ms)  # global timer read (FUN_0042BE10)
	s[0xEE2B6D92] = func(a: Array) -> Dictionary: return MajiroVm.vfloat(sin(deg_to_rad(_af(a[0]))))  # sin (degrees, FUN_00402640)
	s[0x12877048] = func(a: Array) -> Dictionary: return MajiroVm.vfloat(cos(deg_to_rad(_af(a[0]))))  # cos (degrees, FUN_00402660)
	s[0xEB5CC468] = func(a: Array) -> Dictionary: return a[0] if not a.is_empty() else MajiroVm.vint(0)  # string copy (FUN_00429E00)
	s[0x0C93FCB4] = func(a: Array) -> Dictionary: effect_speed = _ai(a[0]) if not a.is_empty() else 1000; return MajiroVm.vint(0)  # set_effectspeed
	s[0x6DE6CDFC] = func(_a: Array) -> Dictionary: invalidate_enabled = true; return MajiroVm.vint(0)   # invalidate_enable
	s[0xCF2B1E50] = func(_a: Array) -> Dictionary: invalidate_enabled = false; return MajiroVm.vint(0)  # invalidate_disable

	s[0x44BC7555] = func(_a: Array) -> Dictionary: return MajiroVm.vint(0)  # mouse_enable
	s[0x60085FA4] = func(_a: Array) -> Dictionary: return MajiroVm.vint(0)  # mouse_disable


func _sc_page_auto_release(a: Array) -> Dictionary:
	var sp: Variant = _sprite(_ai(a[0]))
	if sp != null:
		sp["auto_rel"] = true
	return MajiroVm.vint(0)


func _mouse_bits() -> int:
	var b := 0
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		b |= 1
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		b |= 2
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		b |= 4
	return b


func _sc_page_set_antidata(a: Array) -> Dictionary:
	# page_set_antidata(color_page, alfa_page): link an 8bpp page
	# as the color page's alfa (mask) companion. The console
	# record pairs every window page this way at boot; as a stub
	# the link was missing and the window plates rendered as
	# opaque black sheets (found 2026-11-05).
	if a.size() >= 2:
		var rec: Variant = _page(_ai(a[0]))
		if rec != null and _pages.has(_ai(a[1])):
			_attach_alfa(rec, _ai(a[1]))
	return MajiroVm.vint(0)


func _sc_page_create(a: Array) -> Dictionary:
	# Engine arg order (arg0 = last pushed): page_create(w, h[, flag]).
	# Scripts push client_height() then client_width(); the exe's
	# handler reads the stack top-down, so arg0 is the width.
	var w := maxi(1, _ai(a[0]))
	var h := maxi(1, _ai(a[1])) if a.size() >= 2 else w
	var flag := 1
	if a.size() >= 3:
		flag = _ai(a[2])
	var id := _alloc_id()
	_new_page_rec(id, w, h, 0 if flag != 0 else 1)
	return MajiroVm.vint(id)


func _sc_page_create_withalfa(a: Array) -> Dictionary:
	var r := _sc_page_create(a)
	var rec: Dictionary = _pages[int(r["v"])]
	var alfa_id := _alloc_id()
	var img: Image = rec["img"]
	_new_page_rec(alfa_id, img.get_width(), img.get_height(), 1)
	_attach_alfa(rec, alfa_id)
	return r


func _sc_page_drawmode(a: Array) -> Dictionary:
	var rec: Variant = _page(_ai(a[0]))
	if rec == null or int(rec["format"]) != 0:
		return MajiroVm.vint(0)
	rec["drawmode"] = _ai(a[1]) if a.size() >= 2 else 0
	return MajiroVm.vint(0)


func _sc_get_alfapage(a: Array) -> Dictionary:
	var x := _ai(a[0])
	if _pages.has(x):
		return MajiroVm.vint(int(_pages[x]["alfa"]))
	var spr: Variant = _sprite(x)
	if spr != null and _pages.has(int(spr["page"])):
		return MajiroVm.vint(int(_pages[int(spr["page"])]["alfa"]))
	return MajiroVm.vint(0)


func _sc_grp_copy(a: Array) -> Dictionary:
	var src: Variant = _page(_ai(a[0]))
	var dst: Variant = _page(_ai(a[5]))
	if src == null or dst == null:
		return MajiroVm.vint(0)
	# Short form (6 args): the destination offset defaults to
	# the source offset -- the omake screen's wipe loop in
	# start.mjil sweeps grp_copy strips with only
	# (src, sx, sy, w, h, dst) and relies on each strip
	# landing at its own sx (same for grp_extcopy below).
	if int(src["format"]) == 0 and int(dst["format"]) == 1:
		return MajiroVm.vint(0)  # 24bpp -> 8bpp is an engine error: skip
	var dx := _ai(a[6]) if a.size() >= 7 else _ai(a[1])
	var dy := _ai(a[7]) if a.size() >= 8 else _ai(a[2])
	_blit_pair(src, dst, _ai(a[1]), _ai(a[2]), _ai(a[3]), _ai(a[4]), dx, dy)
	return MajiroVm.vint(0)


func _sc_timer_progress(a: Array) -> Dictionary:
	# Source order (start_tick, duration_ms, max) -> max *
	# elapsed/duration, clamped. $$cb_console_wrote@CONSOLE
	# drives its typewriter reveal width from this (its pushes
	# are xl, timemax, timer -- last pushed is arg0); the
	# zero-duration case is instant.
	var mx := _ai(a[2])
	var dur := _ai(a[1])
	if dur <= 0:
		return MajiroVm.vint(mx)
	return MajiroVm.vint(clampi(mx * (time_ms - _ai(a[0])) / dur, 0, mx))


func _sc_grp_extcopy(a: Array) -> Dictionary:
	var src: Variant = _page(_ai(a[0]))
	var dst: Variant = _page(_ai(a[5]))
	if src == null or dst == null:
		return MajiroVm.vint(0)
	var dx := _ai(a[6]) if a.size() >= 7 else _ai(a[1])
	var dy := _ai(a[7]) if a.size() >= 8 else _ai(a[2])
	var fade := _ai(a[8]) if a.size() >= 9 else 0
	_extcopy_pair(src, dst, _ai(a[1]), _ai(a[2]), _ai(a[3]), _ai(a[4]), dx, dy, fade)
	return MajiroVm.vint(0)


func _sc_grp_boxfill(a: Array) -> Dictionary:
	var rec: Variant = _page(_ai(a[0]))
	if rec == null:
		return MajiroVm.vint(0)
	_fill_rect(rec, _ai(a[1]), _ai(a[2]), _ai(a[3]), _ai(a[4]), _unpack_color(_ai(a[5])))
	return MajiroVm.vint(0)



func _sc_grp_mulboxfill(a: Array) -> Dictionary:
	var rec: Variant = _page(_ai(a[0]))
	if rec == null or a.size() < 6:
		return MajiroVm.vint(0)
	if int(rec["format"]) != 0:
		return MajiroVm.vint(0)  # native touches 24bpp color pages only
	var img: Image = rec["img"]
	var r := Rect2i(_ai(a[1]), _ai(a[2]), _ai(a[3]), _ai(a[4])).intersection(
			Rect2i(0, 0, img.get_width(), img.get_height()))
	if r.size.x <= 0 or r.size.y <= 0:
		return MajiroVm.vint(0)
	# Multiply blend (exe FUN_00421940): each channel c becomes
	# c * (m + 1) >> 8, m from the color in COLORREF order
	# (R in the low byte); the page alpha is untouched.
	var col := _ai(a[5])
	var mr := (col & 0xFF) + 1
	var mg := ((col >> 8) & 0xFF) + 1
	var mb := ((col >> 16) & 0xFF) + 1
	var data := _px(rec)
	var w4 := img.get_width() * 4
	for yy in range(r.position.y, r.position.y + r.size.y):
		var o := yy * w4 + r.position.x * 4
		for xx in range(r.size.x):
			data[o] = (data[o] * mr) >> 8
			data[o + 1] = (data[o + 1] * mg) >> 8
			data[o + 2] = (data[o + 2] * mb) >> 8
			o += 4
	rec["px"] = data
	rec["px_dirty"] = true
	rec["dirty"] = true
	return MajiroVm.vint(0)


func _sc_make_alfa_table(a: Array) -> Dictionary:
	# make_alfa_table(alfa_src, alfa_dst, intarray[256]) (exe
	# FUN_00423520 + FUN_00459f60): build a 256-entry lookup from
	# the array (each value clamped to 0..255) and remap the dst
	# page's index bytes through it, indexed by the src page's
	# index bytes: dst[i] = table[src[i]], over the intersection
	# of the two pages. Both pages must be 8bpp (format != 0);
	# every validation failure is a silent no-op in the engine.
	# Index bytes live in the R channel of the stored RGBA image.
	if a.size() < 3:
		return MajiroVm.vint(0)
	var ra: Variant = _page(_ai(a[0]))
	var rb: Variant = _page(_ai(a[1]))
	if ra == null or rb == null:
		return MajiroVm.vint(0)
	if int(ra["format"]) == 0 or int(rb["format"]) == 0:
		return MajiroVm.vint(0)
	if int(a[2].get("k", -1)) != MajiroVm.K_IARR:
		return MajiroVm.vint(0)
	var flat: Array = []
	_flat_ints(a[2]["v"], flat)
	if flat.size() < 256:
		return MajiroVm.vint(0)
	var table := PackedByteArray()
	table.resize(256)
	for i in range(256):
		table[i] = clampi(int(flat[i]), 0, 255)
	var adata := _px(ra)
	var bdata := _px(rb)
	var wa: int = ra["img"].get_width()
	var wb: int = rb["img"].get_width()
	var w := mini(wa, wb)
	var h := mini(ra["img"].get_height(), rb["img"].get_height())
	for yy in range(h):
		var oa := yy * wa * 4
		var ob := yy * wb * 4
		for xx in range(w):
			bdata[ob] = table[adata[oa]]
			oa += 4
			ob += 4
	rb["px"] = bdata
	rb["px_dirty"] = true
	rb["dirty"] = true
	return MajiroVm.vint(0)


func _flat_ints(v: Variant, out: Array) -> void:
	if v is Array:
		for e in v:
			_flat_ints(e, out)
	elif v is Dictionary:
		out.append(_ai(v))


func _sc_grp_extboxfill(a: Array) -> Dictionary:
	var rec: Variant = _page(_ai(a[0]))
	if rec == null or a.size() < 7:
		return MajiroVm.vint(0)
	var trans := _ai(a[6])
	if trans >= 256:
		return MajiroVm.vint(0)
	var col := _unpack_color(_ai(a[5]))
	var img: Image = rec["img"]
	var r := Rect2i(_ai(a[1]), _ai(a[2]), _ai(a[3]), _ai(a[4])).intersection(
			Rect2i(0, 0, img.get_width(), img.get_height()))
	if r.size.x <= 0 or r.size.y <= 0:
		return MajiroVm.vint(0)
	var data := _px(rec)
	var w4 := img.get_width() * 4
	var weight := trans
	var inv := 256 - weight
	var cr := int(col.r8)
	var cg := int(col.g8)
	var cb := int(col.b8)
	for row in range(r.position.y, r.position.y + r.size.y):
		var off := row * w4 + r.position.x * 4
		for i in range(r.size.x):
			var o := off + i * 4
			data[o] = (cr * inv + data[o] * weight) >> 8
			data[o + 1] = (cg * inv + data[o + 1] * weight) >> 8
			data[o + 2] = (cb * inv + data[o + 2] * weight) >> 8
	rec["px"] = data
	rec["px_dirty"] = true
	rec["dirty"] = true
	return MajiroVm.vint(0)


## Draw an RGBA image into a page at pos with alpha blending (used
## by the console's baked text lines). The page's alfa companion, if
## any, absorbs the glyph coverage: mask *= (255 - alpha) / 255.
## Console wipe: restore a page region to its boot state (black
## color page, full 255 mask on the alfa companion). The native
## console clears its text surface when ctrl "w" fires
## CONSOLE_CLS; the script-side cb only re-arms the text area.
func clear_page_rect(page_id: int, r: Rect2i) -> void:
	var rec: Variant = _page(page_id)
	if rec == null:
		return
	_fill_rect(rec, r.position.x, r.position.y, r.size.x, r.size.y, Color(0, 0, 0, 1))
	var alfa_id := int(rec["alfa"])
	if alfa_id != 0 and _pages.has(alfa_id):
		_fill_rect(_pages[alfa_id], r.position.x, r.position.y, r.size.x, r.size.y, Color(1, 1, 1, 1))


func page_draw_image(page_id: int, src_img: Image, pos: Vector2i) -> void:
	var rec: Variant = _page(page_id)
	if rec == null:
		return
	_px_invalidate(rec)
	var img: Image = rec["img"]
	img.blend_rect(src_img, Rect2i(0, 0, src_img.get_width(), src_img.get_height()), pos)
	rec["dirty"] = true
	var alfa_id := int(rec["alfa"])
	if alfa_id != 0 and _pages.has(alfa_id):
		var arec: Dictionary = _pages[alfa_id]
		var adata := _px(arec)
		var sdata := src_img.get_data()
		var aw := (arec["img"] as Image).get_width()
		for yy in range(src_img.get_height()):
			var dy := pos.y + yy
			if dy < 0 or dy >= (arec["img"] as Image).get_height():
				continue
			for xx in range(src_img.get_width()):
				var dx := pos.x + xx
				if dx < 0 or dx >= aw:
					continue
				var sa := sdata[(yy * src_img.get_width() + xx) * 4 + 3]
				if sa == 0:
					continue
				var o := (dy * aw + dx) * 4
				var nv := (adata[o] * (255 - sa)) >> 8
				adata[o] = nv
				adata[o + 1] = nv
				adata[o + 2] = nv
		arec["px"] = adata
		arec["px_dirty"] = true
		arec["dirty"] = true


## Clear a rect of a page to transparent (console_cls): color pixels
## to (0,0,0,0), alfa companion to fully transparent (255).
func page_clear_rect(page_id: int, r: Rect2i) -> void:
	var rec: Variant = _page(page_id)
	if rec == null:
		return
	_px_invalidate(rec)
	var img: Image = rec["img"]
	var clip := r.intersection(Rect2i(0, 0, img.get_width(), img.get_height()))
	if clip.size.x > 0 and clip.size.y > 0:
		img.fill_rect(clip, Color(0, 0, 0, 0))
		rec["dirty"] = true
	var alfa_id := int(rec["alfa"])
	if alfa_id != 0 and _pages.has(alfa_id):
		var arec: Dictionary = _pages[alfa_id]
		_px_invalidate(arec)
		var aimg: Image = arec["img"]
		var aclip := r.intersection(Rect2i(0, 0, aimg.get_width(), aimg.get_height()))
		if aclip.size.x > 0 and aclip.size.y > 0:
			aimg.fill_rect(aclip, Color(1, 1, 1, 1))
			arec["dirty"] = true


func _sc_grp_point_get(a: Array) -> Dictionary:
	var rec: Variant = _page(_ai(a[0]))
	if rec == null:
		return MajiroVm.vint(0)
	_px_flush(rec)
	var img: Image = rec["img"]
	var x := _ai(a[1])
	var y := _ai(a[2])
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return MajiroVm.vint(0)
	var c := img.get_pixel(x, y)
	return MajiroVm.vint(int(c.r8) | (int(c.g8) << 8) | (int(c.b8) << 16))


func _sc_grp_point_set(a: Array) -> Dictionary:
	var rec: Variant = _page(_ai(a[0]))
	if rec == null:
		return MajiroVm.vint(0)
	_px_invalidate(rec)
	var img: Image = rec["img"]
	var x := _ai(a[1])
	var y := _ai(a[2])
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return MajiroVm.vint(0)
	img.set_pixel(x, y, _unpack_color(_ai(a[3])))
	rec["dirty"] = true
	return MajiroVm.vint(0)


func _sc_pic_unpack(a: Array) -> Dictionary:
	# Engine arg order: pic_unpack(page, name$[, x, y]).
	var rec: Variant = _page(_ai(a[0]))
	if rec == null:
		return MajiroVm.vint(0)
	var d := _decode_file(_ab(a[1]))
	if d.is_empty():
		return MajiroVm.vint(0)
	var page_img: Image = rec["img"]
	if int(d["w"]) < page_img.get_width() or int(d["h"]) < page_img.get_height():
		# Sub-page image (a stamp, a seal, a badge): natively the
		# decode lands ON the page at the (x, y) offsets, blended
		# through its _.rc8 alfa companion -- it does not replace
		# the page. (Loadsave stamps its seal onto the finished
		# panel page this way; replacing wiped the whole panel.)
		var src_img := _img_from_rgb(d)
		var alfa_bytes := vfs.read_file(_alfa_name(_ab(a[1])))
		if not alfa_bytes.is_empty():
			var mask := MajiroRct.decode(alfa_bytes)
			if mask != null and mask.width == int(d["w"]) and mask.height == int(d["h"]):
				var sdata := src_img.get_data()
				for i in range(int(d["w"]) * int(d["h"])):
					# alfa polarity: 255 = fully transparent
					sdata[i * 4 + 3] = 255 - mask.rgb[i * 3]
				src_img.set_data(int(d["w"]), int(d["h"]), false, Image.FORMAT_RGBA8, sdata)
		var ox := _ai(a[2]) if a.size() > 2 else 0
		var oy := _ai(a[3]) if a.size() > 3 else 0
		page_draw_image(int(rec["id"]), src_img, Vector2i(ox, oy))
		return MajiroVm.vint(1)
	_set_page_image(rec, _img_from_rgb(d))
	return MajiroVm.vint(1)


## sprite_paste(sprite, page): rasterize the sprite (its region of its
## source page, alfa mask and sprite alfa applied) into the page at the
## sprite's position. FUN_0044C5E0 validates arg0 against the sprite
## list and arg1 against the page list. (An earlier reading of this
## handler as (dst_page, src_page) was wrong; call-site probe 2026-11-05
## showed a[0] is a sprite id and a[1] a page id, and the old handler
## silently no-opped every paste, leaving displayed pages black.)
func _sc_sprite_paste(a: Array) -> Dictionary:
	if a.size() < 2:
		return MajiroVm.vint(0)
	var spr_id := _ai(a[0])
	var dst_id := _ai(a[1])
	if not _sprites.has(spr_id) or not _pages.has(dst_id):
		return MajiroVm.vint(0)
	var spr: Dictionary = _sprites[spr_id]
	var src_id := int(spr["page"])
	if not _pages.has(src_id):
		return MajiroVm.vint(0)
	var prec: Dictionary = _pages[src_id]
	_px_flush(prec)
	var patch := (prec["img"] as Image).get_region(Rect2i(
			int(spr["sx"]), int(spr["sy"]), int(spr["xl"]), int(spr["yl"])))
	var alfa_id := int(prec["alfa"])
	if alfa_id != 0 and _pages.has(alfa_id):
		_px_flush(_pages[alfa_id])
		var mask := (_pages[alfa_id]["img"] as Image).get_region(Rect2i(
				int(spr["sx"]), int(spr["sy"]), int(spr["xl"]), int(spr["yl"])))
		var pd := patch.get_data()
		var md := mask.get_data()
		var salpha := 255 - int(spr["alfa"])
		for i in range(0, pd.size(), 4):
			var cov := (255 - md[i]) * salpha / 255
			pd[i + 3] = int(cov)
		patch.set_data(patch.get_width(), patch.get_height(), false, Image.FORMAT_RGBA8, pd)
	elif int(spr["alfa"]) != 0:
		var pd2 := patch.get_data()
		var salpha2 := 255 - int(spr["alfa"])
		for i in range(0, pd2.size(), 4):
			pd2[i + 3] = int(pd2[i + 3]) * salpha2 / 255
		patch.set_data(patch.get_width(), patch.get_height(), false, Image.FORMAT_RGBA8, pd2)
	var ppos := Vector2i(int(spr["x"]), int(spr["y"]))
	if bool(spr["ext"]):
		ppos -= Vector2i(int(spr["xl"]) / 2, int(spr["yl"]) / 2)
	page_draw_image(dst_id, patch, ppos)
	return MajiroVm.vint(0)


func _sc_sprite_create(a: Array, ext: bool) -> int:
	var page_id := _ai(a[0])
	if a.size() >= 6:
		return _sprite_create(page_id, _ai(a[1]), _ai(a[2]), _ai(a[3]), _ai(a[4]), _ai(a[5]), ext)
	if a.size() >= 5:
		return _sprite_create(page_id, _ai(a[1]), _ai(a[2]), _ai(a[3]), _ai(a[4]), FRONT, ext)
	return _sprite_create(page_id, 0, 0, 0, 0, FRONT, ext)


func _sc_sprite_create_file(a: Array, ext: bool) -> int:
	var page_id := _page_from_file(_ab(a[0]), true)
	if a.size() >= 5:
		return _sprite_create(page_id, _ai(a[1]), _ai(a[2]), _ai(a[3]), _ai(a[4]), FRONT, ext)
	return _sprite_create(page_id, 0, 0, 0, 0, FRONT, ext)


func _sc_sprite_move(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null:
		return MajiroVm.vint(0)
	var tx := _ai(a[1])
	var ty := _ai(a[2])
	var dur := _ai(a[3]) if a.size() >= 4 else 0
	if dur > 0:
		spr["move"] = {"fx": int(spr["x"]), "fy": int(spr["y"]),
				"tx": tx, "ty": ty, "start": time_ms, "dur": dur}
	else:
		spr["x"] = tx
		spr["y"] = ty
		spr["move"] = {}
	_apply_sprite(spr)
	return MajiroVm.vint(0)


func _sc_sprite_move_wait(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null or (spr["move"] as Dictionary).is_empty():
		vm._cur["poll_armed"] = false
		return MajiroVm.vint(0)
	vm._cur["poll_armed"] = true
	_suspend()
	return MajiroVm.vint(0)


func _sc_sprite_alfa_set(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null:
		return MajiroVm.vint(0)
	var target := clampi(_ai(a[1]), 0, 255)
	var dur := _ai(a[2]) if a.size() >= 3 else 0
	if dur > 0:
		spr["alfa_anim"] = {"from": int(spr["alfa"]), "to": target,
				"start": time_ms, "dur": dur}
	else:
		spr["alfa"] = target
		spr["alfa_anim"] = {}
	_apply_sprite(spr)
	return MajiroVm.vint(0)


func _sc_sprite_alfa_define(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null:
		return MajiroVm.vint(0)
	var keys: Array = []
	var i := 1
	while i + 1 < a.size():
		keys.append([clampi(_ai(a[i]), 0, 255), maxi(0, _ai(a[i + 1]))])
		i += 2
	if keys.is_empty():
		return MajiroVm.vint(0)
	spr["alfa_anim"] = {"keys": keys, "start": time_ms, "idx": 0,
			"seg_start": time_ms, "from": float(spr["alfa"])}
	return MajiroVm.vint(0)


func _sc_sprite_alfa_wait(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null or (spr["alfa_anim"] as Dictionary).is_empty():
		vm._cur["poll_armed"] = false
		return MajiroVm.vint(0)
	vm._cur["poll_armed"] = true
	_suspend()
	return MajiroVm.vint(0)


func _sc_sprite_animate_define(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null:
		return MajiroVm.vint(0)
	var frames: Array = []
	var i := 1
	while i + 1 < a.size():
		frames.append([_ai(a[i]), maxi(1, _ai(a[i + 1]))])
		i += 2
	if frames.is_empty():
		return MajiroVm.vint(0)
	spr["frame_anim"] = {"frames": frames, "start": time_ms, "base_sx": int(spr["sx"])}
	return MajiroVm.vint(0)


func _sc_sprite_animate_add(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null or a.size() < 3:
		return MajiroVm.vint(0)
	var fa: Dictionary = spr["frame_anim"]
	if fa.is_empty():
		fa = {"frames": [], "start": time_ms, "base_sx": int(spr["sx"])}
		(fa["frames"] as Array).append([_ai(a[1]), maxi(1, _ai(a[2]))])
		spr["frame_anim"] = fa
	else:
		(fa["frames"] as Array).append([_ai(a[1]), maxi(1, _ai(a[2]))])
	return MajiroVm.vint(0)


func _sc_sprite_animate_wait(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null or (spr["frame_anim"] as Dictionary).is_empty():
		vm._cur["poll_armed"] = false
		return MajiroVm.vint(0)
	vm._cur["poll_armed"] = true
	_suspend()
	return MajiroVm.vint(0)


func _sc_sprite_xmodify_set(a: Array) -> Dictionary:
	# Engine semantics: xmodify_set(sprite, float ratio, [time ms]).
	# The value is a plain ratio (1.0 = natural size); with a time arg
	# the change animates. (A percent reading stored 1.0 as 0.01 and
	# shrank the background sprite to a dot; fixed 2026-11-05.)
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null:
		return MajiroVm.vint(0)
	var dur := _ai(a[2]) if a.size() >= 3 else 0
	if dur > 0:
		spr["mod_anim_x"] = {"from": float(spr["xmod"]), "to": _af(a[1]),
				"start": time_ms, "dur": dur}
	else:
		spr["mod_anim_x"] = {}
		spr["xmod"] = _af(a[1])
		_apply_sprite(spr)
	return MajiroVm.vint(0)


func _sc_sprite_ymodify_set(a: Array) -> Dictionary:
	# See _sc_sprite_xmodify_set for the ratio/time semantics.
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null:
		return MajiroVm.vint(0)
	var dur := _ai(a[2]) if a.size() >= 3 else 0
	if dur > 0:
		spr["mod_anim_y"] = {"from": float(spr["ymod"]), "to": _af(a[1]),
				"start": time_ms, "dur": dur}
	else:
		spr["mod_anim_y"] = {}
		spr["ymod"] = _af(a[1])
		_apply_sprite(spr)
	return MajiroVm.vint(0)


func _sc_sprite_rotate(a: Array) -> Dictionary:
	var spr: Variant = _sprite(_ai(a[0]))
	if spr == null:
		return MajiroVm.vint(0)
	spr["rot"] = _af(a[1])
	_apply_sprite(spr)
	return MajiroVm.vint(0)


func _sc_priority(a: Array, high: bool, single: bool) -> void:
	if a.size() >= 2:
		_priority_insert(_ai(a[0]), _ai(a[1]), high, single)
	elif not a.is_empty():
		var id := _ai(a[0])
		if not _sprites.has(id):
			return
		_order.erase(id)
		if high:
			_order.append(id)
		else:
			_order.push_front(id)
		_reindex()


## sprite_push/pop: entering a sub-screen (config, loadsave)
## shelves the current sprite list -- its sprites stop being
## displayed -- and starts a fresh list; pop discards the
## sub-screen's list and restores the shelved one with the
## visibility each sprite had when it was shelved.
func _sc_sprite_push(_a: Array) -> Dictionary:
	var vis: Dictionary = {}
	for id in _order:
		if _sprites.has(id):
			var nd := _sprites[id]["node"] as Sprite2D
			vis[id] = nd.visible
			nd.visible = false
	_order_stack.append({"order": _order.duplicate(), "vis": vis})
	_order = []
	return MajiroVm.vint(0)


func _sc_sprite_pop(_a: Array) -> Dictionary:
	if _order_stack.is_empty():
		return MajiroVm.vint(0)
	var entry: Dictionary = _order_stack.pop_back()
	var saved: Array = entry["order"]
	var vis: Dictionary = entry["vis"]
	for id in _sprites:
		if not saved.has(id):
			(_sprites[id]["node"] as Sprite2D).visible = false
	_order = saved.filter(func(id: int) -> bool: return _sprites.has(id))
	for id in _order:
		(_sprites[id]["node"] as Sprite2D).visible = bool(vis.get(id, true))
	_reindex()
	return MajiroVm.vint(0)


## areaevent_set(id, x, y, xl, yl, cb_a, cb_b, cb_c, flags): register
## a mouse area. The three callback slots are (on, off, click) in
## engine order (the click slot verified against buttonmenu's
## handlers, which receive (id, x, y, xl, yl) as their arguments).
func _sc_areaevent_set(a: Array) -> Dictionary:
	if a.size() < 8:
		return MajiroVm.vint(0)
	var rec := {
		"id": _ai(a[0]), "x": _ai(a[1]), "y": _ai(a[2]),
		"xl": _ai(a[3]), "yl": _ai(a[4]),
		"on": _ai(a[5]) & 0xFFFFFFFF, "off": _ai(a[6]) & 0xFFFFFFFF,
		"click": _ai(a[7]) & 0xFFFFFFFF,
		"flags": _ai(a[8]) if a.size() >= 9 else 0,
		"hover": false,
	}
	for i in range(_areas.size()):
		if int(_areas[i]["id"]) == int(rec["id"]):
			_areas[i] = rec
			return MajiroVm.vint(0)
	_areas.append(rec)
	return MajiroVm.vint(0)


func _fire_area(rec: Dictionary, fn: int) -> void:
	if fn == 0:
		return
	vm.spawn_function(fn, [MajiroVm.vint(int(rec["id"])), MajiroVm.vint(int(rec["x"])),
			MajiroVm.vint(int(rec["y"])), MajiroVm.vint(int(rec["xl"])), MajiroVm.vint(int(rec["yl"]))])


## areaevent_check(): dispatch hover enter/leave and click events
## for the registered areas against the current mouse state.
func _sc_areaevent_check(_a: Array) -> Dictionary:
	var fired_click := false
	for rec in _areas:
		var inside := mouse_pos.x >= float(rec["x"]) and mouse_pos.x < float(rec["x"] + rec["xl"]) \
				and mouse_pos.y >= float(rec["y"]) and mouse_pos.y < float(rec["y"] + rec["yl"])
		if inside and not bool(rec["hover"]):
			rec["hover"] = true
			_fire_area(rec, int(rec["on"]))
		elif not inside and bool(rec["hover"]):
			rec["hover"] = false
			_fire_area(rec, int(rec["off"]))
		if area_click_bits != 0 and int(rec["click"]) != 0 \
				and area_click_pos.x >= float(rec["x"]) and area_click_pos.x < float(rec["x"] + rec["xl"]) \
				and area_click_pos.y >= float(rec["y"]) and area_click_pos.y < float(rec["y"] + rec["yl"]):
			_fire_area(rec, int(rec["click"]))
			fired_click = true
	if fired_click:
		area_click_bits = 0
	return MajiroVm.vint(0)


func _sc_mk_wait(a: Array) -> Dictionary:
	if click_bits != 0:
		var b := click_bits
		click_bits = 0
		vm._cur["mk_armed"] = false
		return MajiroVm.vint(b)
	vm._cur["mk_armed"] = true
	_suspend()
	return MajiroVm.vint(0)


func _sc_wait(a: Array) -> Dictionary:
	var t: Dictionary = vm._cur
	var ms := _ai(a[0]) if not a.is_empty() else 0
	if t.has("stage_wait_until"):
		if time_ms >= int(t["stage_wait_until"]):
			t.erase("stage_wait_until")
			return MajiroVm.vint(0)
		_suspend()
		return MajiroVm.vint(0)
	if ms <= 0:
		# wait(0) / wait(-1) / wait(-2) are frame-sync waits in
		# Majiro: yield until the next stage frame. Returning
		# instantly made script animation loops spin forever
		# inside a single vm.run.
		if t.has("stage_wait_frame"):
			if _frame_no >= int(t["stage_wait_frame"]):
				t.erase("stage_wait_frame")
				return MajiroVm.vint(0)
			_suspend()
			return MajiroVm.vint(0)
		t["stage_wait_frame"] = _frame_no + 1
		_suspend()
		return MajiroVm.vint(0)
	t["stage_wait_until"] = time_ms + ms
	_suspend()
	return MajiroVm.vint(0)


## timer_sync(state, interval_ms) -> new state: frame-pacing
## primitive. Blocks until state+interval (engine time) and returns
## that boundary; if already past it, returns the boundary at once
## so the caller's cadence stays drift-free.
func _sc_timer_sync(a: Array) -> Dictionary:
	var t: Dictionary = vm._cur
	if t.has("ts_until"):
		var ret := int(t["ts_ret"])
		t.erase("ts_until")
		t.erase("ts_ret")
		return MajiroVm.vint(ret)
	var state := _ai(a[0]) if a.size() >= 1 else 0
	var interval := _ai(a[1]) if a.size() >= 2 else 0
	var target := state + interval
	if target <= time_ms:
		# Behind schedule: drop missed beats once the lag exceeds a
		# few intervals, or a slow frame makes the caller spiral in
		# catch-up passes (observed with script-side effect loops).
		if interval > 0 and time_ms - target > interval * 4:
			return MajiroVm.vint(time_ms)
		return MajiroVm.vint(target)
	t["ts_until"] = target
	t["ts_ret"] = target
	_suspend()
	return MajiroVm.vint(0)


var _event_hooks := {}        # name -> [fn hash]
var _event_hooks_after := {}  # name -> [fn hash]


## event_hook(name$, fn): register a script handler for a named
## engine event. do_event dispatches to the registered handlers.
func _sc_event_hook(a: Array) -> Dictionary:
	if a.size() >= 2:
		var nm := MajiroText.decode_cp932(_ab(a[0]))
		var arr: Array = _event_hooks.get(nm, [])
		arr.append(_ai(a[1]) & 0xFFFFFFFF)
		_event_hooks[nm] = arr
	return MajiroVm.vint(0)


func _sc_event_hook_after(a: Array) -> Dictionary:
	if a.size() >= 2:
		var nm := MajiroText.decode_cp932(_ab(a[0]))
		var arr: Array = _event_hooks_after.get(nm, [])
		arr.append(_ai(a[1]) & 0xFFFFFFFF)
		_event_hooks_after[nm] = arr
	return MajiroVm.vint(0)


## event_release(name$, fn): unregister a handler previously added
## with event_hook/event_hook_after (same argument order).
func _sc_event_release(a: Array) -> Dictionary:
	if a.size() >= 2:
		var nm := MajiroText.decode_cp932(_ab(a[0]))
		var fn := _ai(a[1]) & 0xFFFFFFFF
		if _event_hooks.has(nm):
			(_event_hooks[nm] as Array).erase(fn)
		if _event_hooks_after.has(nm):
			(_event_hooks_after[nm] as Array).erase(fn)
	return MajiroVm.vint(0)


## do_event(name$, args...): fire the named event's handlers (each
## in its own thread, receiving the event arguments).
func _sc_do_event(a: Array) -> Dictionary:
	if a.is_empty():
		return MajiroVm.vint(0)
	var nm := MajiroText.decode_cp932(_ab(a[0]))
	fire_event(nm, a.slice(1))
	return MajiroVm.vint(0)


## Fire a named engine event: spawn every hooked handler (before
## and after sets) with the given VM-value arguments. Used by
## do_event and by the console layer for the engine's built-in
## CONSOLE_* events.
func fire_event(nm: String, args: Array) -> void:
	for fn in _event_hooks.get(nm, []):
		vm.spawn_function(int(fn), args)
	for fn in _event_hooks_after.get(nm, []):
		vm.spawn_function(int(fn), args)


const TRANSITION_MS := 800


## do_event_single(name$, arg): the engine's built-in transition event
## blocks the calling thread while the transition runs; on completion
## OR on a click-skip it resumes the thread at its armed bsel.5 target
## (the pic/transit cleanup path) instead of returning.
func _sc_do_event_single(a: Array) -> Dictionary:
	# Engine semantics (pinned 2026-11-06 from pic/transit mjil):
	# do_event_single(-1, name$, payload...) fires the named event's
	# hooked workers with the payload and BLOCKS the caller until
	# every spawned worker thread has finished; a click kills the
	# workers and skips the caller to its armed bsel.5 destructor
	# (handled in _tick_waits). The transition effects themselves
	# are script code (transit.mjil / transit_top.mjil): workers
	# self-select on the effect number, claim the transition via
	# $$trans_notice@PIC's thread-int lock, and animate a sprite
	# created on the transition page. The -1 and the name are the
	# engine's own arguments; hooks receive only the payload.
	var t: Dictionary = vm._cur
	if bool(t.get("join_done", false)):
		t.erase("join_done")
		return MajiroVm.vint(0)
	var name_idx := -1
	var nm := ""
	for k in range(a.size()):
		if int(a[k]["k"]) == K_STRING:
			var s := MajiroText.decode_cp932(_ab(a[k]))
			if s == "DO_TRANSITION" or s == "DO_TOP_TRANSITION":
				name_idx = k
				nm = s
				break
	if name_idx < 0:
		unhandled[0x29F1AC40] = int(unhandled.get(0x29F1AC40, 0)) + 1
		return MajiroVm.vint(0)
	var payload: Array = a.slice(name_idx + 1)
	var tids: Array = []
	for fn in _event_hooks.get(nm, []):
		tids.append(vm.spawn_function(int(fn), payload))
	for fn in _event_hooks_after.get(nm, []):
		tids.append(vm.spawn_function(int(fn), payload))
	if tids.is_empty():
		return MajiroVm.vint(0)
	t["join_tids"] = tids
	_suspend()
	return MajiroVm.vint(0)


func _sc_draw_wait(a: Array) -> Dictionary:
	var t: Dictionary = vm._cur
	if bool(t.get("dw_armed", false)):
		t["dw_armed"] = false
		return MajiroVm.vint(0)
	t["dw_armed"] = true
	_suspend()
	return MajiroVm.vint(0)
