class_name MajiroInsn
extends RefCounted
## Majiro bytecode instruction decoder (MajiroObjX/V code streams).
##
## Operand layout follows each opcode's encoding string, byte-for-byte with
## the reference disassembler (docs/majiro-format.md):
##   t: u16 count + count x u8 type codes       s: u16 byte length (incl. NUL) + raw bytes
##   f: u16 flags                               h: u32 name hash
##   o: i16 variable offset (-2 = array length) 0: u32 placeholder (call-site cache slot)
##   i: i32 int constant                        r: f32 float constant
##   a: u16 argument count                      j: i32 relative jump offset
##   l: u16 source line number                  c: u16 count + count x i32 switch offsets
##
## Decoded strings stay raw bytes ("sraw", without the trailing NUL): the
## text layer owns CP932/GBK conversion.

const TABLE_PATH := "res://src/majiro/majiro_opcodes.json"

static var _table: Dictionary = {}


static func _ensure_table() -> void:
	if not _table.is_empty():
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(TABLE_PATH))
	if typeof(parsed) == TYPE_DICTIONARY:
		for k in parsed.keys():
			_table[int(k)] = parsed[k]


static func mnemonic(op: int) -> String:
	_ensure_table()
	var row: Variant = _table.get(op)
	if row == null:
		return "op.%03x" % op
	return String(row["mn"])


static func encoding(op: int) -> String:
	_ensure_table()
	var row: Variant = _table.get(op)
	if row == null:
		return ""
	return String(row["enc"])


static func known(op: int) -> bool:
	_ensure_table()
	return _table.has(op)


static func decode(code: PackedByteArray, at: int) -> Dictionary:
	var op := code.decode_u16(at)
	var enc := encoding(op)
	var pos := at + 2
	var d := {
		"op": op, "mn": mnemonic(op), "flags": 0, "hash": 0, "voff": 0,
		"iv": 0, "fv": 0.0, "ac": 0, "ln": 0, "jo": 0, "aux": 0,
		"types": [], "sraw": PackedByteArray(), "cases": [],
	}
	for ci in range(enc.length()):
		match enc[ci]:
			"t":
				var n := code.decode_u16(pos)
				pos += 2
				var ts: Array = []
				for j in range(n):
					ts.append(code[pos + j])
				pos += n
				d["types"] = ts
			"s":
				var n := code.decode_u16(pos)
				pos += 2
				d["sraw"] = code.slice(pos, pos + maxi(n - 1, 0))
				pos += n
			"f":
				d["flags"] = code.decode_u16(pos)
				pos += 2
			"h":
				d["hash"] = code.decode_u32(pos)
				pos += 4
			"o":
				d["voff"] = code.decode_s16(pos)
				pos += 2
			"0":
				d["aux"] = code.decode_u32(pos)
				pos += 4
			"i":
				d["iv"] = code.decode_s32(pos)
				pos += 4
			"r":
				d["fv"] = code.decode_float(pos)
				pos += 4
			"a":
				d["ac"] = code.decode_u16(pos)
				pos += 2
			"j":
				d["jo"] = code.decode_s32(pos)
				pos += 4
			"l":
				d["ln"] = code.decode_u16(pos)
				pos += 2
			"c":
				var n := code.decode_u16(pos)
				pos += 2
				var cs: Array = []
				for j in range(n):
					cs.append(code.decode_s32(pos + j * 4))
				pos += n * 4
				d["cases"] = cs
	d["size"] = pos - at
	return d
