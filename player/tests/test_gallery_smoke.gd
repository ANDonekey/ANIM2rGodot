extends SceneTree
## Gallery smoke test: boot the real main scene against a local
## package (interactive path), confirm the title menu opens, open
## the scene list, force-reach scene 1, enter the recollection and
## confirm dialogue flows from the scene entry. Screenshots land in
## <game_dir>/shots_gallery for visual review.
##   godot --headless --path player -s tests/test_gallery_smoke.gd -- <game_dir>

var _main: Node


func _shot(name: String) -> void:
	var img := root.get_texture().get_image()
	var dir := OS.get_cmdline_user_args()[0] + "/shots_gallery"
	DirAccess.make_dir_recursive_absolute(dir)
	img.save_png(dir + "/" + name)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: test_gallery_smoke.gd -- <game_dir>")
		quit(2)
		return
	_main = load("res://main.tscn").instantiate()
	root.add_child(_main)
	await _frames(5)
	# Main's _ready opened the directory picker (no --game-dir in
	# this harness); the test drives start_game directly instead.
	for ch in _main.get_children():
		if ch is FileDialog:
			ch.hide()
	_main.start_game(args[0])
	await _frames(10)
	var fails := 0
	if not _main.gallery.is_open() or _main.gallery.mode() != "title":
		push_error("FAIL title menu not open after package load")
		fails += 1
	_shot("title.png")
	# Scene list: entries exist; enable scene 1 by simulating reach.
	_main._on_gallery_scenes_requested()
	await _frames(5)
	if _main.gallery.mode() != "scenes":
		push_error("FAIL scene list did not open")
		fails += 1
	_shot("scenes.png")
	# Reach tracking must be automatic: clear the store, enter the
	# recollection directly (bypassing the button's enabled gate),
	# and the VM executing the scene's dispatch target must flag it.
	_main._system["reached"].clear()
	_main._on_gallery_recollection(1)
	await _frames(10)
	if not _main._system["reached"].has("1"):
		push_error("FAIL scene 1 not auto-marked reached after entry")
		fails += 1
	if _main._waiting != "say":
		push_error("FAIL recollection did not reach a dialogue line")
		fails += 1
	else:
		var first: Variant = _main._backlog[0] if _main._backlog.size() > 0 else {}
		print("recollection first line: ", first)
		for i in 6:
			_main._advance()
			await _frames(3)
		_shot("recollection.png")
	# Esc navigation: in-game Esc opens the title menu, Esc again
	# (with a live session) closes it back into the game.
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	_main._input(esc)
	await _frames(3)
	if _main.gallery.mode() != "title":
		push_error("FAIL Esc in game did not open title menu")
		fails += 1
	_main._input(esc)
	await _frames(3)
	if _main.gallery.is_open():
		push_error("FAIL Esc at title did not resume the game")
		fails += 1
	# Movie gallery: inject two unlock entries so the list renders
	# real rows, and assert the panel is actually visible — it is
	# opened here from a hidden state (a recollection is playing),
	# which is how the missing-visible bug slipped past mode checks.
	_main._system["movies"]["op.mpg"] = true
	_main._system["movies"]["ev_012.mpg"] = true
	_main._on_gallery_movies_requested()
	await _frames(5)
	if _main.gallery.mode() != "movies":
		push_error("FAIL movie list did not open")
		fails += 1
	if not _main.gallery._root.visible:
		push_error("FAIL movie list opened but panel not visible")
		fails += 1
	if _main.gallery._list.get_child_count() != 2:
		push_error("FAIL movie list rows != 2")
		fails += 1
	_shot("movies.png")
	if fails == 0:
		print("PASS gallery smoke (title/scenes/recollection/movies)")
		quit(0)
	else:
		quit(1)
