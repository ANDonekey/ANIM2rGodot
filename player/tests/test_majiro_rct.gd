extends SceneTree
## MajiroRct oracle test.
## Args: <game_dir> <oracle.json> [max_images]
## The oracle lists {arc, name, w, h, md5} rows produced by the reference
## Python decoder (host: ~/starless/work/rct_oracle/oracle.json); each
## selected image is decoded in GDScript and its RGB md5 compared.

func _md5(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var root: String = args[0]
	var oracle_path: String = args[1]
	var limit := 14
	if args.size() > 2:
		limit = int(args[2])
	var name_filter := ""
	if args.size() > 3:
		name_filter = String(args[3]).to_lower()
	var oracle: Array = JSON.parse_string(FileAccess.get_file_as_string(oracle_path))
	var arcs := {}
	var picked := 0
	var failed := 0
	var kinds := {}
	for row in oracle:
		if picked >= limit:
			break
		if name_filter != "" and not String(row["name"]).to_lower().ends_with(name_filter):
			continue
		var arc_name := String(row["arc"])
		if not arcs.has(arc_name):
			var a := MajiroArc.new()
			if not a.open(root + "/" + arc_name + ".arc"):
				print("cannot open ", arc_name)
				quit(1)
				return
			arcs[arc_name] = a
		var arc: MajiroArc = arcs[arc_name]
		var data := PackedByteArray()
		var want := String(row["name"]).to_lower()
		for i in arc.entry_count():
			if MajiroText.decode_cp932(arc.raw_name(i)).to_lower() == want:
				data = arc.read_at(i)
				break
		var img := MajiroRct.decode(data)
		if img == null:
			print("DECODE NULL ", row["name"])
			failed += 1
			continue
		kinds[img.kind] = int(kinds.get(img.kind, 0)) + 1
		var md5 := _md5(img.rgb)
		var ok := img.width == int(row["w"]) and img.height == int(row["h"]) and md5 == String(row["md5"])
		if not ok:
			print("MISMATCH ", row["name"], " got ", img.width, "x", img.height, " ", md5, " want ", row["md5"])
			failed += 1
		picked += 1
	print("checked ", picked, " images, kinds: ", kinds, ", failed: ", failed)
	print("test_majiro_rct: ", "PASS" if failed == 0 and picked > 0 else "FAIL")
	quit(0 if failed == 0 and picked > 0 else 1)
