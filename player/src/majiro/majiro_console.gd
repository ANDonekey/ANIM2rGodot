class_name MajiroConsole
extends Node
## Console/text host for MajiroVm (design spec section 5).
##
## Text model: the VM appends text/proc/ctrl events to its trace;
## the console accumulates text, and at each proc (message end) it
## word-wraps the buffer, bakes the lines into the console page's
## image with one fixed Mincho-style system font (the engine's font
## name is ignored by design; only sizes are honored), and gates
## the scenario thread until the player clicks.
##
## Baking goes through a tiny offscreen SubViewport+Label so the
## glyphs land in the page image itself and take part in page
## compositing like the engine's fontout.

var vm: MajiroVm
var stage: MajiroStage
var codec := "cp932"

var text_page := 0
var rect := Rect2i(0, 0, 0, 0)
var cur := Vector2i.ZERO
var mojispeed := 0
var autospeed := 0
var fast_mode_flg := 0
var font_name_bytes := PackedByteArray()
# fontout context (exe FUN_00419d70..FUN_0041a0f0): one shared
# draw state for the fontout syscall family, holding the exe
# template's defaults until a script arms it. Colors are
# COLORREF-packed (R in the low byte) like console_color's; the
# sub color's top byte selects the shadow/outline mode.
var fo_name := PackedByteArray()
# Template defaults from the exe's fontout context block
# (0x4A7258): height 20, width 10, step 25, main color white,
# sub color -1 (none).
var fo_h := 20
var fo_w := 10
var fo_step := 25
var fo_extra := 0
var fo_mincho := false
var fo_color := 0x00FFFFFF
var fo_sub := -1
var fo_page := 0
var fo_pen := Vector2i.ZERO
var _fo_stack: Array = []
var _fo_queue: Array = []

# Font metrics armed by the most recent console_set (set_concon
# always pairs console_font with console_set). Text baking uses
# these, never the live font_* state: other threads (the yazlib
# half-size rubi helper) call console_font between a clear and
# its text, and baking must not inherit their metrics.
var bake_font_yl := 24
var bake_font_xl := 12
var bake_font_ystep := 35
var bake_prop := 0
# Same capture rule for the text colors: console_color is
# re-armed by set_concon right before its console_set, and
# other threads (name display) store fc/dc between a clear
# and the bake landing, so the bake must use the armed pair.
var bake_color_a := 0xFFFFFF
var bake_color_b := 0
# Surface generation: bumped on every window wipe. Bake jobs
# carry the generation they were queued in; a job whose
# generation has passed is dropped without drawing or firing
# its CONSOLE_WROTE (the native surface is synchronous, so a
# block replaced before display never reaches it -- our async
# bake must not smear it under the next block).
var _surface_gen := 0
# Trace events are processed strictly in order. A window wipe
# must not be applied until every bake queued before it has
# landed (the native surface draws synchronously); pump()
# therefore parks the batch at a wipe until the bake queue
# drains, and _process resumes it.
var _pending_events: Array = []
var _pump_parked := false
var color_a := 0xFFFFFF
var color_b := 0
var font_yl := 24
var font_xl := 12
var font_ystep := 35
var font_proportional := 0
var is_on := false
var _firing := {}
var waiting := false
## Harness instrumentation: number of non-empty messages flushed.
## Test hook (--hold-text): once a message is waiting, never auto-advance.
var hold := false
var events: Array = []
var stub_calls := {}

var _buffer := ""
var _bake_queue: Array = []   # {text, pos} line jobs
var _baking := false
var _font: Font
var _vp: SubViewport
var _label: Label
var _opened_once := false


func bind(p_vm: MajiroVm, p_stage: MajiroStage, p_codec: String) -> void:
	vm = p_vm
	stage = p_stage
	codec = p_codec


func _ready() -> void:
	var sf := SystemFont.new()
	sf.font_names = PackedStringArray([
		"Noto Serif CJK JP", "Noto Serif CJK SC", "IPAMincho",
		"MS PMincho", "MS Mincho", "serif"])
	_font = sf
	_vp = SubViewport.new()
	_vp.size = Vector2i(1100, 96)
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	_label = Label.new()
	_label.add_theme_font_override("font", _font)
	_vp.add_child(_label)


func gate() -> bool:
	return not waiting


func _process(_delta: float) -> void:
	if waiting and not hold and stage != null and (stage.click_bits != 0 or stage.area_click_bits != 0):
		waiting = false
	if not _baking and not _bake_queue.is_empty():
		_bake_next()
	if not _baking and not _fo_queue.is_empty():
		_fo_next()
	if _pump_parked and not _baking and _bake_queue.is_empty():
		_pump_parked = false
		_pump_step()


func _record(hash: int) -> Callable:
	return func(_a: Array) -> Dictionary:
		stub_calls[hash] = int(stub_calls.get(hash, 0)) + 1
		return MajiroVm.vint(0)


func attach() -> void:
	var s := vm.syscalls
	s[0x403960F8] = _sc_console_set          # console_set
	s[0x06B3C8AC] = _sc_console_font         # console_font
	s[0x5FDCCCEE] = func(a: Array) -> Dictionary: color_a = MajiroStage._ai(a[0]); color_b = MajiroStage._ai(a[1]) if a.size() >= 2 else 0; return MajiroVm.vint(0)  # console_color
	s[0xBA81EF8D] = func(a: Array) -> Dictionary: cur = Vector2i(MajiroStage._ai(a[0]), MajiroStage._ai(a[1])); return MajiroVm.vint(0)  # console_locate
	s[0xF1F8A206] = func(a: Array) -> Dictionary: cur = Vector2i(MajiroStage._ai(a[0]), MajiroStage._ai(a[1])); return MajiroVm.vint(0)  # console_locate_force
	s[0x0E42730D] = func(_a: Array) -> Dictionary: return MajiroVm.vint(cur.x)  # console_curpos_x
	s[0x934D927B] = func(_a: Array) -> Dictionary: return MajiroVm.vint(cur.y)  # console_curpos_y
	s[0xB5A1E3C9] = _sc_console_cls          # console_cls
	s[0x307F28BC] = func(_a: Array) -> Dictionary: return MajiroVm.vint(0)  # console_redraw
	s[0xA2743878] = _sc_console_on           # console_on
	s[0x979D1F16] = _sc_console_off          # console_off
	s[0x5B87A41D] = func(_a: Array) -> Dictionary: return MajiroVm.vint(1 if is_on else 0)  # console_is_on
	for h in [0x82FD765B, 0x2CB1BC41, 0x728876A3, 0x6E080825, 0x88B4B26C,
			0x3F401BBD, 0x6621F84D, 0x0C6D0129, 0x59180BBB, 0x5C9ED743,
			0x30FA2A29, 0x8D8D8817, 0xE6A97E70, 0xD4066E31, 0x4133D7A9]:
		s[h] = _record(h)  # font_height_get, hist family, histbuff_*
	s[0xE5C70196] = _sc_get_mojispeed      # get_mojispeed
	s[0x6501CC30] = func(a: Array) -> Dictionary: mojispeed = MajiroStage._ai(a[0]); return MajiroVm.vint(0)  # set_mojispeed
	s[0x6ED38886] = func(a: Array) -> Dictionary: autospeed = MajiroStage._ai(a[0]); return MajiroVm.vint(0)  # set_autospeed
	s[0x1EC3C6BB] = func(a: Array) -> Dictionary: font_name_bytes = MajiroStage._ab(a[0]); return MajiroVm.vint(0)  # set_font_name
	s[0xC5270429] = func(_a: Array) -> Dictionary: return MajiroVm.vstr(font_name_bytes)  # get_font_name$
	s[0xC1D2B85A] = func(a: Array) -> Dictionary: fast_mode_flg = MajiroStage._ai(a[0]); return MajiroVm.vint(0)  # set_fast_mode_flg
	s[0x3EABF498] = _record(0x3EABF498)      # fast_mode_config
	s[0x62374297] = func(_a: Array) -> Dictionary: return MajiroVm.vint(0)  # screen_mode
	s[0x57F6310D] = _sc_fontout_locate     # fontout_locate
	s[0x90816C6E] = _sc_fontout_color      # fontout_color
	s[0xE186D19A] = _sc_fontout_font       # fontout_font
	s[0x35A89417] = _sc_fontout            # fontout
	s[0x9A661709] = _sc_fontout_push       # fontout_push
	s[0xB75C3B5F] = _sc_fontout_pop        # fontout_pop
	vm.text_gate = Callable(self, "gate")


func _sc_get_mojispeed(_a: Array) -> Dictionary:
	# The canonical text-speed value lives in the config
	# persistent $ddf4e4e2 (stored by config's cfg loader);
	# set_mojispeed overrides it. A zero here would zero the
	# typewriter's timemax in $$cb_console_wrote@CONSOLE and
	# the reveal would copy a 0-width segment (found 2026-11-05).
	var v := mojispeed
	if v == 0:
		var cell: Variant = vm._persist_synth.get(0xDDF4E4E2, null)
		if cell != null:
			v = int((cell as Dictionary).get("v", 0))
	if v == 0:
		v = 50
	return MajiroVm.vint(v)


func _sc_console_set(a: Array) -> Dictionary:
	text_page = MajiroStage._ai(a[0])
	rect = Rect2i(MajiroStage._ai(a[1]), MajiroStage._ai(a[2]),
			MajiroStage._ai(a[3]), MajiroStage._ai(a[4]))
	cur = rect.position
	bake_font_yl = font_yl
	bake_font_xl = font_xl
	bake_font_ystep = font_ystep
	bake_prop = font_proportional
	bake_color_a = color_a
	bake_color_b = color_b
	return MajiroVm.vint(0)


func _sc_console_font(a: Array) -> Dictionary:
	# (name$, yl, xl, ystep, proportional): the name is ignored by
	# design (one fixed Mincho-style system font); sizes only.
	if a.size() >= 2:
		font_yl = MajiroStage._ai(a[1])
	if a.size() >= 3:
		font_xl = MajiroStage._ai(a[2])
	if a.size() >= 4:
		font_ystep = MajiroStage._ai(a[3])
	if a.size() >= 5:
		font_proportional = MajiroStage._ai(a[4])
	return MajiroVm.vint(0)


func _sc_console_cls(_a: Array) -> Dictionary:
	_buffer = ""
	if stage != null and text_page != 0:
		stage.page_clear_rect(text_page, rect)
	cur = rect.position
	return MajiroVm.vint(0)


func _event_args2(a: Array) -> Array:
	var args: Array = []
	args.append(MajiroVm.vint(MajiroStage._ai(a[0])) if a.size() >= 1 else MajiroVm.vint(0))
	args.append(MajiroVm.vint(MajiroStage._ai(a[1])) if a.size() >= 2 else MajiroVm.vint(0))
	return args


func _sc_console_on(a: Array) -> Dictionary:
	is_on = true
	# The engine's console_on also fires the CONSOLE_ON event: the
	# console record hooks it ($$cb_console_on@CONSOLE) to slide
	# its window in. (An earlier reading spawned $F7AC8CD8 here;
	# the actual dispatch is the event system, registered by
	# $$main@CONSOLE. Found 2026-11-05.)
	if stage != null and not _firing.has("CONSOLE_ON"):
		_firing["CONSOLE_ON"] = true
		stage.fire_event("CONSOLE_ON", _event_args2(a))
		_firing.erase("CONSOLE_ON")
	return MajiroVm.vint(0)


func _sc_console_off(a: Array) -> Dictionary:
	is_on = false
	if stage != null and not _firing.has("CONSOLE_OFF"):
		_firing["CONSOLE_OFF"] = true
		stage.fire_event("CONSOLE_OFF", _event_args2(a))
		_firing.erase("CONSOLE_OFF")
	return MajiroVm.vint(0)


static func _unpack_rgb(v: int) -> Color:
	return Color8(v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, 255)


## Drain the VM trace: accumulate text, flush at proc into baked
## lines on the console page, then gate for a click.
func pump() -> void:
	if vm.trace.is_empty():
		return
	var drained: Array = vm.trace.duplicate()
	vm.trace.clear()
	events.append_array(drained)
	_pending_events.append_array(drained)
	if not _pump_parked:
		_pump_step()


func _pump_step() -> void:
	while not _pending_events.is_empty():
		var ev: Dictionary = _pending_events[0]
		var kind := String(ev.get("ev", ""))
		if kind == "ctrl":
			var cs := MajiroText.decode(ev["s"], codec)
			if cs == "w" and (not _bake_queue.is_empty() or _baking):
				# Let the previous block's bakes land before
				# the wipe replaces them; _process resumes us.
				_pump_parked = true
				return
			_pending_events.pop_front()
			_on_ctrl(cs)
		elif kind == "text":
			_pending_events.pop_front()
			_buffer += MajiroText.decode(ev["s"], codec)
		elif kind == "proc":
			_pending_events.pop_front()
			_flush_message()
		else:
			_pending_events.pop_front()


func _on_ctrl(s: String) -> void:
	if s == "\n" or s == "\r\n":
		_buffer += "\n"
		return
	if s == "w":
		# ctrl "w": wipe the message window -- the engine fires
		# CONSOLE_CLS; $$cb_console_cls@CONSOLE re-arms the text
		# area via console_set. The native console also clears
		# its text surface at this point (cb_console_cls has no
		# grp ops at all), so clear the draw page's text rect and
		# home the cursor here.
		_surface_gen += 1
		if stage != null:
			stage.fire_event("CONSOLE_CLS", [])
			if text_page != 0:
				stage.clear_page_rect(text_page, rect)
			cur = rect.position
		return


func _flush_message() -> void:
	var text := _buffer
	_buffer = ""
	if stage != null and not text.strip_edges().is_empty():
		if not is_on:
			# A message arriving while the console is closed opens
			# the window: the engine fires CONSOLE_ON at this point
			# ($$cb_console_on@CONSOLE slides/fades the window in).
			is_on = true
			stage.fire_event("CONSOLE_ON", _event_args2([]))
	if text_page == 0 or stage == null:
		waiting = true
		return
	for line in _wrap(text):
		if cur.y >= rect.position.y + rect.size.y:
			break  # the native surface clips at the text area
		var lpos := Vector2i(cur.x, cur.y)
		# The engine fires CONSOLE_WROTE per written line with the
		# line's region (page, x, y_center, xl_px, yl, zerotime);
		# $$cb_console_wrote@CONSOLE extcopy-reveals exactly that
		# segment of con_draw into con_disp. Fire it only once the
		# line's bake has landed (the native surface is synchronous).
		var wargs: Array = [
			MajiroVm.vint(text_page), MajiroVm.vint(lpos.x),
			MajiroVm.vint(lpos.y + bake_font_yl / 2),
			MajiroVm.vint(_text_width(line)), MajiroVm.vint(bake_font_yl),
			MajiroVm.vint(0)]
		_bake_queue.append({"text": line, "pos": lpos, "wrote": wargs, "gen": _surface_gen})
		cur.y += bake_font_ystep
		cur.x = rect.position.x
	waiting = true


func _wrap(text: String) -> Array:
	var out: Array = []
	var max_w := rect.size.x
	for para in text.split("\n"):
		var line := ""
		for ch in para:
			var trial := line + ch
			if _text_width(trial) > max_w and line != "":
				out.append(line)
				line = ch
			else:
				line = trial
		out.append(line)
	return out


func _text_width(s: String) -> int:
	if bake_prop == 0:
		# Engine monospace cells: full-width glyphs take 2 cells
		# (confont_xl is the half-width unit, 12 for a 24px font).
		var cells := 0
		for ch in s:
			cells += 2 if ch.unicode_at(0) >= 0x1100 else 1
		return cells * maxi(1, bake_font_xl)
	if _font == null:
		return s.length() * maxi(1, font_xl)
	return int(_font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, bake_font_yl).x)



func _fo_measure(s: String, h: int) -> int:
	if _font == null:
		return s.length() * maxi(1, fo_w)
	return int(_font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, h).x)


func _sc_fontout_locate(a: Array) -> Dictionary:
	if a.size() >= 3:
		fo_page = MajiroStage._ai(a[0])
		fo_pen = Vector2i(MajiroStage._ai(a[1]), MajiroStage._ai(a[2]))
	return MajiroVm.vint(0)


func _sc_fontout_color(a: Array) -> Dictionary:
	if a.size() >= 1:
		fo_color = MajiroStage._ai(a[0])
	fo_sub = MajiroStage._ai(a[1]) if a.size() >= 2 else -1
	return MajiroVm.vint(0)


func _sc_fontout_font(a: Array) -> Dictionary:
	if a.size() >= 1:
		fo_name = MajiroStage._ab(a[0])
	fo_h = MajiroStage._ai(a[1]) if a.size() >= 2 else 20
	fo_w = MajiroStage._ai(a[2]) if a.size() >= 3 else fo_h / 2
	fo_step = MajiroStage._ai(a[3]) if a.size() >= 4 else (fo_h * 5) / 4
	fo_extra = MajiroStage._ai(a[4]) if a.size() >= 5 else 0
	# The exe flags Mincho faces (name contains the CP932 bytes
	# of "明朝"); their glyphs get a synthetic-bold second
	# strike in the rasterizer (FUN_0041a660).
	fo_mincho = false
	var pat := PackedByteArray([0x96, 0xBE, 0x92, 0xA9])
	if fo_name.size() >= 4:
		for i in range(fo_name.size() - 3):
			if fo_name[i] == pat[0] and fo_name[i + 1] == pat[1] and fo_name[i + 2] == pat[2] and fo_name[i + 3] == pat[3]:
				fo_mincho = true
				break
	return MajiroVm.vint(0)


func _sc_fontout_push(_a: Array) -> Dictionary:
	_fo_stack.append([fo_name, fo_h, fo_w, fo_step, fo_extra, fo_mincho, fo_color, fo_sub, fo_page, fo_pen])
	return MajiroVm.vint(0)


func _sc_fontout_pop(_a: Array) -> Dictionary:
	if not _fo_stack.is_empty():
		var s: Array = _fo_stack.pop_back()
		fo_name = s[0]
		fo_h = s[1]
		fo_w = s[2]
		fo_step = s[3]
		fo_extra = s[4]
		fo_mincho = s[5]
		fo_color = s[6]
		fo_sub = s[7]
		fo_page = s[8]
		fo_pen = s[9]
	return MajiroVm.vint(0)


func _sc_fontout(a: Array) -> Dictionary:
	if a.is_empty() or stage == null:
		return MajiroVm.vint(0)
	# UI records (config/loadsave/message_box) ship unpatched;
	# the engine renders their string bytes as CP932.
	var text := MajiroText.decode(MajiroStage._ab(a[0]), "cp932")
	if text == "" or fo_page == 0 or stage._page(fo_page) == null:
		return MajiroVm.vint(0)
	var w := _fo_measure(text, fo_h)
	var pos := fo_pen
	if a.size() >= 3:
		# Box form (exe FUN_0041a0f0): align inside the box at
		# the pen (align -1 = left, -2 = right, else center);
		# pen.y is restored afterwards, pen.x advances by the
		# drawn width.
		var bw := MajiroStage._ai(a[1])
		var bh := MajiroStage._ai(a[2])
		var align := MajiroStage._ai(a[3]) if a.size() >= 4 else 0
		if align == -2:
			pos.x += bw - w
		elif align != -1:
			pos.x += (bw - w) / 2
		pos.y += (bh - fo_h) / 2
	fo_pen.x += w
	_fo_queue.append({"page": fo_page, "text": text, "pos": pos, "h": fo_h,
			"color": fo_color, "sub": fo_sub, "mincho": fo_mincho})
	return MajiroVm.vint(0)


func _fo_next() -> void:
	_baking = true
	var job: Dictionary = _fo_queue.pop_front()
	if _vp == null or stage == null:
		_baking = false
		return
	var h := int(job["h"])
	_label.remove_theme_color_override("font_outline_color")
	_label.remove_theme_constant_override("outline_size")
	_label.remove_theme_color_override("font_shadow_color")
	_label.add_theme_font_size_override("font_size", h)
	_label.add_theme_color_override("font_color", _unpack_rgb(int(job["color"]) & 0xFFFFFF))
	var sub := int(job["sub"])
	if sub != -1:
		var sc := _unpack_rgb(sub & 0xFFFFFF)
		if ((sub >> 24) & 0x7F) == 1:
			_label.add_theme_color_override("font_outline_color", sc)
			_label.add_theme_constant_override("outline_size", maxi(1, h / 18))
		else:
			_label.add_theme_color_override("font_shadow_color", sc)
			_label.add_theme_constant_override("shadow_offset_x", maxi(1, h / 9))
			_label.add_theme_constant_override("shadow_offset_y", maxi(1, h / 18))
	_label.text = String(job["text"])
	var w := maxi(2, mini(1100, _fo_measure(String(job["text"]), h) + 16))
	_label.size = Vector2(w, h + 16)
	_vp.size = Vector2i(w, h + 16)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await get_tree().process_frame
	var img := _vp.get_texture().get_image()
	var crop_h := mini(img.get_height(), h + 8)
	if crop_h > 0 and img.get_width() > 0:
		var cropped := img.get_region(Rect2i(0, 0, img.get_width(), crop_h))
		var pos: Vector2i = job["pos"]
		stage.page_draw_image(int(job["page"]), cropped, pos)
		if bool(job["mincho"]):
			stage.page_draw_image(int(job["page"]), cropped, pos + Vector2i(1, 0))
	_label.remove_theme_color_override("font_outline_color")
	_label.remove_theme_constant_override("outline_size")
	_label.remove_theme_color_override("font_shadow_color")
	_baking = false


func _bake_next() -> void:
	_baking = true
	var job: Dictionary = _bake_queue.pop_front()
	var line: String = job["text"]
	var pos: Vector2i = job["pos"]
	if int(job.get("gen", 0)) != _surface_gen:
		_baking = false
		return  # superseded by a wipe while queued
	if line == "" or _vp == null:
		_baking = false
		if job.has("wrote") and stage != null:
			stage.fire_event("CONSOLE_WROTE", job["wrote"])
		return
	_label.add_theme_font_size_override("font_size", bake_font_yl)
	_label.add_theme_color_override("font_color", _unpack_rgb(bake_color_a))
	if bake_color_b != 0:
		# The shadow color's top byte is its alpha: set_concon
		# passes rgb(0,0,0) | (kmk << 24), and kmk is 1 in
		# practice, so the native shadow is effectively
		# invisible. Dropping the byte (as a plain RGB unpack
		# does) renders the shadow silhouette at full strength
		# and the glyphs read as dark blobs.
		var sc := _unpack_rgb(bake_color_b)
		sc.a = float((bake_color_b >> 24) & 0xFF) / 255.0
		if sc.a > 0.0:
			_label.add_theme_color_override("font_shadow_color", sc)
			_label.add_theme_constant_override("shadow_offset_x", 1)
			_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.text = line
	var w := maxi(2, mini(1100, _text_width(line) + 8))
	_label.size = Vector2(w, bake_font_yl + 16)
	_vp.size = Vector2i(w, bake_font_yl + 16)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await get_tree().process_frame
	if int(job.get("gen", 0)) != _surface_gen:
		_baking = false
		return  # wiped while this line was rendering
	var img := _vp.get_texture().get_image()
	# crop to the text's own height (the line box)
	var crop_h := mini(img.get_height(), bake_font_yl + 8)
	if crop_h > 0 and img.get_width() > 0:
		var cropped := img.get_region(Rect2i(0, 0, img.get_width(), crop_h))
		cropped.save_png("/tmp/mj_bake_last.png")
		stage.page_draw_image(text_page, cropped, pos)
	if job.has("wrote") and stage != null:
		stage.fire_event("CONSOLE_WROTE", job["wrote"])
	_baking = false
