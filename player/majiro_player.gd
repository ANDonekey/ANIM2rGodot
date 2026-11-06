extends Node2D
## Majiro player entry scene: boots a Majiro game directory with the
## full presentation host (MajiroStage) and plays it interactively.
## Usage: majiro_player -- <game_dir>
##
## The game surface is a fixed 1024x768 SubViewport, shown scaled in
## the app window. The text codec is chosen from the game directory:
## a CHS.TBL glyph table -> "chs" substitution decode; an update arc
## -> "gbk"; otherwise the original "cp932".

const STEP_BUDGET := 60000

var vfs: MajiroVfs
var vm: MajiroVm
var host: MajiroHost
var stage: MajiroStage
var console: MajiroConsole
var audio: MajiroAudio
var text_codec := "cp932"
var _subviewport: SubViewport


func _ready() -> void:
	DisplayServer.window_set_size(Vector2i(1024, 768))
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: majiro_player -- <game_dir>")
		get_tree().quit(2)
		return
	var game_dir := args[0]
	vfs = MajiroVfs.new()
	if not vfs.open_game(game_dir):
		push_error("no Majiro arcs found in " + game_dir)
		get_tree().quit(1)
		return
	if vfs.has_update:
		text_codec = "gbk"
	var chs_path := game_dir + "/CHS.TBL"
	if FileAccess.file_exists(chs_path):
		var tbl := FileAccess.get_file_as_bytes(chs_path)
		if tbl.size() >= 122880:
			MajiroText.set_chs_table(tbl)
			text_codec = "chs"
	vm = MajiroVm.new(Callable(vfs, "load_script"))
	host = MajiroHost.new()
	host.game_dir = game_dir
	host.read_file = Callable(vfs, "read_file")
	host.attach(vm)
	_subviewport = SubViewport.new()
	_subviewport.size = Vector2i(1024, 768)
	_subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_subviewport)
	var disp_layer := CanvasLayer.new()
	disp_layer.layer = 100
	add_child(disp_layer)
	var disp := TextureRect.new()
	disp.set_anchors_preset(Control.PRESET_FULL_RECT)
	disp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	disp.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	disp.texture = _subviewport.get_texture()
	disp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disp_layer.add_child(disp)
	stage = MajiroStage.new()
	_subviewport.add_child(stage)
	stage.bind(vm, vfs)
	stage.attach()
	console = MajiroConsole.new()
	add_child(console)
	console.bind(vm, stage, text_codec)
	console.attach()
	stage._console = console
	audio = MajiroAudio.new()
	add_child(audio)
	audio.bind(vm, vfs)
	audio.attach()
	stage._audio = audio
	var sys_path := game_dir + "/savedata/majiro_system.mss"
	if FileAccess.file_exists(sys_path):
		var sf := FileAccess.open(sys_path, FileAccess.READ)
		if sf != null and vm.load_persistents(sf.get_buffer(sf.get_length())):
			print("majiro_player: system data loaded (persistent state restored)")
	if not vm.boot("start"):
		push_error("boot failed")
		get_tree().quit(1)
		return
	print("majiro_player: booted ", game_dir, " codec=", text_codec)


func _process(_delta: float) -> void:
	if vm == null:
		return
	vm.run(STEP_BUDGET)
	console.pump()
