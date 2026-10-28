extends SceneTree
## Recollection verification: SceScript.recollection_table() must find
## the CheckMemory dispatch chain, and a VM booted with
## recollection_request = k must reproduce the canonical event stream
## starting at scene k's entry (the original engine's semantics,
## established against the Python oracle on 2026-10-28).
##   godot --headless --path player -s tests/test_recollection.gd -- <game_dir>


func _run_lines(sce: SceScript, request: int, cap: int) -> Array:
	var vm := ScriptVM.new(sce)
	vm.virtual_clock = true
	vm.recollection_request = request
	var lines: Array = []
	var guard := 0
	while guard < 200000 and lines.size() < cap:
		guard += 1
		var ev := vm.run_until_event()
		vm.drain_effects()
		match ev["kind"]:
			"say":
				lines.append("say|%s|%s" % [ev["speaker"], ev["text"]])
			"narrate":
				lines.append("nar|%s" % ev["text"])
			"choice":
				vm.choose(0)
			"end":
				break
			_:
				break
	return lines


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: test_recollection.gd -- <game_dir>")
		quit(2)
		return
	var pkg := GamePackage.new()
	if not pkg.open(args[0]):
		quit(1)
		return
	var sce := SceScript.load_from_bytes(pkg.sce_bytes())
	var fails := 0
	var table := sce.recollection_table()
	if table.size() != 77:
		push_error("FAIL table size: got %d want 77" % table.size())
		fails += 1
	var prev := -1
	for e in table:
		if int(e["target"]) <= prev:
			push_error("FAIL table targets not increasing at value %d" % int(e["value"]))
			fails += 1
			break
		prev = int(e["target"])
	if fails == 0:
		# Canonical prefix vs the scene-1 run: identical streams, the
		# recollection run being a strict suffix-slice of the canon.
		var canon := _run_lines(sce, 0, 2000)
		var recol := _run_lines(sce, 1, 600)
		if recol.is_empty() or canon.size() < 400:
			push_error("FAIL stream sizes canon=%d recol=%d" % [canon.size(), recol.size()])
			fails += 1
		else:
			var at: int = canon.find(recol[0])
			if at < 0:
				push_error("FAIL recollection head not in canon: " + recol[0])
				fails += 1
			elif at + recol.size() > canon.size():
				push_error("FAIL canon too short for slice: at=%d recol=%d canon=%d"
						% [at, recol.size(), canon.size()])
				fails += 1
			else:
				for i in recol.size():
					if canon[at + i] != recol[i]:
						push_error("FAIL slice diverges at +%d" % i)
						fails += 1
						break
				var pv := sce.preview_line(int(table[1]["target"]))
				if pv.is_empty() or pv["speaker"] == "":
					push_error("FAIL preview_line for scene 1: " + str(pv))
					fails += 1
	if fails == 0:
		print("PASS recollection entries=", table.size(),
				" scene1_head_matches_canon_slice")
		quit(0)
	else:
		quit(1)
