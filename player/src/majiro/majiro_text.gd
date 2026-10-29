class_name MajiroText
extends RefCounted
## Legacy-encoding text decoding for Majiro script strings.
##
## Tables (src/majiro/cp932.bin, gbk.bin) are generated from the platform
## codecs: 256 u16 single-byte entries (0xFFFF = double-byte lead), then
## 65536 u16 pair entries indexed by (lead << 8) | trail; 0xFFFD replaces
## unmapped sequences. Decoded codepoints are emitted as UTF-8.

const CP932_PATH := "res://src/majiro/cp932.bin"
const GBK_PATH := "res://src/majiro/gbk.bin"

static var _tables := {}


static func _table(path: String) -> PackedByteArray:
	if _tables.has(path):
		return _tables[path]
	var data := FileAccess.get_file_as_bytes(path)
	_tables[path] = data
	return data


static func decode(bytes: PackedByteArray, codec: String) -> String:
	var tab := _table(CP932_PATH if codec == "cp932" else GBK_PATH)
	if tab.size() < 131584:
		return bytes.get_string_from_ascii()
	var out := PackedByteArray()
	var i := 0
	while i < bytes.size():
		var b := bytes[i]
		var single := tab.decode_u16(b * 2)
		if single == 0xFFFF:
			if i + 1 >= bytes.size():
				_append_cp(out, 0xFFFD)
				i += 1
				continue
			var cp := tab.decode_u16(512 + ((b << 8) | bytes[i + 1]) * 2)
			_append_cp(out, cp)
			i += 2
		else:
			_append_cp(out, single)
			i += 1
	return out.get_string_from_utf8()


static func decode_cp932(bytes: PackedByteArray) -> String:
	return decode(bytes, "cp932")


static func decode_gbk(bytes: PackedByteArray) -> String:
	return decode(bytes, "gbk")


static func _append_cp(out: PackedByteArray, cp: int) -> void:
	if cp < 0x80:
		out.append(cp)
	elif cp < 0x800:
		out.append(0xC0 | (cp >> 6))
		out.append(0x80 | (cp & 0x3F))
	elif cp < 0x10000:
		out.append(0xE0 | (cp >> 12))
		out.append(0x80 | ((cp >> 6) & 0x3F))
		out.append(0x80 | (cp & 0x3F))
	else:
		out.append(0xF0 | (cp >> 18))
		out.append(0x80 | ((cp >> 12) & 0x3F))
		out.append(0x80 | ((cp >> 6) & 0x3F))
		out.append(0x80 | (cp & 0x3F))
