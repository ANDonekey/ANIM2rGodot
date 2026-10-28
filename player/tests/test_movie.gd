extends SceneTree
## Movie path check: open an online package, download one transcoded
## movie and verify VideoStreamTheora actually plays it.
## Usage: godot --headless --path. -s tests/test_movie.gd -- <pkg_base_url> [movie_name]

var _failed := false


func _fail(msg: String) -> void:
	_failed = true
	print("FAIL movie: ", msg)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 1:
		print("usage: test_movie.gd -- <pkg_base_url> [movie_name]")
		quit(2)
		return
	var base: String = args[0]
	var movie_name: String = args[1] if args.size() > 1 else "op.mpg"
	# HTTPRequest needs its node inside the tree; during _initialize
	# the root is not yet, so start on the first frame.
	process_frame.connect(func() -> void: _run(base, movie_name), CONNECT_ONE_SHOT)


func _run(base: String, movie_name: String) -> void:
	var source := WebSource.new()
	root.add_child(source)
	var pkg := GamePackage.new()
	if not await pkg.open_web(source, base):
		_fail("open_web failed")
		quit(1)
		return
	var path: String = await pkg.ensure_movie(movie_name)
	if path == "":
		_fail("ensure_movie returned empty for " + movie_name)
		quit(1)
		return
	var stream := VideoStreamTheora.new()
	stream.file = path
	var player := VideoStreamPlayer.new()
	player.stream = stream
	root.add_child(player)
	player.play()
	var t := 0.0
	while t < 5.0 and not player.is_playing():
		await create_timer(0.2).timeout
		t += 0.2
	if not player.is_playing():
		_fail("VideoStreamPlayer not playing")
		quit(1)
		return
	await create_timer(2.0).timeout
	var pos := player.stream_position
	if pos < 0.5:
		_fail("stream position did not advance: %f" % pos)
		quit(1)
		return
	print("PASS movie %s pos=%.2f len=%.2f" % [movie_name, pos, player.get_stream_length()])
	quit(0)
