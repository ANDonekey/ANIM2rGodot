extends SceneTree
## Majiro loader verification against the STARLESS package directory.
##   godot --headless --path player -s tests/test_majiro.gd -- <game_dir>
## Expected values are the measured facts for the sample package:
## scenario.arc 252 entries, updateCHS.arc 234, voice.arc 15540; the
## sta012b13 script decrypts to code containing the "bg13" resource string
## and its entrypoint function hash is 0x1D128F30.

var _failures := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		print("ok   ", label)
	else:
		_failures += 1
		printerr("FAIL ", label)


func _contains(hay: PackedByteArray, needle: PackedByteArray) -> bool:
	if needle.size() == 0 or hay.size() < needle.size():
		return false
	for i in range(hay.size() - needle.size() + 1):
		if hay[i] != needle[0]:
			continue
		var is_match := true
		for j in range(1, needle.size()):
			if hay[i + j] != needle[j]:
				is_match = false
				break
		if is_match:
			return true
	return false


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: test_majiro.gd -- <game_dir>")
		quit(2)
		return
	var dir := args[0]

	var scenario := MajiroArc.new()
	_check(scenario.open(dir.path_join("scenario.arc")), "scenario.arc opens")
	_check(scenario.entry_count() == 252, "scenario.arc has 252 entries (got %d)" % scenario.entry_count())

	var chs := MajiroArc.new()
	_check(chs.open(dir.path_join("updateCHS.arc")), "updateCHS.arc opens")
	_check(chs.entry_count() == 234, "updateCHS.arc has 234 entries (got %d)" % chs.entry_count())

	var voice := MajiroArc.new()
	_check(voice.open(dir.path_join("voice.arc")), "voice.arc opens")
	_check(voice.entry_count() == 15540, "voice.arc has 15540 entries (got %d)" % voice.entry_count())

	var idx := scenario.find("sta012b13_".to_ascii_buffer())
	_check(idx >= 0, "sta012b13 script found in scenario.arc")
	if idx >= 0:
		var mjo := MajiroMjo.new()
		_check(mjo.load(scenario.read_at(idx)), "sta012b13 .mjo loads")
		_check(mjo.functions.size() >= 1, "function table parsed (%d functions)" % mjo.functions.size())
		if mjo.functions.size() >= 1:
			_check(mjo.functions[0]["hash"] == 0x1D128F30, "entrypoint hash is 0x1D128F30 (got 0x%08x)" % mjo.functions[0]["hash"])
		_check(_contains(mjo.code, "bg13".to_ascii_buffer()), "decrypted code contains ldstr \"bg13\"")
		_check(_contains(mjo.code, "SE099".to_ascii_buffer()), "decrypted code contains SE099 cue name")

	if _failures == 0:
		print("test_majiro: PASS")
		quit(0)
	else:
		printerr("test_majiro: %d FAILURES" % _failures)
		quit(1)
