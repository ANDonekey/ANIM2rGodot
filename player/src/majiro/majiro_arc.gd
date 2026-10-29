class_name MajiroArc
extends RefCounted
## MajiroArcV3.000 archive reader (Majiro engine).
##
## Layout (verified on STARLESS, see docs/majiro-format.md):
##   +0x00 char[16] "MajiroArcV3.000\0"
##   +0x10 u32 entry_count, +0x14 u32 name_table_offset, +0x18 u32 data_offset
##   +0x1C entry[count] x 16 bytes: {u32 name_hash_lo, u32 name_hash_hi,
##         u32 offset, u32 size}, sorted by the 64-bit name hash
##   name table: CP932 filenames, NUL-separated, same order as entries
##   data region: raw entry bytes
##
## Names are kept as byte-preserving keys (byte value == char code) because
## Godot has no built-in CP932 decoder; the text layer owns CP932 -> Unicode
## conversion. Entry data is read on demand, never whole-archive.

var _f: FileAccess
var _raw_names: Array[PackedByteArray] = []
var _offsets: Array[int] = []
var _sizes: Array[int] = []
var _index: Dictionary = {} # byte-preserving name key -> entry index


static func name_key(raw: PackedByteArray) -> String:
	var chars := PackedStringArray()
	chars.resize(raw.size())
	for i in range(raw.size()):
		chars[i] = char(raw[i])
	return "".join(chars)


func open(path: String) -> bool:
	_f = FileAccess.open(path, FileAccess.READ)
	if _f == null:
		push_error("MajiroArc: cannot open %s" % path)
		return false
	var head := _f.get_buffer(28)
	if head.size() < 28 or head.slice(0, 15).get_string_from_ascii() != "MajiroArcV3.000":
		push_error("MajiroArc: bad magic in %s" % path)
		return false
	var count := head.decode_u32(16)
	var name_off := head.decode_u32(20)
	var data_off := head.decode_u32(24)
	_raw_names.clear()
	_offsets.clear()
	_sizes.clear()
	_index.clear()
	for i in range(count):
		_f.seek(28 + 16 * i)
		var e := _f.get_buffer(16)
		_offsets.append(e.decode_u32(8))
		_sizes.append(e.decode_u32(12))
	_f.seek(name_off)
	var table := _f.get_buffer(data_off - name_off)
	var start := 0
	for i in range(table.size()):
		if table[i] == 0:
			if i > start:
				_raw_names.append(table.slice(start, i))
			start = i + 1
	if _raw_names.size() != count:
		push_error("MajiroArc: name count %d != entry count %d" % [_raw_names.size(), count])
		return false
	for i in range(count):
		_index[name_key(_raw_names[i])] = i
	return true


func entry_count() -> int:
	return _offsets.size()


func raw_name(idx: int) -> PackedByteArray:
	return _raw_names[idx]


func entry_size(idx: int) -> int:
	return _sizes[idx]


func find(prefix: PackedByteArray) -> int:
	for i in range(_raw_names.size()):
		var n := _raw_names[i]
		if n.size() >= prefix.size() and n.slice(0, prefix.size()) == prefix:
			return i
	return -1


func has(name: String) -> bool:
	return _index.has(name)


func read_at(idx: int) -> PackedByteArray:
	_f.seek(_offsets[idx])
	return _f.get_buffer(_sizes[idx])


func read_named(name: String) -> PackedByteArray:
	if not _index.has(name):
		return PackedByteArray()
	return read_at(_index[name])
