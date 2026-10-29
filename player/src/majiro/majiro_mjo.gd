class_name MajiroMjo
extends RefCounted
## MajiroObjX1.000 script loader (Majiro engine).
##
## Layout (verified on STARLESS, see docs/majiro-format.md):
##   +0x00 char[16] "MajiroObjX1.000\0"
##   +0x10 u32 entrypoint_offset (offset into decrypted code)
##   +0x14 u32 field_14 (semantics unresolved)
##   +0x18 u32 function_count
##   +0x1C function[count] x 8 bytes: {u32 name_hash32, u32 code_offset}
##         u32 code_length (== remaining file size)
##         code[code_length]: XOR-encrypted bytecode
##
## Encryption ("crypt32"): code[i] = enc[i] XOR key[i & 0x3FF], where key is
## the standard CRC-32 table packed as 256 little-endian u32 (1024 bytes).
## Identifier names (function table) use plain CRC-32 over CP932 bytes.
## The MajiroObjV variant uses the CRC-64 table key instead; not present in
## the STARLESS sample and not implemented yet.

var entrypoint_offset: int = 0
var field_14: int = 0
var functions: Array[Dictionary] = [] # {hash: int, offset: int}
var code: PackedByteArray = PackedByteArray() # decrypted bytecode

static var _crypt_key: PackedByteArray = PackedByteArray()


static func crypt_key() -> PackedByteArray:
	if _crypt_key.size() == 1024:
		return _crypt_key
	var key := PackedByteArray()
	key.resize(1024)
	for n in range(256):
		var c := n
		for _k in range(8):
			if c & 1:
				c = (c >> 1) ^ 0xEDB88320
			else:
				c = c >> 1
		key.encode_u32(n * 4, c)
	_crypt_key = key
	return key


static func crypt32(data: PackedByteArray) -> PackedByteArray:
	var key := crypt_key()
	var out := PackedByteArray()
	out.resize(data.size())
	for i in range(data.size()):
		out[i] = data[i] ^ key[i & 0x3FF]
	return out


func load(bytes: PackedByteArray) -> bool:
	if bytes.size() < 40 or bytes.slice(0, 15).get_string_from_ascii() != "MajiroObjX1.000":
		push_error("MajiroMjo: bad magic")
		return false
	entrypoint_offset = bytes.decode_u32(16)
	field_14 = bytes.decode_u32(20)
	var fcount := bytes.decode_u32(24)
	var pos := 28
	functions.clear()
	for i in range(fcount):
		if pos + 8 > bytes.size():
			push_error("MajiroMjo: truncated function table")
			return false
		functions.append({"hash": bytes.decode_u32(pos), "offset": bytes.decode_u32(pos + 4)})
		pos += 8
	if pos + 4 > bytes.size():
		push_error("MajiroMjo: truncated code length")
		return false
	var clen := bytes.decode_u32(pos)
	pos += 4
	if pos + clen > bytes.size():
		push_error("MajiroMjo: code overruns file")
		return false
	code = crypt32(bytes.slice(pos, pos + clen))
	return true
