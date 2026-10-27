extends SceneTree
## VM verification: autoplay (always first option, virtual clock) must
## reproduce the independent Python oracle's canonical event stream
## exactly.   godot --headless --path player -s tests/test_vm.gd -- <game_dir> <oracle.json>

func _canon_effect(e: Dictionary) -> String:
	match e["kind"]:
		"image": return "fx|image|%s" % e["name"]
		"movie": return "fx|movie|%s" % e["name"]
		"bgm_play": return "fx|bgm_play|%d" % e["track"]
		"bgm_stop": return "fx|bgm_stop"
		"voice_play": return "fx|voice_play|%s" % e["name"]
		"emote_load": return "fx|emote_load|%d|%s" % [e["slot"], e["name"]]
		"emote_unload": return "fx|emote_unload|%d" % e["slot"]
		"emote_load_hc": return "fx|emote_load_hc|%d|%s" % [e["slot"], e["name"]]
		"emote_pose": return "fx|emote_pose|%d|%s|%d" % [e["slot"], e["label"], e["time"]]
		"snapshot": return "fx|snapshot|%d" % e["slot"]
		"paramset": return "fx|paramset|%d|%d" % [e["id"], e["value"]]
		"select_broken": return "fx|select_broken"
	return ""  # non-canonical effects are stage-only


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("usage: test_vm.gd -- <game_dir> <oracle.json>")
		quit(2)
		return
	var oracle: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	var pkg := GamePackage.new()
	if not pkg.open(args[0]):
		quit(1)
		return
	var vm := ScriptVM.new(SceScript.load_from_bytes(pkg.sce_bytes()))
	vm.virtual_clock = true
	var lines: Array[String] = []
	var n_say := 0
	var n_nar := 0
	var n_choice := 0
	var guard := 0
	while guard < 200000:
		guard += 1
		var ev := vm.run_until_event()
		for e in vm.drain_effects():
			var c := _canon_effect(e)
			if c != "":
				lines.append(c)
		match ev["kind"]:
			"say":
				lines.append("say|%s|%s|%s" % [ev["speaker"], ev["text"], ev["voice"]])
				n_say += 1
			"narrate":
				lines.append("nar|%s" % ev["text"])
				n_nar += 1
			"choice":
				var vals: Array = []
				for o in ev["options"]:
					vals.append(str(o["value"]))
				lines.append("choice|" + ",".join(vals))
				n_choice += 1
				vm.choose(0)
			"end":
				break
			_:
				push_error("FAIL unexpected event: " + str(ev))
				quit(1)
				return
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("\n".join(lines).to_utf8_buffer())
	var chain := ctx.finish().hex_encode()
	var fails := 0
	if lines.size() != int(oracle["events"]):
		push_error("FAIL events: got %d want %d" % [lines.size(), int(oracle["events"])])
		fails += 1
	if chain != oracle["chain"]:
		push_error("FAIL chain: got %s want %s" % [chain, oracle["chain"]])
		fails += 1
	if n_say != int(oracle["say"]) or n_nar != int(oracle["nar"]) or n_choice != int(oracle["choice"]):
		push_error("FAIL counts say=%d nar=%d choice=%d" % [n_say, n_nar, n_choice])
		fails += 1
	if fails == 0:
		print("PASS vm events=", lines.size(), " say=", n_say, " nar=", n_nar, " choice=", n_choice)
		quit(0)
	else:
		# Locate first divergence for diagnosis.
		for i in mini(lines.size(), 6):
			print("  got[", i, "] ", lines[i])
		quit(1)
