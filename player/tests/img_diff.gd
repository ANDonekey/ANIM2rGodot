extends SceneTree
## Compare a crop of two screenshots (blend on vs off): mean abs diff per
## channel over the face region tells whether multiply shading is applied.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var a := Image.load_from_file(args[0])
	var b := Image.load_from_file(args[1])
	var x0 := int(args[2])
	var y0 := int(args[3])
	var x1 := int(args[4])
	var y1 := int(args[5])
	var da := a.get_region(Rect2i(x0, y0, x1 - x0, y1 - y0))
	var db := b.get_region(Rect2i(x0, y0, x1 - x0, y1 - y0))
	var n := da.get_width() * da.get_height()
	var sums := [0.0, 0.0, 0.0]
	var changed := 0
	for yy in da.get_height():
		for xx in da.get_width():
			var ca := da.get_pixel(xx, yy)
			var cb := db.get_pixel(xx, yy)
			if ca != cb:
				changed += 1
			sums[0] += absf(ca.r - cb.r)
			sums[1] += absf(ca.g - cb.g)
			sums[2] += absf(ca.b - cb.b)
	print("RESULT changed=%d/%d mean=(%.5f %.5f %.5f)" % [changed, n,
			sums[0] / n, sums[1] / n, sums[2] / n])
	quit(0)
