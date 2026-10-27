class_name GFilePack
extends RefCounted
## GFilePack reader (voice .pck and cg/psbpack.dat share the format):
##   [u32 count][count x (u32 zero, u32 offset, u32 size)]
##   [NUL-terminated ASCII name table][blobs at absolute offsets]
##
## Only the header (index + names) is read at open; entries are fetched
## on demand with seek+read, so 1 GB packs cost a few hundred KB of RAM.

var _f: FileAccess
var names: Array[String] = []
var _index: Dictionary = {}  # lowercase name -> [offset, size]


static func open(path: String) -> GFilePack:
	var p := GFilePack.new()
	p._f = FileAccess.open(path, FileAccess.READ)
	if p._f == null:
		push_error("GFilePack: cannot open " + path)
		return null
	var count := int(p._f.get_32())
	var entries: Array = []
	entries.resize(count)
	for i in count:
		p._f.get_32()  # zero field
		var off := int(p._f.get_32())
		var size := int(p._f.get_32())
		entries[i] = [off, size]
	for i in count:
		var buf := PackedByteArray()
		while true:
			var ch := p._f.get_8()
			if ch == 0 or p._f.eof_reached():
				break
			buf.append(ch)
		var nm := buf.get_string_from_ascii()
		p.names.append(nm)
		p._index[nm.to_lower()] = entries[i]
	return p


func entry_count() -> int:
	return names.size()


func has(name: String) -> bool:
	return _index.has(name.to_lower())


func get_entry(name: String) -> PackedByteArray:
	var e: Variant = _index.get(name.to_lower())
	if e == null:
		return PackedByteArray()
	_f.seek(e[0])
	return _f.get_buffer(e[1])
