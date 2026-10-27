extends SceneTree
## Loader verification against a real package directory.
##   godot --headless --path player -s tests/test_loader.gd -- <game_dir>
## Expected values are the Python-baseline facts for the sample package
## (kabe2 GPT): cg 1016, psb 69, voice 12722, bgm 11, movie 78, plus
## SHA256 spot checks computed with the Python reference implementations.

const EXPECT := {
	"cg": 1016, "psb": 69, "voice": 12722, "bgm": 11, "movie": 78,
}
const HASH_MCHINA110 := "8d17d9e428212719aaeeb7fae36e3287d157118257863e02e251c1e7adf1fc33"
const HASH_VOICE := "58d2cfc25ee203cb88ad0312bc4c7d36334d953848674a63132d57d5b7861a70"
const HASH_BG110 := "7b9366721876b7b599621dd92c021d2e0ac2d9386c91df78a402b20ed0a6af48"


func _sha(b: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(b)
	return ctx.finish().hex_encode()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: test_loader.gd -- <game_dir>")
		quit(2)
		return
	var pkg := GamePackage.new()
	if not pkg.open(args[0]):
		push_error("open failed")
		quit(1)
		return
	var fails := 0
	var got := {
		"cg": pkg.cg_count(), "psb": pkg.psb_count(), "voice": pkg.voice_count(),
		"bgm": pkg.bgm_count(), "movie": pkg.movie_count(),
	}
	for k in EXPECT:
		if got[k] != EXPECT[k]:
			push_error("FAIL %s: got %d want %d" % [k, got[k], EXPECT[k]])
			fails += 1
	if _sha(pkg.psb_bytes("Mchina110")) != HASH_MCHINA110:
		push_error("FAIL psb bytes hash")
		fails += 1
	if _sha(pkg.voice_bytes("w000001a")) != HASH_VOICE:
		push_error("FAIL voice bytes hash")
		fails += 1
	if _sha(pkg.image_bytes("BG110")) != HASH_BG110:
		push_error("FAIL image bytes hash")
		fails += 1
	if pkg.sce_bytes().size() != 2054861:
		push_error("FAIL sce size: %d" % pkg.sce_bytes().size())
		fails += 1
	if fails == 0:
		print("PASS loader counts=", got)
		quit(0)
	else:
		quit(1)
