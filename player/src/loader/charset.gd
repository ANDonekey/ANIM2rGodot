class_name Charset
extends RefCounted
## Decodes CP932 (Shift-JIS) or GBK/GB18030 byte strings to String.
##
## Uses 128 KiB mapping tables embedded in charset_tables.gd (base64,
## generated from Python's codecs by reference/python/
## make_charset_tables.py — the reverse-engineering baseline), indexed
## by (lead<<8)|trail. Embedded in code because loose data files are
## silently dropped from exported .pck builds: Godot's editor scan
## ignores .b64/.bin/.dat outright, and even a registered .txt copy
## did not survive CLI export packing (verified 2026-10-28 — exported
## builds read an empty table and garbled all decoded text).
## Single-byte rules follow Python: CP932 0xA1-0xDF are halfwidth katakana,
## everything else below 0x80 is ASCII. GB18030 4-byte sequences do not
## occur in the sample game's pool (verified); they decode as U+FFFD.

const REPLACEMENT := 0xFFFD

var mode: String = "cp932"  # or "gbk"
var _tbl: PackedByteArray


static func load_mode(p_mode: String) -> Charset:
	var c := Charset.new()
	c.mode = p_mode
	c._tbl = Marshalls.base64_to_raw(CharsetTables.table_b64(p_mode))
	return c


static func _read_tbl(tbl: PackedByteArray, lead: int, trail: int) -> int:
	var i := ((lead << 8) | trail) * 2
	return tbl[i] | (tbl[i + 1] << 8)


## Count strings that fail strict decoding under the given mode;
## used for encoding auto-detection (mirrors the Python probe).
func bad_string_count(strings: Array) -> int:
	var bad := 0
	for b: PackedByteArray in strings:
		if _decode_or_null(b) == null:
			bad += 1
	return bad


func decode(bytes: PackedByteArray) -> String:
	var v: Variant = _decode_or_null(bytes)
	if v == null:
		# Lenient path: replace invalid units and continue.
		return _decode_lenient(bytes)
	return v


func _decode_or_null(bytes: PackedByteArray) -> Variant:
	var cps := PackedInt32Array()
	var i := 0
	var n := bytes.size()
	while i < n:
		var b := bytes[i]
		if b < 0x80:
			cps.append(b)
			i += 1
			continue
		if mode == "cp932":
			if b >= 0xA1 and b <= 0xDF:
				cps.append(0xFF61 + (b - 0xA1))
				i += 1
				continue
			if (b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC):
				if i + 1 >= n:
					return null
				var cp := _read_tbl(_tbl, b, bytes[i + 1])
				if cp == 0:
					return null
				cps.append(cp)
				i += 2
				continue
			return null
		else:  # gbk
			if b >= 0x81 and b <= 0xFE:
				if i + 1 >= n:
					return null
				var t := bytes[i + 1]
				if t >= 0x30 and t <= 0x39:
					# GB18030 4-byte sequence: unsupported (absent in practice)
					return null
				var cp2 := _read_tbl(_tbl, b, t)
				if cp2 == 0:
					return null
				cps.append(cp2)
				i += 2
				continue
			return null
	var s := ""
	for cp in cps:
		s += char(cp)
	return s


func _decode_lenient(bytes: PackedByteArray) -> String:
	var s := ""
	var i := 0
	var n := bytes.size()
	while i < n:
		var b := bytes[i]
		if b < 0x80:
			s += char(b)
			i += 1
		elif mode == "cp932" and b >= 0xA1 and b <= 0xDF:
			s += char(0xFF61 + (b - 0xA1))
			i += 1
		elif i + 1 < n and ((mode == "cp932" and ((b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC))) or (mode == "gbk" and b >= 0x81 and b <= 0xFE)):
			var cp := _read_tbl(_tbl, b, bytes[i + 1])
			if cp != 0:
				s += char(cp)
				i += 2
			else:
				s += char(REPLACEMENT)
				i += 1
		else:
			s += char(REPLACEMENT)
			i += 1
	return s
