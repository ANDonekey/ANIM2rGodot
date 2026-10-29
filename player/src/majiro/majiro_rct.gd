class_name MajiroRct
## Majiro .rct (24-bit) / .rc8 (8-bit indexed) image decoder.
## Format per MajiroTools wiki, verified on STARLESS samples (2026-10-29):
##   header: 98 5A 92 9A + "TC00"/"TC01" (rct) or "8_00" (rc8),
##           u32 width, u32 height, u32 data_size
##   TC01 adds: u16 base_name_length + base filename (overlay layer;
##   pure red #FF0000 = transparent, shows the base image's pixel)
##   rc8 adds: 256xRGB palette before the data buffer
##   data buffer: LZ77 command stream (see _unpack); rct pixels are BGR.
## 'S' signature variants (TS00/TS01) are XOR-encrypted and not handled yet.

const RCT_TABLE := [-16, -32, -48, -64, -80, -96,
	49, 33, 17, 1, -15, -31, -47,
	50, 34, 18, 2, -14, -30, -46,
	51, 35, 19, 3, -13, -29, -45,
	36, 20, 4, -12, -28]
const RC8_TABLE := [-16, -32, -48, -64,
	49, 33, 17, 1, -15, -31, -47,
	34, 18, 2, -14, -30]

var width := 0
var height := 0
var kind := ""          # "TC00" | "TC01" | "8_00"
var base_name := ""     # TC01 only
var rgb := PackedByteArray()  # width*height*3, RGB order


static func _shift_table(width: int, base: Array) -> Array:
	var out := []
	for s in base:
		var v := int(s)
		out.append((v >> 4) - (v & 0xf) * width)
	return out


static func _unpack(data: PackedByteArray, start: int, w: int, h: int,
		depth: int, base_table: Array, count_mask: int, count_base: int,
		shift_start: int) -> PackedByteArray:
	var shifts := _shift_table(w, base_table)
	var total := w * h * depth
	var out := PackedByteArray()
	out.resize(total)
	# first pixel raw
	for i in depth:
		out[i] = data[start + i]
	var src := start + depth
	var dst := depth
	while dst < total:
		var cmd := data[src]
		src += 1
		if cmd & 0x80 == 0:
			var count := cmd
			if count == 0x7f:
				count += data.decode_u16(src)
				src += 2
			count = (count + 1) * depth
			for i in count:
				out[dst + i] = data[src + i]
			src += count
			dst += count
		else:
			var count2 := cmd & count_mask
			if count2 == count_mask:
				count2 += data.decode_u16(src)
				src += 2
			count2 = (count2 + count_base) * depth
			var shift: int = shifts[(cmd & 0x7f) >> shift_start] * depth
			var s0 := dst + shift
			if -shift >= count2:
				for i in count2:
					out[dst + i] = out[s0 + i]
			else:
				# overlapped: the -shift-byte pattern repeats
				var pat := PackedByteArray()
				pat.resize(-shift)
				for i in -shift:
					pat[i] = out[s0 + i]
				var done := 0
				while done < count2:
					var n: int = mini(pat.size(), count2 - done)
					for i in n:
						out[dst + done + i] = pat[i]
					done += n
			dst += count2
	return out


## Decode one image file's bytes. Returns a MajiroRct or null on bad input.
static func decode(data: PackedByteArray) -> MajiroRct:
	if data.size() < 20:
		return null
	if data[0] != 0x98 or data[1] != 0x5a or data[2] != 0x92 or data[3] != 0x9a:
		return null
	var img := MajiroRct.new()
	img.kind = data.slice(4, 8).get_string_from_ascii()
	img.width = data.decode_u32(8)
	img.height = data.decode_u32(12)
	var pos := 20
	if img.kind == "TC01":
		var nlen := data.decode_u16(pos)
		pos += 2
		var raw := data.slice(pos, pos + nlen)
		while not raw.is_empty() and raw[raw.size() - 1] == 0:
			raw.resize(raw.size() - 1)
		img.base_name = MajiroText.decode_cp932(raw)
		pos += nlen
		var bgr := _unpack(data, pos, img.width, img.height, 3,
			RCT_TABLE, 0x3, 1, 2)
		img.rgb = _bgr_to_rgb(bgr)
	elif img.kind == "TC00":
		var bgr := _unpack(data, pos, img.width, img.height, 3,
			RCT_TABLE, 0x3, 1, 2)
		img.rgb = _bgr_to_rgb(bgr)
	elif img.kind == "8_00":
		var palette := data.slice(20, 20 + 768)
		pos = 20 + 768
		var idx := _unpack(data, pos, img.width, img.height, 1,
			RC8_TABLE, 0x7, 3, 3)
		img.rgb = PackedByteArray()
		img.rgb.resize(img.width * img.height * 3)
		for i in idx.size():
			var p := int(idx[i]) * 3
			img.rgb[i * 3] = palette[p]
			img.rgb[i * 3 + 1] = palette[p + 1]
			img.rgb[i * 3 + 2] = palette[p + 2]
	else:
		return null
	return img


static func _bgr_to_rgb(bgr: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(bgr.size())
	for i in range(0, bgr.size(), 3):
		out[i] = bgr[i + 2]
		out[i + 1] = bgr[i + 1]
		out[i + 2] = bgr[i]
	return out


## TC01 composition: overlay pixels replace base pixels except pure red
## (#FF0000), which is transparent. Inputs are RGB buffers of equal size.
static func composite(overlay_rgb: PackedByteArray, base_rgb: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray(base_rgb)
	for i in range(0, mini(overlay_rgb.size(), out.size()), 3):
		if overlay_rgb[i] == 255 and overlay_rgb[i + 1] == 0 and overlay_rgb[i + 2] == 0:
			continue
		out[i] = overlay_rgb[i]
		out[i + 1] = overlay_rgb[i + 1]
		out[i + 2] = overlay_rgb[i + 2]
	return out
