extends SceneTree
## Headless byte-equality test for the GSecret port.
##
## Usage:
##   godot --headless --path player -s tests/test_gsecret.gd -- <encrypted> <expected_sha256>
## The expected hash comes from the Python reference implementation
## (reference/python/anim_gsecret.py) run on the same file.
## Exit code 0 and "PASS" on stdout when the outputs match byte-for-byte.


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("usage: test_gsecret.gd -- <encrypted> <expected_sha256>")
		quit(2)
		return
	var data := FileAccess.get_file_as_bytes(args[0])
	if data.is_empty():
		push_error("cannot read input: " + args[0])
		quit(2)
		return
	var plain := GSecret.decrypt(data)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(plain)
	var got := ctx.finish().hex_encode()
	if got == args[1]:
		print("PASS sha256=", got, " bytes=", plain.size())
		quit(0)
	else:
		push_error("FAIL got=" + got + " want=" + args[1])
		quit(1)
