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
	var args := OS.get_cmdline_user_args()
	var dir := ""
	var i := 0
	while i < args.size():
		match args[i]:
			"--game-dir":
				i += 1
				dir = args[i]
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
	if dir != "":
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


func start_game(dir: String) -> void:
	pkg = GamePackage.new()
	if not pkg.open(dir):
		ui.show_status("No ANIM data package found in: " + dir)
		return
	ui.show_status("")
	var sce := SceScript.load_from_bytes(pkg.sce_bytes())
	var define := DefineTable.parse(pkg.define_bytes())
	stage.setup(pkg, define)
	audio.setup(pkg)
	_load_system()
	vm = ScriptVM.new(sce)
	_pump()


func _process(delta: float) -> void:
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
				ui.show_status("— END —")
				if _auto:
					_finish_autoplay()
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
			stage.movie_placeholder(e["name"])
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
## registers movies, op 0x1F registers HC scenes; idempotent, persisted
## to user://system.json.
var _system: Dictionary = {"movies": {}, "hc": {}}


func _load_system() -> void:
	_system = {"movies": {}, "hc": {}}
	if FileAccess.file_exists("user://system.json"):
		var parsed: Variant = JSON.parse_string(
				FileAccess.get_file_as_string("user://system.json"))
		if parsed is Dictionary:
			for kind in ["movies", "hc"]:
				for name in parsed.get(kind, []):
					_system[kind][name] = true


func _unlock(kind: String, name: String) -> void:
	if not _system[kind].has(name):
		_system[kind][name] = true
		var out := {}
		for k in _system:
			out[k] = _system[k].keys()
		var f := FileAccess.open("user://system.json", FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(out))


func _advance() -> void:
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
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
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
	if _shots_dir != "":
		_take_shot("shot_final.png")
	if _stats_path != "":
		var stats := {"events": _stat_events, "say": _stat_say,
				"choices": _stat_choice, "effects": _stat_effects,
				"ended": _ended, "shots": _shot_beats.keys()}
		var f := FileAccess.open(_stats_path, FileAccess.WRITE)
		f.store_string(JSON.stringify(stats))
		f.close()
	get_tree().quit()
