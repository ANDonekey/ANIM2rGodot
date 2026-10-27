class_name DefineTable
extends RefCounted
## E-mote pose table from a decrypted ANIM define file - port of
## reference/python/define_extract.py (poses section).
## Record: [u32 9][u32 flags] 'em...' label, then (varname, ascii-float)
## string pairs until the ('', '0.0') terminator pair.

var poses: Dictionary = {}  # label -> {flags: int, vars: {name: float}}


static func _cstr(d: PackedByteArray, pos: int) -> Array:
	var e := d.find(0, pos)
	if e == -1:
		return [null, pos]
	return [d.slice(pos, e).get_string_from_ascii(), e + 1]


static func _is_em_label(s: String) -> bool:
	if not s.begins_with("em") or s.length() < 3:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		var ok := (c >= 0x30 and c <= 0x39) or (c >= 0x41 and c <= 0x5A) \
				or (c >= 0x61 and c <= 0x7A) or c == 0x5F
		if not ok:
			return false
	return true


static func parse(d: PackedByteArray) -> DefineTable:
	var t := DefineTable.new()
	var marker := PackedByteArray([9, 0, 0, 0])
	var from := 0
	while true:
		var at := _find_marker(d, marker, from)
		if at == -1:
			break
		from = at + 1
		var pos := at + 4
		if pos + 4 > d.size():
			continue
		var flags := SceScript._u32(d, pos)
		pos += 4
		var lr := _cstr(d, pos)
		if lr[0] == null or not _is_em_label(lr[0]):
			continue
		var label: String = lr[0]
		pos = lr[1]
		var vars_ := {}
		var ok := true
		while true:
			var nr := _cstr(d, pos)
			if nr[0] == null:
				ok = false
				break
			var vr := _cstr(d, nr[1])
			if vr[0] == null:
				ok = false
				break
			pos = vr[1]
			if nr[0] == "" and vr[0] == "0.0":
				break
			if not (vr[0] as String).is_valid_float():
				ok = false
				break
			vars_[nr[0]] = (vr[0] as String).to_float()
			if vars_.size() > 40:
				ok = false
				break
		if ok:
			t.poses[label] = {"flags": flags, "vars": vars_}
	return t


static func _find_marker(d: PackedByteArray, marker: PackedByteArray, from: int) -> int:
	var i := from
	var last := d.size() - marker.size()
	while i <= last:
		var match_all := true
		for j in marker.size():
			if d[i + j] != marker[j]:
				match_all = false
				break
		if match_all:
			return i
		i += 1
	return -1


func pose_vars(label: String) -> Dictionary:
	var p: Variant = poses.get(label)
	if p == null:
		return {}
	return p["vars"]
