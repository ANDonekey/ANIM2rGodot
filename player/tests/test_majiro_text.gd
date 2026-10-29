extends SceneTree
## Majiro text decoding verification against codec oracles.
##   godot --headless --path player -s tests/test_majiro_text.gd -- <work_dir>

var _failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL ", label)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: test_majiro_text.gd -- <work_dir>")
		quit(2)
		return
	var oracle: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0].path_join("text_oracle.json")))
	_check(typeof(oracle) == TYPE_ARRAY, "oracle loads")
	if typeof(oracle) != TYPE_ARRAY:
		quit(1)
		return
	var counts := {}
	var bad := 0
	for row in oracle:
		var codec := String(row["codec"])
		counts[codec] = int(counts.get(codec, 0)) + 1
		var bytes := PackedByteArray()
		bytes.resize(String(row["hex"]).length() / 2)
		for i in range(bytes.size()):
			bytes[i] = ("0x" + String(row["hex"]).substr(i * 2, 2)).hex_to_int()
		var got := MajiroText.decode(bytes, codec)
		if got != String(row["dec"]):
			bad += 1
			if bad <= 4:
				printerr("  mismatch [%s]: got '%s' want '%s'" % [codec, got, String(row["dec"])])
	for codec in counts.keys():
		print("  codec %s: %d rows" % [codec, counts[codec]])
	_check(bad == 0, "all oracle strings decode exactly (%d bad)" % bad)
	_check(MajiroText.decode_cp932(PackedByteArray([0x82, 0xA0])) == "あ", "cp932 あ")
	_check(MajiroText.decode_gbk(PackedByteArray([0xD6, 0xD0])) == "中", "gbk 中")
	if _failures == 0:
		print("test_majiro_text: PASS")
		quit(0)
	else:
		printerr("test_majiro_text: %d FAILURES" % _failures)
		quit(1)
