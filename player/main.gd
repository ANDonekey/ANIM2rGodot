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
var title: TitleUI
var saveload: SaveLoadUI
var _pending_thumb: Image
var settings: GameSettings
var settings_ui: SettingsUI
var extra_ui: ExtraUI
var flow_ui: FlowUI
var _last_voice_by_speaker: Dictionary = {}
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
	title = TitleUI.new()
	add_child(title)
	title.start_story.connect(_on_gallery_start_story)
	title.load_save.connect(func() -> void:
		saveload.open_screen(pkg, "load", true))
	title.open_extra.connect(_on_title_extra)
	title.open_flow.connect(func() -> void: flow_ui.open_screen(pkg))
	saveload = SaveLoadUI.new()
	add_child(saveload)
	saveload.load_requested.connect(_on_saveload_load)
	saveload.save_requested.connect(_on_saveload_save)
	saveload.delete_requested.connect(_on_saveload_delete)
	saveload.wipe_requested.connect(_on_saveload_wipe)
	saveload.to_title_requested.connect(_show_title)
	settings = GameSettings.new()
	settings_ui = SettingsUI.new()
	settings_ui.settings = settings
	add_child(settings_ui)
	settings_ui.changed.connect(_apply_settings)
	settings_ui.test_bgm_requested.connect(func() -> void:
		audio.play_bgm(0))
	settings_ui.test_voice_requested.connect(func(char_id: String) -> void:
		var speaker := "千夏" if char_id == "chinatsu" else "文子"
		if _last_voice_by_speaker.has(speaker):
			audio.play_voice(_last_voice_by_speaker[speaker]))
	title.open_config.connect(func() -> void:
		settings_ui.open_screen(pkg, "config"))
	title.open_volume.connect(func() -> void:
		settings_ui.open_screen(pkg, "volume"))
	flow_ui = FlowUI.new()
	add_child(flow_ui)
	extra_ui = ExtraUI.new()
	add_child(extra_ui)
	extra_ui.to_title.connect(_show_title)
	extra_ui.start_recollection.connect(_on_gallery_recollection)
	extra_ui.music_play.connect(func(track: int) -> void:
		audio.set_bgm_loop(extra_ui.repeat_on())
		audio.play_bgm(track))
	extra_ui.music_stop.connect(func() -> void:
		audio.stop_bgm()
		audio.set_bgm_loop(true))
	extra_ui.music_repeat.connect(func(on: bool) -> void:
		audio.set_bgm_loop(on))
	_load_system()
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
	_apply_settings()
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
	_apply_bgv_gain(false)
	audio.stop_bgv()
	vm = ScriptVM.new(_sce)
	vm.recollection_request = request
	vm.watch_targets = _recol_targets
	_ended = false
	_waiting = ""
	_backlog.clear()
	_session_live = true


func _show_title() -> void:
	gallery.hide_all()
	title.show_title(pkg)
	if _shots_dir != "" and not _shot_beats.has("title"):
		_shot_beats["title"] = true
		_take_shot("shot_title.png")


## Open the SAVE / LOAD screen from in-game (S / L keys, system
## bar). The thumbnail is captured first, while the game is still
## visible - the original flashes its thumbnail-saving banner for
## the same reason.
## Push the persistent settings into the live engine: audio gains,
## screen mode, message window opacity, auto-mode interval.
func _apply_settings() -> void:
	if settings == null:
		return
	var v := settings.volume
	var master := int(v["master"]) / 100.0
	if not bool(v["play_master"]):
		master = 0.0
	AudioServer.set_bus_volume_db(0,
			linear_to_db(maxf(master, 0.0001)))
	audio.set_bgm_gain(int(v["bgm"]) / 100.0
			if bool(v["play_bgm"]) else 0.0)
	_apply_bgv_gain(false)
	if not OS.has_feature("web"):
		DisplayServer.window_set_mode(
				DisplayServer.WINDOW_MODE_FULLSCREEN
				if int(settings.config["screen_mode"]) == 1
				else DisplayServer.WINDOW_MODE_WINDOWED)
	ui.set_window_opacity(0.85
			- int(settings.config["window_opacity"]) / 100.0 * 0.7)
	_auto_interval = 1.2 - int(settings.config["auto_speed"]) / 100.0 * 1.1


## BGV gain with the dialogue ducking level applied while a voice
## line plays (BGV（台詞再生中） in the original's VOLUME screen).
func _apply_bgv_gain(duck: bool) -> void:
	if settings == null:
		return
	var v := settings.volume
	var f := int(v["bgv"]) / 100.0 if bool(v["play_bgv"]) else 0.0
	if duck and bool(v["play_bgv_duck"]):
		f *= int(v["bgv_duck"]) / 100.0
	audio.set_bgv_gain(f)


## Per-character voice gain from the VOLUME character tabs.
func _apply_voice_gain(speaker: String) -> void:
	if settings == null:
		return
	var char_id: String = {"千夏": "chinatsu", "文子": "fumiko"}.get(
			speaker, "")
	var f := 0.85
	if char_id != "" and settings.chars.has(char_id):
		var c: Dictionary = settings.chars[char_id]
		f = int(c["volume"]) / 100.0 if bool(c["play"]) else 0.0
	audio.set_voice_gain(f)


func _open_saveload(mode: String) -> void:
	_pending_thumb = get_viewport().get_texture().get_image()
	saveload.open_screen(pkg, mode, false)


func _write_slot(slot: int, thumb: Image) -> void:
	if vm == null:
		return
	DirAccess.make_dir_recursive_absolute(SaveLoadUI.SLOT_DIR)
	var data := _collect_save_data()
	var dt := Time.get_datetime_dict_from_system()
	var text := ""
	if not _backlog.is_empty():
		text = str(_backlog[_backlog.size() - 1].get("text", ""))
	data["meta"] = {
		"date": "%04d/%02d/%02d" % [dt["year"], dt["month"], dt["day"]],
		"time": "%02d:%02d:%02d" % [dt["hour"], dt["minute"], dt["second"]],
		"text": text,
	}
	var f := FileAccess.open(saveload.slot_path(slot), FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	if thumb != null:
		var timg := thumb.duplicate() as Image
		timg.resize(480, 270)
		timg.save_png(saveload.thumb_path(slot))


func _on_saveload_save(slot: int) -> void:
	_write_slot(slot, _pending_thumb)


func _on_saveload_load(slot: int) -> void:
	saveload.close()
	title.hide_all()
	gallery.hide_all()
	if vm == null or _ended:
		_new_vm(0)  # _load_game restores state onto a live VM
	_load_game(saveload.slot_path(slot))


func _on_saveload_delete(slot: int) -> void:
	DirAccess.remove_absolute(saveload.slot_path(slot))
	DirAccess.remove_absolute(saveload.thumb_path(slot))


func _on_saveload_wipe() -> void:
	var dir := DirAccess.open(SaveLoadUI.SLOT_DIR)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(SaveLoadUI.SLOT_DIR + "/" + file)


## EXTRA: the asset-driven five-tab hub (ExtraUI). Scenes are the
## CheckMemory dispatch values 1..76 with their reached state and
## first-line captions.
func _on_title_extra() -> void:
	title.hide_all()
	extra_ui.scenes = _extra_scenes()
	extra_ui.music_count = pkg.bgm_count()
	if extra_ui.define == null:
		extra_ui.define = DefineTable.parse(pkg.define_bytes())
	extra_ui.open_screen(pkg, "cg")


func _extra_scenes() -> Array:
	if _sce == null:
		_sce = SceScript.load_from_bytes(pkg.sce_bytes())
	var out: Array = []
	for e in _sce.recollection_table():
		var value := int(e["value"])
		if value <= 0:
			continue
		var caption := ""
		var pv := _sce.preview_line(int(e["target"]))
		if not pv.is_empty():
			var line := DialogueUI.display_text(pv["text"])
			if line.begins_with("「") and line.ends_with("」"):
				line = line.substr(1, line.length() - 2)
			caption = pv["speaker"] + "「" + line + "」" \
					if pv["speaker"] != "" else line
		out.append({"value": value,
				"reached": _system["reached"].has(str(value)),
				"caption": caption})
	return out


func _on_gallery_start_story() -> void:
	_in_recollection = false
	_new_vm(0)
	gallery.hide_all()
	title.hide_all()
	_pump()


func _on_gallery_load_save() -> void:
	gallery.hide_all()
	title.hide_all()
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
					_apply_voice_gain(ev["speaker"])
					_last_voice_by_speaker[ev["speaker"]] = ev["voice"]
					audio.play_voice(ev["voice"])
					_apply_bgv_gain(true)
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
			_write_slot(100, get_viewport().get_texture().get_image())


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
	_apply_bgv_gain(false)
	vm.advance_requested = true
	_pump()


func _on_choice_picked(k: int) -> void:
	if _waiting != "choice":
		return
	_waiting = ""
	ui.hide_choices()
	vm.choose(k)
	_pump()


func _input(event: InputEvent) -> void:
	var esc: bool = event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE
	var click: bool = event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT
	# While the SAVE / LOAD screen is open, input belongs to it.
	if saveload != null and saveload.is_open():
		if esc:
			saveload.go_back()
		return
	# The CONFIG / VOLUME screens handle their own input (incl. Esc).
	if settings_ui != null and settings_ui.is_open():
		return
	# The EXTRA hub handles its own input too.
	if extra_ui != null and extra_ui.is_open():
		return
	# The FLOW chart handles its own input too.
	if flow_ui != null and flow_ui.is_open():
		return
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
		elif event.keycode == KEY_S and _session_live and not _ended:
			_open_saveload("save")
		elif event.keycode == KEY_L and _session_live and not _ended:
			_open_saveload("load")
		elif event.keycode == KEY_C and _session_live and not _ended:
			settings_ui.open_screen(pkg, "config")
		elif event.keycode == KEY_V and _session_live and not _ended:
			settings_ui.open_screen(pkg, "volume")
		elif event.keycode == KEY_Y and _session_live and not _ended:
			flow_ui.open_screen(pkg)


func _collect_save_data() -> Dictionary:
	return {
		"pc": vm.pc, "stack": vm.call_stack,
		"lf": Array(vm.flags_local), "gf": Array(vm.flags_global),
		"stage": stage.get_state(), "bgm": audio.current_bgm,
		"backlog": _backlog,
	}


func _save_game(path: String) -> void:
	if vm == null:
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(_collect_save_data()))
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
