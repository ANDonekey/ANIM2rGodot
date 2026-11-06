extends SceneTree
## Compare two screenshots: mean absolute per-channel difference over
## the overlapping area after resizing B to A. Prints stats; exit 0
## always (the caller judges the numbers).
##   godot --headless --path player -s tests/check_shot.gd -- <a.png> <b.png>

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("usage: check_shot.gd -- <a.png> <b.png>")
		quit(2)
		return
	var a := Image.load_from_file(args[0])
	var b := Image.load_from_file(args[1])
	if a == null or b == null:
		printerr("check_shot: load failed")
		quit(1)
		return
	print("sizes: A=", a.get_size(), " B=", b.get_size())
	if b.get_size() != a.get_size():
		b.resize(a.get_width(), a.get_height(), Image.INTERPOLATE_NEAREST)
	a.convert(Image.FORMAT_RGBA8)
	b.convert(Image.FORMAT_RGBA8)
	var da := a.get_data()
	var db := b.get_data()
	var total := 0.0
	var exact := 0
	var npix := a.get_width() * a.get_height()
	for i in range(0, da.size(), 4):
		var d0 := absi(da[i] - db[i])
		var d1 := absi(da[i + 1] - db[i + 1])
		var d2 := absi(da[i + 2] - db[i + 2])
		total += float(d0 + d1 + d2) / 3.0
		if d0 + d1 + d2 == 0:
			exact += 1
	print("mean_abs_diff=%.3f exact_pixels=%.1f%%" % [total / npix, 100.0 * float(exact) / float(npix)])
	quit(0)
