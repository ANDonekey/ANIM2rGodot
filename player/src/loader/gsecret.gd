class_name GSecret
extends RefCounted
## GSecretFile decryption (ANIM teamMM engine).
##
## Format: [00 00 00 01][16-byte key stored in plaintext][body]
## body[i] = plain[i] XOR key[i mod 16]; after every full 16-byte block the
## key is updated using the plaintext byte at block offset 14, whose low
## 3 bits select one of eight addition formulas (case 6 falls through into
## the case 7 block). A trailing partial block is XORed with the current
## key and triggers no update.
##
## Line-by-line port of reference/python/anim_gsecret.py; the sequential
## assignment order inside _update_key is part of the algorithm (later
## assignments read values written by earlier ones).
## Verified byte-for-byte against the Python reference (see tests/).

static func is_gsecret(data: PackedByteArray) -> bool:
	return data.size() >= 20 and data[0] == 0 and data[1] == 0 and data[2] == 0 and data[3] == 1


static func decrypt(data: PackedByteArray) -> PackedByteArray:
	if not is_gsecret(data):
		push_error("GSecret: bad magic or truncated file")
		return PackedByteArray()
	var key: Array[int] = []
	key.resize(16)
	for i in 16:
		key[i] = data[4 + i]
	var out := PackedByteArray()
	out.resize(data.size() - 20)
	for i in out.size():
		out[i] = data[20 + i] ^ key[i & 15]
		if (i & 15) == 15:
			_update_key(key, out[i - 1])
	return out


static func _update_key(k: Array[int], fb: int) -> void:
	match fb & 7:
		0:
			k[0] = (k[0] + fb) & 0xff
			k[3] = (k[3] + fb + 2) & 0xff
			k[4] = (k[2] + fb + 0x0b) & 0xff
			k[8] = (k[6] + 7) & 0xff
		1:
			k[2] = (k[10] + k[9]) & 0xff
			k[6] = (k[15] + k[7]) & 0xff
			k[8] = (k[8] + k[1]) & 0xff
			k[15] = (k[3] + k[5]) & 0xff
		2:
			k[1] = (k[1] + k[2]) & 0xff
			k[5] = (k[5] + k[6]) & 0xff
			k[7] = (k[7] + k[8]) & 0xff
			k[10] = (k[10] + k[11]) & 0xff
		3:
			k[9] = (k[1] + k[2]) & 0xff
			k[11] = (k[5] + k[6]) & 0xff
			k[12] = (k[7] + k[8]) & 0xff
			k[13] = (k[10] + k[11]) & 0xff
		4:
			k[0] = (k[1] + 0x6f) & 0xff
			k[3] = (k[4] + 0x47) & 0xff
			k[4] = (k[5] + 0x11) & 0xff
			k[14] = (k[15] + 0x40) & 0xff
		5:
			k[2] = (k[10] + k[2]) & 0xff
			k[4] = (k[12] + k[5]) & 0xff
			k[6] = (k[14] + k[8]) & 0xff
			k[8] = (k[0] + k[11]) & 0xff
		6:
			k[9] = (k[1] + k[11]) & 0xff
			k[11] = (k[3] + k[13]) & 0xff
			k[13] = (k[5] + k[15]) & 0xff
			k[15] = (k[7] + k[9]) & 0xff
			k[1] = (k[5] + k[9]) & 0xff
			k[2] = (k[6] + k[10]) & 0xff
			k[3] = (k[7] + k[11]) & 0xff
			k[4] = (k[8] + k[12]) & 0xff
		_:
			k[1] = (k[5] + k[9]) & 0xff
			k[2] = (k[6] + k[10]) & 0xff
			k[3] = (k[7] + k[11]) & 0xff
			k[4] = (k[8] + k[12]) & 0xff
