extends SceneTree
## Parser verification against the Python baseline for the same sce.
##   godot --headless --path player -s tests/test_parser.gd -- <game_dir> <baseline.json>

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("usage: test_parser.gd -- <game_dir> <baseline.json>")
		quit(2)
		return
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	var pkg := GamePackage.new()
	if not pkg.open(args[0]):
		quit(1)
		return
	var script := SceScript.load_from_bytes(pkg.sce_bytes())
	var fails := 0
	var checks := {
		"records": script.records.size(),
		"labels": script.labels.size(),
		"pool": script.pool_count(),
	}
	for k in checks:
		if checks[k] != int(base[k]):
			push_error("FAIL %s: got %d want %d" % [k, checks[k], int(base[k])])
			fails += 1
	if script.parse_failures.size() != (base["fails"] as Array).size():
		push_error("FAIL parse_failures: got %s want %s" % [str(script.parse_failures), str(base["fails"])])
		fails += 1
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for r in script.records:
		ctx.update(("%d:%d;" % [r.off, r.op]).to_utf8_buffer())
	var chain := ctx.finish().hex_encode()
	if chain != base["chain"]:
		push_error("FAIL chain: got %s want %s" % [chain, base["chain"]])
		fails += 1
	var text_ops := {0xD2: true, 0xD3: true, 0xD4: true, 0xD5: true}
	var n_text := 0
	var n_voiced := 0
	var n_select := 0
	for r in script.records:
		if text_ops.has(r.op):
			n_text += 1
		if r.op == 0xD2:
			n_voiced += 1
		if r.op == 0xC0 or r.op == 0xC8:
			n_select += 1
	if n_text != int(base["text_lines"]) or n_voiced != int(base["voiced"]) or n_select != int(base["selects"]):
		push_error("FAIL counts text=%d voiced=%d select=%d" % [n_text, n_voiced, n_select])
		fails += 1
	if script.charset.mode != "gbk":
		push_error("FAIL charset detection: got %s want gbk" % script.charset.mode)
		fails += 1
	for k in base["pool_samples"]:
		var want: String = base["pool_samples"][k]
		var got := script.pool_str(int(k))
		if got != want:
			push_error("FAIL pool[%s]: got %s want %s" % [k, got, want])
			fails += 1
	if fails == 0:
		print("PASS parser records=", script.records.size(), " charset=", script.charset.mode)
		quit(0)
	else:
		quit(1)
