extends SceneTree
## PSB + E-mote evaluator verification against the Python baseline:
## part lists for three (model, pose) cases must match geometry,
## including v2 warp grids and stencil clip geometry.
##   godot --headless --path player -s tests/test_emote.gd -- <game_dir> <baseline_emote.json>

const TOL := 0.02
const TOL_M := 0.0002


func _close(a: float, b: float, tol: float) -> bool:
	return abs(a - b) <= tol


func _flat_pts(pts: Array) -> Array:
	var out := []
	for p in pts:
		out.append(p.x)
		out.append(p.y)
	return out


func _flat_close(got: Array, want: Array, tol: float) -> bool:
	if got.size() != want.size():
		return false
	for i in got.size():
		if not _close(float(got[i]), float(want[i]), tol):
			return false
	return true


func _clip_summary(geoms: Array) -> Array:
	var out := []
	for g in geoms:
		var kind := "tex"
		var size := []
		if g.has("blank"):
			kind = "blank"
			size = [int(g["blank"][0]), int(g["blank"][1])]
		else:
			var r: Rect2i = g["rect"]
			size = [r.size.x, r.size.y]
		out.append({"kind": kind, "size": size, "opa": int(g["opa"]),
				"grid": _flat_pts(g["grid"]), "grid_n": int(g["grid_n"])})
	return out


func _clip_eq(got: Array, want: Array) -> bool:
	if got.size() != want.size():
		return false
	for i in got.size():
		var g: Dictionary = got[i]
		var w: Dictionary = want[i]
		if g["kind"] != w["kind"] or g["opa"] != int(w["opa"]) or g["grid_n"] != int(w["grid_n"]):
			return false
		if g["size"][0] != int(w["size"][0]) or g["size"][1] != int(w["size"][1]):
			return false
		if not _flat_close(g["grid"], w["grid"], TOL):
			return false
	return true


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("usage: test_emote.gd -- <game_dir> <baseline_emote.json>")
		quit(2)
		return
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	var pkg := GamePackage.new()
	if not pkg.open(args[0]):
		quit(1)
		return
	var define := DefineTable.parse(pkg.define_bytes())
	var fails := 0
	if define.poses.size() != 177:
		push_error("FAIL poses: got %d want 177" % define.poses.size())
		fails += 1
	var cases := [["Mchina110", ""], ["Mchina110", "em114"], ["Mhide208a", "em201"]]
	for c in cases:
		var key: String = c[0] + "|" + (c[1] if c[1] != "" else "None")
		var model := EmoteModel.from_psb(Psb.parse(pkg.psb_bytes(c[0])))
		var vars_: Dictionary = define.pose_vars(c[1]) if c[1] != "" else {}
		var parts := model.collect(model.base_chara(), model.base_motion(), vars_)
		var want: Dictionary = base[key]
		if parts.size() != int(want["count"]):
			push_error("FAIL %s count: got %d want %d" % [key, parts.size(), int(want["count"])])
			fails += 1
			continue
		var wp: Array = want["parts"]
		for i in parts.size():
			var g: Dictionary = parts[i]
			var w: Dictionary = wp[i]
			var ok: bool = g["label"] == w["label"] and g["opa"] == int(w["opa"]) and g["vis"] == w["vis"]
			ok = ok and _close(g["x"], w["x"], TOL) and _close(g["y"], w["y"], TOL) and _close(g["z"], w["z"], TOL)
			ok = ok and _close(g["ox"], w["ox"], TOL) and _close(g["oy"], w["oy"], TOL)
			for j in 4:
				ok = ok and _close(g["m"][j], w["m"][j], TOL_M)
			ok = ok and g["grid_n"] == int(w["grid_n"])
			ok = ok and _flat_close(_flat_pts(EmoteModel.part_corners(g)), w["corners"], TOL)
			if int(w["grid_n"]) > 1:
				ok = ok and _flat_close(_flat_pts(g["grid"]), w["grid"], TOL)
			ok = ok and _clip_eq(_clip_summary(g["clip"]), w["clip"])
			if not ok:
				push_error("FAIL %s part %d: got label=%s grid_n=%s clip=%d want label=%s grid_n=%s clip=%d" % [
					key, i, g["label"], g["grid_n"], (g["clip"] as Array).size(),
					w["label"], w["grid_n"], (w["clip"] as Array).size()])
				fails += 1
				break
	if fails == 0:
		print("PASS emote poses=", define.poses.size())
		quit(0)
	else:
		quit(1)
