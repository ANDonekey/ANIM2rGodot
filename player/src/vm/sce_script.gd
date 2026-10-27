class_name SceScript
extends RefCounted
## Record-level parser for decrypted ANIM sce binaries.
## Line-by-line port of reference/python/sce_parse.py + sce_token.py
## (signatures are generated into sce_signatures.gd from the Python table).
##
## Operand value forms (Arrays, mirroring the Python tuples):
##   EXPR  -> ["flag", bank_byte(0x40='@' local / 0x41='A' global), index]
##            ["imm", tag, u32 value]
##   'K'   -> ["stack", expr0, [[tag, sub, [params...]], ...]]
##   'C'   -> ["select", [[choice_value, pool_idx], ...]]
##   'D'   -> ["textblock", [["line", speaker, text, seq] | ["param", v], ...]]
##   'T'   -> tail appended as ["u8x5", [...]] / ["u32", v] / ["u32x4", [...]]

class Rec:
	var off: int
	var op: int
	var ops: Array
	var end: int


var records: Array = []  # of Rec
var record_index: Dictionary = {}  # code offset -> record index
var labels: Array = []  # of [name, offset]
var label_offset: Dictionary = {}  # name -> offset (first occurrence)
var parse_failures: Array = []  # of [segment_start, fail_offset]
var charset: Charset

var _pool: Array = []  # of PackedByteArray (raw)
var _pool_cache: Dictionary = {}


static func _u16(d: PackedByteArray, q: int) -> int:
	return d[q] | (d[q + 1] << 8)


static func _u32(d: PackedByteArray, q: int) -> int:
	return d[q] | (d[q + 1] << 8) | (d[q + 2] << 16) | (d[q + 3] << 24)


static func _find_nul(d: PackedByteArray, from: int, limit: int) -> int:
	var i := from
	while i < limit:
		if d[i] == 0:
			return i
		i += 1
	return -1


static func load_from_bytes(d: PackedByteArray) -> SceScript:
	var s := SceScript.new()
	var lt_off := _u32(d, 0)
	var pool_off := _u32(d, 4)
	# ---- label table ----
	var pos := lt_off
	while pos < pool_off:
		var e := _find_nul(d, pos, pool_off)
		if e == -1:
			break
		var nm := d.slice(pos, e).get_string_from_ascii()
		var off := _u32(d, e + 1)
		s.labels.append([nm, off])
		if not s.label_offset.has(nm):
			s.label_offset[nm] = off
		pos = e + 5
	# ---- string pool (raw bytes; decoded lazily) ----
	pos = pool_off
	while pos < d.size():
		var e2 := d.find(0, pos)
		if e2 == -1:
			break
		s._pool.append(d.slice(pos, e2))
		pos = e2 + 1
	# ---- encoding auto-detection (strict-decode probe, mirrors Python) ----
	var sample: Array = []
	var step := maxi(1, s._pool.size() / 300)
	var i := 0
	while i < s._pool.size():
		sample.append(s._pool[i])
		i += step
	var cs_cp := Charset.load_mode("cp932")
	var cs_gb := Charset.load_mode("gbk")
	var bad_cp := cs_cp.bad_string_count(sample)
	var bad_gb := cs_gb.bad_string_count(sample)
	s.charset = cs_gb if bad_gb < bad_cp else cs_cp
	# ---- code segments ----
	var offs: Array = []
	for l in s.labels:
		if not offs.has(l[1]):
			offs.append(l[1])
	offs.sort()
	var segs: Array = []
	if not offs.is_empty():
		segs.append([8, offs[0]])
		for k in offs.size() - 1:
			segs.append([offs[k], offs[k + 1]])
		segs.append([offs[offs.size() - 1], lt_off])
	for sg in segs:
		s._parse_segment(d, sg[0], sg[1])
	for idx in s.records.size():
		s.record_index[s.records[idx].off] = idx
	return s


func _parse_segment(d: PackedByteArray, a: int, b: int) -> void:
	var p := a
	while p < b:
		var r := _parse_record(d, p, b)
		if r == null or r.end > b or r.end <= p:
			parse_failures.append([a, p])
			return
		records.append(r)
		p = r.end


func _parse_expr(d: PackedByteArray, q: int) -> Array:
	var tag := d[q]
	q += 1
	if tag == 0x40 or tag == 0x41:
		return [["flag", tag, _u16(d, q)], q + 2]
	return [["imm", tag, _u32(d, q)], q + 4]


func _parse_stack(d: PackedByteArray, q: int, limit: int) -> Array:
	var head := _parse_expr(d, q)
	var v0: Array = head[0]
	q = head[1]
	var entries: Array = []
	while true:
		var tag := _u32(d, q)
		q += 4
		if tag == 0xBC:
			break
		var sub := d[q]
		q += 1
		var params: Array = []
		if sub == 0xBA:
			var a := d[q]
			var b := _u16(d, q + 1)
			var t := d[q + 3]
			q += 4
			if t == 0x43:
				params = [a, b, t, _u32(d, q)]
				q += 4
			else:
				params = [a, b, t, _u16(d, q)]
				q += 2
		else:
			for tt in SceSubParams.SIG.get(sub, ""):
				if tt == "E":
					var r := _parse_expr(d, q)
					params.append(r[0])
					q = r[1]
				elif tt == "1":
					params.append(d[q])
					q += 1
				elif tt == "2":
					params.append(_u16(d, q))
					q += 2
				elif tt == "4":
					params.append(_u32(d, q))
					q += 4
		entries.append([tag, sub, params])
	return [["stack", v0, entries], q]


func _parse_record(d: PackedByteArray, p: int, limit: int) -> Rec:
	var op := d[p]
	if not SceSignatures.SIG.has(op):
		return null
	var sig: String = SceSignatures.SIG[op]
	var q := p + 1
	var ops: Array = []
	for ci in sig.length():
		var t := sig[ci]
		match t:
			"S":
				var e := _find_nul(d, q, limit)
				if e == -1:
					return null
				ops.append(d.slice(q, e).get_string_from_ascii())
				q = e + 1
			"1":
				ops.append(d[q])
				q += 1
			"2":
				ops.append(_u16(d, q))
				q += 2
			"4":
				ops.append(_u32(d, q))
				q += 4
			"8":
				ops.append(d.decode_double(q))
				q += 8
			"E":
				var r := _parse_expr(d, q)
				ops.append(r[0])
				q = r[1]
			"T":
				var v := d[p + 1]
				if v == 0x28:
					var tail: Array = []
					for k in 5:
						tail.append(d[q + k])
					ops.append(["u8x5", tail])
					q += 5
				elif v == 0x46:
					ops.append(["u32", _u32(d, q)])
					q += 4
				elif v == 0x47:
					var tail4: Array = []
					for k in 4:
						tail4.append(_u32(d, q + 4 * k))
					ops.append(["u32x4", tail4])
					q += 16
			"K":
				var rk := _parse_stack(d, q, limit)
				ops.append(rk[0])
				q = rk[1]
			"C":
				var n := d[q]
				q += 1
				var pairs: Array = []
				for k in n:
					pairs.append([_u32(d, q), _u32(d, q + 4)])
					q += 8
				ops.append(["select", pairs])
			"D":
				var entries: Array = []
				while true:
					var c := d[q]
					q += 1
					if c == 0xD7:
						break
					if c == 0xD3:
						# interpreter: u32 speaker, u32 text, u16 seq
						entries.append(["line", _u32(d, q), _u32(d, q + 4), _u16(d, q + 8)])
						q += 10
					elif c == 0xD8:
						# pending render parameter for the next line
						entries.append(["param", _u32(d, q)])
						q += 4
					else:
						return null
				ops.append(["textblock", entries])
	var rec := Rec.new()
	rec.off = p
	rec.op = op
	rec.ops = ops
	rec.end = q
	return rec


func pool_count() -> int:
	return _pool.size()


func pool_str(idx: int) -> String:
	if idx < 0 or idx >= _pool.size():
		return "<idx %d out of range>" % idx
	if _pool_cache.has(idx):
		return _pool_cache[idx]
	var s := charset.decode(_pool[idx])
	_pool_cache[idx] = s
	return s
