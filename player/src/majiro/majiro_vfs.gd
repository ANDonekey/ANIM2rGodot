class_name MajiroVfs
extends RefCounted
## Majiro package access: MajiroArcV3 containers in the engine's search
## order (docs/majiro-format.md §11): updateCHS -> scenario -> fastdata
## -> data1..4 -> stream -> voice. Scripts (.mjo) resolve from the
## update pack first, then scenario. Entry names are indexed twice:
## decoded (cp932) lower-case for display-side lookups, and raw-bytes
## ascii lower-case because the VM passes script names through an
## ascii decode that mangles non-ascii bytes the same way on both sides.

const ARC_ORDER := ["updateCHS", "scenario", "fastdata", "data1", "data2",
		"data3", "data4", "stream", "voice"]

var game_dir := ""
var has_update := false

var _file_arcs: Array = []   # [{arc, index, name}] in search order
var _script_arcs: Array = [] # subset of _file_arcs holding .mjo
var _script_cache := {}


func open_game(dir: String) -> bool:
	game_dir = dir
	_file_arcs.clear()
	_script_arcs.clear()
	for arc_name in ARC_ORDER:
		var arc := MajiroArc.new()
		if not arc.open(dir.path_join(arc_name + ".arc")):
			continue
		var index := {}
		for i in range(arc.entry_count()):
			var raw := arc.raw_name(i)
			index[MajiroText.decode_cp932(raw).to_lower()] = i
			index[raw.get_string_from_ascii().to_lower()] = i
		var rec := {"arc": arc, "index": index, "name": arc_name}
		_file_arcs.append(rec)
		if arc_name == "updateCHS":
			has_update = true
			_script_arcs.append(rec)
		elif arc_name == "scenario":
			_script_arcs.append(rec)
	return not _file_arcs.is_empty()


func read_file(fname: String) -> PackedByteArray:
	var key := fname.to_lower()
	for rec in _file_arcs:
		var index: Dictionary = rec["index"]
		if index.has(key):
			return (rec["arc"] as MajiroArc).read_at(int(index[key]))
	return PackedByteArray()


## Lookup by raw name bytes (script string operands): decode for the
## display index, then fall back to the ascii-mangled key.
func read_file_bytes(raw_name: PackedByteArray) -> PackedByteArray:
	var by_decoded := read_file(MajiroText.decode_cp932(raw_name))
	if not by_decoded.is_empty():
		return by_decoded
	return read_file(raw_name.get_string_from_ascii())


func file_exists(fname: String) -> bool:
	var key := fname.to_lower()
	for rec in _file_arcs:
		if (rec["index"] as Dictionary).has(key):
			return true
	return false


## VM vfs callable: (script_name_without_extension) -> MajiroMjo or null.
func load_script(script_name: String) -> Variant:
	if _script_cache.has(script_name):
		return _script_cache[script_name]
	var key := (script_name + ".mjo").to_lower()
	var bytes := PackedByteArray()
	for rec in _script_arcs:
		var index: Dictionary = rec["index"]
		if index.has(key):
			bytes = (rec["arc"] as MajiroArc).read_at(int(index[key]))
			break
	var result: Variant = null
	if not bytes.is_empty():
		var mjo := MajiroMjo.new()
		if mjo.load(bytes):
			result = mjo
	_script_cache[script_name] = result
	return result
