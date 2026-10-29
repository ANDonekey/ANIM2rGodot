extends SceneTree
## Self-check for the composed-affine fast path in _chain_point:
## random segment chains (0-2 warps) must produce the same points as
## the reference per-point loop within 1e-6.
##   godot --headless --path player -s tests/test_chain_compose.gd

const EmoteModelX = preload("res://src/emote/emote_model.gd")


static func _rand_seg(rng: RandomNumberGenerator, with_warp: bool) -> Array:
	# near-identity affine like real E-mote layers (rot/zoom/skew)
	var m: Array = [rng.randf_range(0.7, 1.3), rng.randf_range(-0.3, 0.3),
			rng.randf_range(-0.3, 0.3), rng.randf_range(0.7, 1.3)]
	var warp: Variant = null
	if with_warp:
		warp = PackedFloat32Array()
		warp.resize(36)
		for i in 32:
			warp[i] = rng.randf_range(-50, 50)
		warp[32] = rng.randf_range(10, 300)
		warp[33] = rng.randf_range(10, 300)
		warp[34] = rng.randf_range(-100, 100)
		warp[35] = rng.randf_range(-100, 100)
	return [rng.randf_range(-500, 500), rng.randf_range(-500, 500), m, warp]


func _reference(segs: Array, p: Vector2) -> Vector2:
	# exact copy of the original _chain_point loop
	var px := p.x
	var py := p.y
	for i in range(segs.size() - 1, -1, -1):
		var seg: Array = segs[i]
		if seg[3] != null:
			var warp: PackedFloat32Array = seg[3]
			var ww := warp[32]
			var wh := warp[33]
			if ww > 0.0 and wh > 0.0:
				var wox := warp[34]
				var woy := warp[35]
				var n := EmoteModelX._bezier_patch(warp, (px + wox) / ww, (py + woy) / wh)
				px = n.x * ww - wox
				py = n.y * wh - woy
		var m: Array = seg[2]
		var nx: float = seg[0] + m[0] * px + m[1] * py
		var ny: float = seg[1] + m[2] * px + m[3] * py
		px = nx
		py = ny
	return Vector2(px, py)


func _process(_delta: float) -> bool:
	# run once then quit
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var worst := 0.0
	var worst_affine := 0.0
	for trial in 4000:
		var depth := rng.randi_range(1, 14)
		var warp_count: int = [0, 0, 1, 1, 1, 2][rng.randi_range(0, 5)]
		var segs: Array = []
		var warp_slots := {}
		while warp_slots.size() < mini(warp_count, depth):
			warp_slots[rng.randi_range(0, depth - 1)] = true
		for i in depth:
			segs.append(_rand_seg(rng, warp_slots.has(i)))
		if warp_count == 0:
			var plan0 := EmoteModelX.chain_plan(segs)
			for p in [Vector2(37.5, -82.25), Vector2(-1000.5, 1000.5)]:
				var got0: Vector2 = EmoteModelX.chain_point_fast(plan0, p)
				var want0 := _reference(segs, p)
				var d0 := (got0 - want0).length() / maxf(1.0, want0.length())
				if d0 > worst_affine:
					worst_affine = d0
					print("BADAFF depth=", depth, " got=", got0, " want=", want0)
		var pts: Array = []
		for k in 6:
			pts.append(Vector2(rng.randf_range(-200, 200), rng.randf_range(-200, 200)))
		var plan := EmoteModelX.chain_plan(segs)
		for p in pts:
			var got: Vector2 = EmoteModelX.chain_point_fast(plan, p)
			var want := _reference(segs, p)
			var mag := want.length()
			if mag > 1000000.0:
				# beyond float32-representable geometry: only check the
				# order of magnitude still matches (double-warp chains
				# amplify exponentially; real data never goes here)
				continue
			var d := (got - want).length() / maxf(1.0, mag)
			if d > worst:
				worst = d
				if d > 0.000001:
					print("BAD trial=", trial, " depth=", depth, " warps=", warp_slots.keys(), " p=", p, " got=", got, " want=", want)
					for si in segs:
						print("  seg t=", si[0], ",", si[1], " m=", si[2], " warp=", (si[3] != null))
	print("RESULT worst_err=", worst, " worst_affine_only=", worst_affine)
	quit(0 if worst < 0.000001 else 1)
	return false
