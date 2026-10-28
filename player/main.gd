extends Node2D
## ANIM2rGodot player entry point.
##
## Boot: --game-dir <path> (or a directory dialog) -> GamePackage ->
## SceScript + DefineTable -> ScriptVM drives Stage / AudioDirector /
## DialogueUI through presentable events.
##
## Keys: click / Space / Enter = advance, F5 = save, F9 = load,
## Ctrl (hold) = skip. Autoplay (for tests): --autoplay <seconds>
## --shots <dir> --stats <path>.

var pkg: GamePackage
var vm: ScriptVM
var gallery: GalleryUI
var _sce: SceScript
var _recol_table: Array = []
var _recol_targets: Dictionary = {}  # record index -> dispatch value
var _session_live := false
var _in_recollection := false
var _gallery_movie := ""
var _web_source: WebSource
var _waiting := ""  # "", "say", "choice"
var _ended := false
var _need_pump := false
var _boot_ticks := 0
var _backlog: Array = []

var _auto := false
var _auto_interval := 0.35
var _auto_left := 0.0
var _auto_timer := 0.0
var _shots_dir := ""
var _stats_path := ""
var _shot_beats: Dictionary = {}
var _stat_events := 0
var _stat_say := 0
var _stat_choice := 0
var _stat_effects := {}
var _seen_emote := false
var _seen_bg := false

@onready var stage: Stage = $Stage
@onready var audio: AudioDirector = $AudioDirector
@onready var ui: DialogueUI = $DialogueUI


func _ready() -> void:
	_boot_ticks = Time.get_ticks_msec()
	ui.choice_picked.connect(_on_choice_picked)
	gallery = GalleryUI.new()
	add_child(gallery)
	gallery.start_story.connect(_on_gallery_start_story)
	gallery.resume_game.connect(func() -> void: gallery.hide_all())
	gallery.load_save.connect(_on_gallery_load_save)
	gallery.start_recollection.connect(_on_gallery_recollection)
	gallery.play_movie.connect(_on_gallery_movie_picked)
	gallery.list_movies_requested.connect(_on_gallery_movies_requested)
	gallery.list_scenes_requested.connect(_on_gallery_scenes_requested)
	gallery.back_to_title.connect(_show_title)
	var args := OS.get_cmdline_user_args()
	var web_probe := false
	if OS.has_feature("web"):
		var loc0: String = Engine.get_singleton("JavaScriptBridge").eval(
				"window.location.href", true)
		web_probe = "probe=1" in loc0
	if "--probe-charset" in args or web_probe:
		var b64 := CharsetTables.table_b64("gbk")
		var raw := Marshalls.base64_to_raw(b64)
		var hc := HashingContext.new()
		hc.start(HashingContext.HASH_SHA256)
		hc.update(raw)
		print("PROBE b64_len=", b64.length(), " raw_len=", raw.size(),
			" sha256=", hc.finish().hex_encode())
		print("PROBE first16=", raw.slice(0, 16).hex_encode())
		var cs := Charset.load_mode("gbk")
		var probe := PackedByteArray([0xBA, 0xC6, 0xB8, 0xA8])
		var s := cs.decode(probe)
		var cps := []
		for k in s.length():
			cps.append(s.unicode_at(k))
		print("PROBE decode bac6b8a8 -> ", s, " cps=", cps)
		var ff = load("res://assets/fonts/NotoSansCJK-Regular.ttc")
		print("PROBE font class=", ff.get_class() if ff != null else "null")
		if ff != null:
			print("PROBE font data_size=", ff.data.size(),
				" has_A=", ff.has_char(0x41),
				" has_hao=", ff.has_char(0x6D69),
				" has_tri=", ff.has_char(0x25BC),
				" size_hao=", ff.get_string_size("浩辅", HORIZONTAL_ALIGNMENT_LEFT, -1, 28))
		if not OS.has_feature("web"):
			get_tree().quit()
		return
	var dir := ""
	var webpkg := ""
	var i := 0
	while i < args.size():
		match args[i]:
			"--game-dir":
				i += 1
				dir = args[i]
			"--webpkg":
				i += 1
				webpkg = args[i]
			"--autoplay":
				i += 1
				_auto = true
				_auto_left = float(args[i])
			"--shots":
				i += 1
				_shots_dir = args[i]
			"--stats":
				i += 1
				_stats_path = args[i]
		i += 1
	if webpkg != "":
		# Online package (also how the desktop build tests the web
		# data path: WebSource is plain HTTPRequest everywhere).
		start_game_web(webpkg)
	elif OS.has_feature("web"):
		_boot_web()
	elif dir != "":
		start_game(dir)
	else:
		ui.show_status("ANIM2rGodot — choose a game data directory")
		var dlg := FileDialog.new()
		dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		dlg.access = FileDialog.ACCESS_FILESYSTEM
		dlg.title = "Select the game data directory (contains *_sce.dat)"
		add_child(dlg)
		dlg.dir_selected.connect(start_game)
		dlg.popup_centered_ratio(0.7)


## Web boot: the package is a sibling "pkg/" directory of the player
## unless ?pkg=<url> says otherwise; ?autoplay=<seconds> mirrors the
## desktop test harness.
func _boot_web() -> void:
	var pkg_url := "pkg/"
	var jsb := Engine.get_singleton("JavaScriptBridge")
	var loc: String = jsb.eval("window.location.href", true)
	var q := loc.find("?")
	if q >= 0:
		for pair in loc.substr(q + 1).split("&"):
			var kv := pair.split("=", true, 1)
			if kv.size() == 2:
				match kv[0]:
					"pkg":
						pkg_url = kv[1].uri_decode()
					"autoplay":
						_auto = true
						_auto_left = float(kv[1])
	if not pkg_url.begins_with("http"):
		var page := loc.substr(0, q) if q >= 0 else loc
		pkg_url = page.substr(0, page.rfind("/") + 1) + pkg_url
	start_game_web(pkg_url)


func start_game_web(base_url: String) -> void:
	ui.show_status("Loading online package…")
	_web_source = WebSource.new()
	add_child(_web_source)
	pkg = GamePackage.new()
	if not await pkg.open_web(_web_source, base_url):
		ui.show_status("No ANIM web package at: " + base_url)
		return
	_begin_game()


func start_game(dir: String) -> void:
	pkg = GamePackage.new()
	if not pkg.open(dir):
		ui.show_status("No ANIM data package found in: " + dir)
		return
	_begin_game()


func _begin_game() -> void:
	ui.show_status("")
	_sce = SceScript.load_from_bytes(pkg.sce_bytes())
	var define := DefineTable.parse(pkg.define_bytes())
	stage.setup(pkg, define)
	audio.setup(pkg)
	_load_system()
	_recol_table = _sce.recollection_table()
	_recol_targets = {}
	for e in _recol_table:
		_recol_targets[int(e["target"])] = int(e["value"])
	if _auto:
		_new_vm(0)
		_pump()
	else:
		_show_title()


## Fresh VM boot. request > 0 enters a recollection scene through
## the script's own CheckMemory dispatch (op 0xA6 register).
func _new_vm(request: int) -> void:
	stage.clear_stage()
	audio.stop_bgm()
	audio.stop_voice()
	audio.stop_bgv()
	vm = ScriptVM.new(_sce)
	vm.recollection_request = request
	vm.watch_targets = _recol_targets
	_ended = false
	_waiting = ""
	_backlog.clear()
	_session_live = true


func _show_title() -> void:
	var scenes_total := maxi(0, _recol_table.size() - 1)
	gallery.show_title(_session_live and not _ended,
			FileAccess.file_exists("user://save.json"),
			_system["movies"].size(), scenes_total,
			_system["reached"].size())


func _on_gallery_start_story() -> void:
	_in_recollection = false
	_new_vm(0)
	gallery.hide_all()
	_pump()


func _on_gallery_load_save() -> void:
	gallery.hide_all()
	if vm == null:
		_new_vm(0)  # _load_game restores state onto a live VM
	_load_game("user://save.json")


func _on_gallery_recollection(value: int) -> void:
	_in_recollection = true
	_new_vm(value)
	gallery.hide_all()
	_pump()


func _on_gallery_movie_picked(name: String) -> void:
	_gallery_movie = name
	gallery.hide_all()
	stage.play_movie(name)


func _on_gallery_movies_requested() -> void:
	var names: Array = _system["movies"].keys()
	names.sort()
	gallery.show_movies(names)


func _on_gallery_scenes_requested() -> void:
	var entries: Array = []
	for e in _recol_table:
		var value: int = e["value"]
		if value == 0:
			continue
		var caption := "场景 %02d" % value
		var pv := _sce.preview_line(int(e["target"]))
		if not pv.is_empty():
			var line := DialogueUI.display_text(pv["text"])
			if line.length() > 26:
				line = line.substr(0, 18) + "…"
			if pv["speaker"] != "":
				caption += "　" + pv["speaker"] + "「" + line + "」"
			else:
				caption += "　" + line
		entries.append({"value": value, "caption": caption,
				"enabled": _system["reached"].has(str(value))})
	gallery.show_scenes(entries)


func _process(delta: float) -> void:
	stage.set_voice_level(audio.voice_level())
	# A gallery movie that ended on its own returns to the list.
	if _gallery_movie != "" and not stage.movie_playing():
		_gallery_movie = ""
		_on_gallery_movies_requested()
	# Recollection reach tracking: the VM flags every dispatch
	# target it executes; drain those into the unlock store.
	if vm != null and not vm.visited_scenes.is_empty():
		var changed := false
		for v in vm.visited_scenes:
			if int(v) > 0 and not _system["reached"].has(str(v)):
				_system["reached"][str(v)] = true
				changed = true
		vm.visited_scenes.clear()
		if changed:
			_persist_system()
	if vm == null or _ended:
		return
	vm.channel_playing = audio.any_voice_playing()
	vm.ctrl_held = Input.is_key_pressed(KEY_CTRL)
	if _need_pump:
		_need_pump = false
		_pump()
	if _auto:
		_auto_left -= delta
		_auto_timer += delta
		if _waiting == "say" and _auto_timer >= _auto_interval:
			_auto_timer = 0.0
			_advance()
		elif _waiting == "choice" and _auto_timer >= _auto_interval:
			_auto_timer = 0.0
			_on_choice_picked(0)
		_check_shot_beats(delta)
		if _auto_left <= 0.0:
			_finish_autoplay()


func _pump() -> void:
	if vm == null or _ended:
		return
	while true:
		vm.channel_playing = audio.any_voice_playing()
		var ev := vm.run_until_event()
		for e in vm.drain_effects():
			_apply_effect(e)
		_stat_events += 1
		match ev["kind"]:
			"say":
				_stat_say += 1
				ui.present_say(ev["speaker"], ev["text"])
				if ev["voice"] != "":
					audio.play_voice(ev["voice"])
				_backlog.append({"speaker": ev["speaker"], "text": ev["text"]})
				_waiting = "say"
				return
			"narrate":
				_stat_say += 1
				ui.present_narrate(ev["text"])
				_backlog.append({"speaker": "", "text": ev["text"]})
				_waiting = "say"
				return
			"choice":
				_stat_choice += 1
				ui.show_choices(ev["options"])
				_waiting = "choice"
				return
			"end":
				_ended = true
				_waiting = ""
				_session_live = false
				ui.show_status("— END —")
				if _auto:
					_finish_autoplay()
				else:
					_in_recollection = false
					_show_title()
				return
			_:  # stall: VM is polling a realtime wait; retry next frame
				_need_pump = true
				return


func _apply_effect(e: Dictionary) -> void:
	var kind: String = e["kind"]
	_stat_effects[kind] = int(_stat_effects.get(kind, 0)) + 1
	match kind:
		"image":
			stage.show_image(e["name"])
			_seen_bg = true
		"movie":
			stage.play_movie(e["name"])
		"bgm_play":
			audio.play_bgm(e["track"])
		"bgm_stop":
			audio.stop_bgm()
		"bgm_fade":
			audio.fade_bgm(e["ms"])
		"voice_play":
			audio.play_bgv(e["name"])
		"voice_stop":
			audio.stop_bgv()
		"emote_load":
			stage.emote_load(e["slot"], e["name"])
		"emote_unload":
			stage.emote_unload(e["slot"])
		"emote_load_hc":
			stage.emote_load_hc(e["slot"], e["name"])
		"emote_pose":
			stage.emote_pose(e["slot"], e["label"], e["time"])
			_seen_emote = true
		"emote_pose_hc":
			stage.emote_pose_hc(e["slot"], e["label"], e["time"])
			_seen_emote = true
		"unlock_movie":
			_unlock("movies", e["name"])
		"unlock_hc":
			_unlock("hc", e["name"])
		"pos_set":
			stage.pos_set(e["pair"], e["slot"], e["x"], e["y"])
		"pos_move":
			stage.pos_move(e["slot"], e["dx"], e["dy"], e["ms"])
		"chara_scale":
			stage.chara_scale(e["slot"], e["raw"], e["ms"])
		"paramset":
			stage.note_transition(e["id"], e["value"], e["tail"])
		"snapshot":
			_save_game("user://autosave.json")


## Gallery unlock store (engine system data equivalent): op 0x21
## registers movies, op 0x1F registers HC scenes, and "reached"
## tracks which recollection scenes story play has entered;
## idempotent, persisted to user://system.json.
var _system: Dictionary = {"movies": {}, "hc": {}, "reached": {}}


func _load_system() -> void:
	_system = {"movies": {}, "hc": {}, "reached": {}}
	if FileAccess.file_exists("user://system.json"):
		var parsed: Variant = JSON.parse_string(
				FileAccess.get_file_as_string("user://system.json"))
		if parsed is Dictionary:
			for kind in ["movies", "hc"]:
				for name in parsed.get(kind, []):
					_system[kind][name] = true
			for v in parsed.get("reached", []):
				_system["reached"][str(int(v))] = true


func _persist_system() -> void:
	var out := {}
	for k in _system:
		out[k] = _system[k].keys()
	var f := FileAccess.open("user://system.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(out))


func _unlock(kind: String, name: String) -> void:
	if not _system[kind].has(name):
		_system[kind][name] = true
		_persist_system()


func _advance() -> void:
	stage.stop_movie()
	if _waiting != "say":
		return
	_waiting = ""
	audio.stop_voice()
	vm.advance_requested = true
	_pump()


func _on_choice_picked(k: int) -> void:
	if _waiting != "choice":
		return
	_waiting = ""
	vm.choose(k)
	_pump()


func _input(event: InputEvent) -> void:
	var esc: bool = event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE
	var click: bool = event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT
	# While a gallery movie plays, Esc/click stops it and reopens
	# the movie list; nothing reaches the story VM.
	if _gallery_movie != "":
		if esc or click:
			stage.stop_movie()
			_gallery_movie = ""
			_on_gallery_movies_requested()
		return
	# While any gallery screen is open, story input is suspended;
	# Esc walks back (list -> title -> resume).
	if gallery != null and gallery.is_open():
		if esc:
			if gallery.mode() == "title":
				if _session_live and not _ended:
					gallery.hide_all()
			else:
				_show_title()
		return
	if esc and vm != null and _session_live:
		_show_title()
		return
	if click:
		_advance()
	elif event.is_action_pressed("ui_accept"):
		_advance()
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F5:
			_save_game("user://save.json")
			ui.show_status("saved")
		elif event.keycode == KEY_F9:
			_load_game("user://save.json")


func _save_game(path: String) -> void:
	if vm == null:
		return
	var data := {
		"pc": vm.pc, "stack": vm.call_stack,
		"lf": Array(vm.flags_local), "gf": Array(vm.flags_global),
		"stage": stage.get_state(), "bgm": audio.current_bgm,
		"backlog": _backlog,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()


func _load_game(path: String) -> void:
	if vm == null or not FileAccess.file_exists(path):
		return
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	vm.pc = int(data["pc"])
	vm.call_stack = (data["stack"] as Array).map(func(v: Variant) -> int: return int(v))
	for i in vm.flags_local.size():
		vm.flags_local[i] = int((data["lf"] as Array)[i])
	for i in vm.flags_global.size():
		vm.flags_global[i] = int((data["gf"] as Array)[i])
	stage.apply_state(data["stage"])
	if int(data["bgm"]) >= 0:
		audio.play_bgm(int(data["bgm"]))
	_backlog = data["backlog"]
	_ended = false
	_waiting = ""
	ui.show_status("loaded")
	_pump()


# ---- autoplay test harness ----

func _check_shot_beats(_delta: float) -> void:
	if _shots_dir == "":
		return
	if _seen_bg and not _shot_beats.has("bg"):
		_shot_beats["bg"] = true
		_take_shot("shot_bg.png")
	if _seen_emote and not _shot_beats.has("emote"):
		_shot_beats["emote"] = true
		_take_shot("shot_emote.png")
	if _waiting == "choice" and not _shot_beats.has("choice"):
		_shot_beats["choice"] = true
		_take_shot("shot_choice.png")


func _take_shot(fname: String) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(_shots_dir)
	img.save_png(_shots_dir.path_join(fname))


func _finish_autoplay() -> void:
	var stats := {"events": _stat_events, "say": _stat_say,
			"choices": _stat_choice, "effects": _stat_effects,
			"blinks": stage.stats_blinks,
			"ended": _ended, "shots": _shot_beats.keys()}
	if OS.has_feature("web"):
		# No filesystem to write stats to and quit() would kill the
		# page: publish the stats where a test driver can read them.
		Engine.get_singleton("JavaScriptBridge").eval(
				"window.__animStats = " + JSON.stringify(stats), true)
		_auto = false
		return
	if _shots_dir != "":
		_take_shot("shot_final.png")
	if _stats_path != "":
		var f := FileAccess.open(_stats_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(stats))
		f.close()
	get_tree().quit()
