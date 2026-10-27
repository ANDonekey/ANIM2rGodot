class_name Psb
extends RefCounted
## PSB (M2 / E-mote) container parser - port of reference/python/psb_parse.py.
## Header fields after the plain 8-byte prefix are XORed with an
## XorShift128 stream (FreeMote Consts keys); body sections are plaintext.

const M32 := 0xFFFFFFFF
const KEY1 := 123456789
const KEY2 := 362436069
const KEY3 := 521288629
const KEY4 := 0x473AB96D

var version: int
var names: Array = []
var strings: Array = []
var _data: PackedByteArray
var _chunks: Array = []  # of [offset, length]
var _off_chunk_data: int
var _off_entries: int


static func _keystream(n: int) -> PackedByteArray:
	var k1 := KEY1
	var k2 := KEY2
	var k3 := KEY3
	var k4 := KEY4
	var cur := 0
	var out := PackedByteArray()
	while out.size() < n:
		if cur == 0:
			var a := (k1 ^ ((k1 << 11) & M32)) & M32
			var c := (a ^ k4 ^ (((a ^ (k4 >> 11)) & M32) >> 8)) & M32
			k1 = k2
			k2 = k3
			k3 = k4
			k4 = c
			cur = c
		out.append(cur & 0xFF)
		cur >>= 8
	return out


static func _u(d: PackedByteArray, pos: int, n: int) -> int:
	var v := 0
	for i in n:
		v |= d[pos + i] << (8 * i)
	return v


static func _array_read(d: PackedByteArray, pos: int, width: int) -> Array:
	var count := _u(d, pos, width)
	pos += width
	var entry_len := d[pos] - 0x0C
	pos += 1
	var vals: Array = []
	for i in count:
		vals.append(_u(d, pos + i * entry_len, entry_len))
	return [vals, pos + count * entry_len]


static func parse(data: PackedByteArray) -> Psb:
	var p := Psb.new()
	p._data = data
	if data.size() < 44 or data[0] != 0x50 or data[1] != 0x53 or data[2] != 0x42 or data[3] != 0:
		push_error("Psb: bad magic")
		return null
	p.version = data[4] | (data[5] << 8)
	var ks := _keystream(36)
	var hdr: Array = []
	for i in 9:
		var off := 8 + 4 * i
		var v := 0
		for j in 4:
			v |= (data[off + j] ^ ks[4 * i + j]) << (8 * j)
		hdr.append(v)
	# header_length, off_names, off_strings, off_strings_data,
	# off_chunk_offsets, off_chunk_lengths, off_chunk_data, off_entries, checksum
	var off_names: int = hdr[1]
	var off_strings: int = hdr[2]
	var off_strings_data: int = hdr[3]
	var off_chunk_offsets: int = hdr[4]
	var off_chunk_lengths: int = hdr[5]
	p._off_chunk_data = hdr[6]
	p._off_entries = hdr[7]
	# names (trie)
	var pos := off_names
	var tag := data[pos]
	var charset: Array = _array_read(data, pos + 1, tag - 0x0D + 1)[0]
	pos = _array_read(data, pos + 1, tag - 0x0D + 1)[1]
	tag = data[pos]
	var names_data: Array = _array_read(data, pos + 1, tag - 0x0D + 1)[0]
	pos = _array_read(data, pos + 1, tag - 0x0D + 1)[1]
	tag = data[pos]
	var name_indexes: Array = _array_read(data, pos + 1, tag - 0x0D + 1)[0]
	for index in name_indexes:
		var bytes := PackedByteArray()
		var chr_: int = names_data[index]
		while chr_ != 0:
			var code: int = names_data[chr_]
			bytes.append(chr_ - charset[code])
			chr_ = code
		bytes.reverse()
		p.names.append(bytes.get_string_from_utf8())
	# strings
	var string_offsets: Array = p._array_at(off_strings)
	for o in string_offsets:
		var start: int = off_strings_data + int(o)
		var e := data.find(0, start)
		p.strings.append(data.slice(start, e).get_string_from_utf8())
	# chunks
	var coffs: Array = p._array_at(off_chunk_offsets)
	var clens: Array = p._array_at(off_chunk_lengths)
	for i in coffs.size():
		p._chunks.append([coffs[i], clens[i]])
	return p


func _array_at(off: int) -> Array:
	var tag := _data[off]
	return _array_read(_data, off + 1, tag - 0x0D + 1)[0]


func chunk_bytes(idx: int) -> PackedByteArray:
	var c: Array = _chunks[idx]
	return _data.slice(_off_chunk_data + c[0], _off_chunk_data + c[0] + c[1])


func chunk_count() -> int:
	return _chunks.size()


func root() -> Variant:
	return _unpack(_off_entries)[0]


func _unpack(pos: int) -> Array:
	var data := _data
	var tag := data[pos]
	pos += 1
	if tag == 0x00 or tag == 0x01:
		return [null, pos]
	if tag == 0x02:
		return [false, pos]
	if tag == 0x03:
		return [true, pos]
	if tag == 0x04:
		return [0, pos]
	if tag >= 0x05 and tag <= 0x0C:  # NumberN1..8
		var n := tag - 0x04
		var v := _u(data, pos, n)
		if n == 4 and v >= 0x80000000:
			v -= 0x100000000
		# n == 8: _u accumulates into a signed 64-bit int, so the wrapped
		# result already is the signed interpretation.
		return [v, pos + n]
	if tag >= 0x0D and tag <= 0x14:  # ArrayN1..8
		return _array_read(data, pos, tag - 0x0D + 1)
	if tag >= 0x15 and tag <= 0x18:  # StringN1..4
		var n2 := tag - 0x14
		return [strings[_u(data, pos, n2)], pos + n2]
	if tag >= 0x19 and tag <= 0x1C:  # ResourceN1..4
		var n3 := tag - 0x18
		return [{"$res": _u(data, pos, n3)}, pos + n3]
	if tag == 0x1D:
		return [0.0, pos]
	if tag == 0x1E:
		return [data.decode_float(pos), pos + 4]
	if tag == 0x1F:
		return [data.decode_double(pos), pos + 8]
	if tag == 0x20:  # List
		var t2 := data[pos]
		var rd := _array_read(data, pos + 1, t2 - 0x0D + 1)
		var offsets: Array = rd[0]
		var base: int = rd[1]
		var out: Array = []
		for o in offsets:
			out.append(_unpack(base + o)[0])
		return [out, base]
	if tag == 0x21:  # Objects (dictionary)
		var t3 := data[pos]
		var rd2 := _array_read(data, pos + 1, t3 - 0x0D + 1)
		var name_idxs: Array = rd2[0]
		var p2: int = rd2[1]
		var t4 := data[p2]
		var rd3 := _array_read(data, p2 + 1, t4 - 0x0D + 1)
		var offsets2: Array = rd3[0]
		var base2: int = rd3[1]
		var dict := {}
		for i in name_idxs.size():
			dict[names[name_idxs[i]]] = _unpack(base2 + offsets2[i])[0]
		return [dict, base2]
	if tag >= 0x22 and tag <= 0x25:  # ExtraChunk (v4 only)
		var n4 := tag - 0x21
		return [{"$xres": _u(data, pos, n4)}, pos + n4]
	push_error("Psb: unknown tag %x at %d" % [tag, pos - 1])
	return [null, pos]
