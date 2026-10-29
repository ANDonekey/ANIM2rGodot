extends SceneTree
## Majiro instruction decoder verification against majiro-py oracles.
##   godot --headless --path player -s tests/test_majiro_decode.gd -- <game_dir> <work_dir>
## The oracle JSONs in <work_dir> (oracle_calendar.json, oracle_sta012b13.json)
## were produced by the reference disassembler from the same .mjo files.

var _failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL ", label)


func _run_one(arc: MajiroArc, prefix: String, oracle_path: String, label: String) -> void:
	var idx := arc.find(prefix.to_ascii_buffer())
	_check(idx >= 0, label + ": script found")
	if idx < 0:
		return
	var mjo := MajiroMjo.new()
	_check(mjo.load(arc.read_at(idx)), label + ": mjo loads")
	var oracle: Variant = JSON.parse_string(FileAccess.get_file_as_string(oracle_path))
	_check(typeof(oracle) == TYPE_ARRAY, label + ": oracle loads")
	if typeof(oracle) != TYPE_ARRAY:
		return
	var want := {}
	for row in oracle:
		want[int(row["off"])] = row
	var offs: Array = []
	for f in mjo.functions:
		offs.append(int(f["offset"]))
	offs.sort()
	var got := {}
	for fi in range(offs.size()):
		var start: int = offs[fi]
		var stop: int = mjo.code.size() if fi == offs.size() - 1 else offs[fi + 1]
		var pos: int = start
		while pos < stop:
			var d := MajiroInsn.decode(mjo.code, pos)
			got[pos] = d
			if int(d["size"]) <= 0:
				break
			pos += int(d["size"])
	_check(got.size() == want.size(), "%s: instruction count mine=%d oracle=%d" % [label, got.size(), want.size()])
	var bad := 0
	for off in want.keys():
		if not got.has(off):
			bad += 1
			if bad <= 5:
				printerr("  missing at 0x%x (%s)" % [off, String(want[off].get("op", "?"))])
			continue
		var d: Dictionary = got[off]
		var w: Dictionary = want[off]
		var diffs: Array = []
		if int(d["op"]) != int(w["op"]):
			diffs.append("op")
		if int(d["size"]) != int(w["size"]):
			diffs.append("size")
		if int(d["hash"]) != int(w["hash"]):
			diffs.append("hash")
		if int(d["voff"]) != int(w["voff"]):
			diffs.append("voff")
		if int(d["iv"]) != int(w["iv"]):
			diffs.append("iv")
		if abs(float(d["fv"]) - float(w["fv"])) > 0.000001:
			diffs.append("fv")
		if int(d["ac"]) != int(w["ac"]):
			diffs.append("ac")
		if int(d["ln"]) != int(w["ln"]):
			diffs.append("ln")
		if int(d["jo"]) != int(w["jo"]):
			diffs.append("jo")
		var wt: Variant = w["tl"]
		var wtypes: Array = []
		if typeof(wt) == TYPE_ARRAY:
			for x in wt:
				wtypes.append(int(x))
		if d["types"] != wtypes:
			diffs.append("types")
		var ws: Variant = w["s"]
		var whex: String = ws if typeof(ws) == TYPE_STRING else ""
		if (d["sraw"] as PackedByteArray).hex_encode() != whex:
			diffs.append("sraw")
		if not diffs.is_empty():
			bad += 1
			if bad <= 5:
				printerr("  diff at 0x%x fields %s" % [off, ",".join(diffs)])
	_check(bad == 0, "%s: all instructions match oracle (%d diffs)" % [label, bad])


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("usage: test_majiro_decode.gd -- <game_dir> <work_dir>")
		quit(2)
		return
	var arc := MajiroArc.new()
	_check(arc.open(args[0].path_join("scenario.arc")), "scenario.arc opens")
	_run_one(arc, "calendar", args[1].path_join("oracle_calendar.json"), "calendar")
	_run_one(arc, "sta012b13_", args[1].path_join("oracle_sta012b13.json"), "sta012b13")
	if _failures == 0:
		print("test_majiro_decode: PASS")
		quit(0)
	else:
		printerr("test_majiro_decode: %d FAILURES" % _failures)
		quit(1)
