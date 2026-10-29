extends SceneTree
## Whole-corpus decoder sweep: every .mjo in scenario.arc + updateCHS.arc
## must decode function-by-function with exact span consumption (no desync,
## no unknown opcodes, no zero-size instructions).
##   godot --headless --path player -s tests/test_majiro_corpus.gd -- <game_dir>

var _failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL ", label)


func _sweep(arc_path: String, label: String) -> void:
	var arc := MajiroArc.new()
	if not arc.open(arc_path):
		_check(false, label + ": arc opens")
		return
	var scripts := 0
	var insns := 0
	var bad := 0
	for idx in range(arc.entry_count()):
		var nm := arc.raw_name(idx)
		if not String(nm.get_string_from_ascii()).ends_with(".mjo"):
			continue
		scripts += 1
		var mjo := MajiroMjo.new()
		if not mjo.load(arc.read_at(idx)):
			bad += 1
			printerr("  load fail: ", nm.get_string_from_ascii())
			continue
		var offs: Array = []
		for f in mjo.functions:
			offs.append(int(f["offset"]))
		offs.sort()
		for fi in range(offs.size()):
			var start: int = offs[fi]
			var stop: int = mjo.code.size() if fi == offs.size() - 1 else offs[fi + 1]
			var pos: int = start
			while pos < stop:
				var d := MajiroInsn.decode(mjo.code, pos)
				insns += 1
				if int(d["size"]) <= 0 or not MajiroInsn.known(int(d["op"])):
					bad += 1
					printerr("  desync/unknown at %s +0x%x op 0x%03x" % [nm.get_string_from_ascii(), pos, int(d["op"])])
					pos = stop
					break
				pos += int(d["size"])
			if pos != stop:
				bad += 1
				printerr("  span mismatch %s func 0x%x: end 0x%x != 0x%x" % [nm.get_string_from_ascii(), start, pos, stop])
	_check(bad == 0, "%s: %d scripts, %d instructions, 0 desyncs" % [label, scripts, insns])


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: test_majiro_corpus.gd -- <game_dir>")
		quit(2)
		return
	_sweep(args[0].path_join("scenario.arc"), "scenario")
	_sweep(args[0].path_join("updateCHS.arc"), "updateCHS")
	if _failures == 0:
		print("test_majiro_corpus: PASS")
		quit(0)
	else:
		printerr("test_majiro_corpus: %d FAILURES" % _failures)
		quit(1)
