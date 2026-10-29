class_name MajiroHost
extends RefCounted
## Headless host services for MajiroVm: the syscall families whose
## semantics are data-only (files, strings, arrays, queries).
## Graphics/sound/input families are registered as logged stubs here;
## the presentation layer replaces them in the real player.
##
## Value dicts use MajiroVm's shape: {"k": kind, "v": payload} with
## kinds 0=int 1=float 2=string(bytes) 3=int[] 4=float[] 5=string[].

const K_INT := 0
const K_FLOAT := 1
const K_STRING := 2
const K_IARR := 3
const K_FARR := 4
const K_SARR := 5

# Set by the owner: (name: String) -> PackedByteArray, empty when missing.
var read_file: Callable
# Client surface the scripts query.
var client_width := 1024
var client_height := 768
# Every stubbed call, hash -> count, plus a readable event log.
var stub_calls := {}
var events: Array = []

var _handles := {}
var _next_handle := 1


static func vint(i: int) -> Dictionary:
	return {"k": K_INT, "v": i}


static func vfloat(f: float) -> Dictionary:
	return {"k": K_FLOAT, "v": f}


static func vstr(b: PackedByteArray) -> Dictionary:
	return {"k": K_STRING, "v": b}


static func varr(kind: int, items: Array) -> Dictionary:
	return {"k": kind, "v": items}


static func _as_int(v: Dictionary) -> int:
	match int(v["k"]):
		K_INT:
			return int(v["v"])
		K_FLOAT:
			return int(float(v["v"]))
		K_STRING:
			return (v["v"] as PackedByteArray).get_string_from_ascii().to_int()
	return 0


static func _as_bytes(v: Dictionary) -> PackedByteArray:
	if int(v["k"]) == K_STRING:
		return v["v"]
	if int(v["k"]) == K_INT:
		return str(int(v["v"])).to_ascii_buffer()
	if int(v["k"]) == K_FLOAT:
		return str(float(v["v"])).to_ascii_buffer()
	return PackedByteArray()


func attach(vm: MajiroVm) -> void:
	var s := vm.syscalls
	# --- file family (Majiro text-format scanner) ---
	s[0xE4E3B40D] = _file_open        # file_open
	s[0xD6333B3C] = _file_close       # file_close
	s[0x2539D212] = _file_read        # file_read   -> int
	s[0x55232561] = _file_read_str    # file_read$  -> string token
	s[0x6008BEBB] = _file_read_line   # file_read_line$
	s[0xE8A6A59F] = _file_read_line   # file_read_line_raw$ (approx)
	s[0x63B8CB23] = _file_puts        # file_puts (logged no-op)
	s[0xD1921ED9] = _file_write_open  # file_write_open -> fake handle
	# --- array dimension family ---
	s[0x96B07AEE] = _dim_create_i     # dim_create#
	s[0x1F57B724] = _dim_create_s     # dim_create$#
	s[0xA6AC6CCC] = _dim_create_f     # dim_create%#
	s[0x3A49E325] = _stub0            # dim_release#
	s[0x134D5585] = _stub0            # dim_release$#
	s[0xAAB68E6D] = _stub0            # dim_release%#
	s[0x7FCF3C82] = _dim_copy         # dim_copy# (shallow: returns source)
	s[0x5BBAE511] = _dim_copy         # dim_copy$#
	s[0xE2413EF9] = _dim_copy         # dim_copy%#
	# --- string / math utilities ---
	s[0x06906970] = _strleft          # strleft$
	s[0x25401A1F] = _strright         # strright$
	s[0x69DB4512] = _strstr           # strstr
	s[0x6F769889] = _itoa             # itoa$
	s[0x3D053317] = _min2             # min
	s[0x6CFC884A] = _max2             # max
	s[0x959B0A16] = _abs              # abs
	# --- queries with fixed answers in a headless run ---
	s[0x8C283F7F] = func(_a: Array) -> Dictionary: return vint(client_height)
	s[0x0EBC053B] = _stub0            # auto_mode_config
	s[0x6E6C641A] = _stub0            # is_testplay
	s[0x38721A26] = _stub0            # is_ultra_fast_mode
	s[0x5B87A41D] = func(_a: Array) -> Dictionary: return vint(1)  # console_is_on
	s[0x4FFAB7C4] = _stub0            # is_save_menu_disable
	# --- click/wait family: headless policy = "already clicked" ---
	s[0x008ACBC0] = func(_a: Array) -> Dictionary: return vint(1)  # mk_wait
	s[0x1204D7E8] = _stub0            # mk_unwait
	s[0x892E9B20] = _stub0            # mk_read
	s[0x2075C300] = _stub0            # mk_stat
	s[0xCF35F0E3] = _stub0            # (timed wait variant)
	s[0xFF75CD29] = _stub0            # (timed wait variant)
	s[0xE06200C4] = func(_a: Array) -> Dictionary: return vint(client_width)
	s[0x266A3C79] = _strupr           # strupr$
	s[0x924EE3EB] = _rgb              # rgb
	s[0xD3C06820] = _file_exists      # pic_is_exist
	s[0x45AD5F4D] = _file_exists      # sound_is_exist
	s[0xA62AA5EB] = _stub0            # is_fast_mode
	s[0xC21F8B49] = _stub0            # is_auto_mode
	s[0x9FB53FBE] = func(_a: Array) -> Dictionary: return vint(1)  # thread_is_exist
	s[0xF8FD08F6] = func(_a: Array) -> Dictionary: return vint(client_width)   # page_len_x
	s[0x65F2E980] = func(_a: Array) -> Dictionary: return vint(client_height)  # page_len_y
	s[0xFEF981D4] = func(_a: Array) -> Dictionary: return vint(0)  # sprite_len_y
	s[0xF6A05538] = _stub0            # sprite_create_ext
	s[0xB7E3E81C] = _stub0            # (registered engine syscall, name unrecovered; 0-arg, call sites look like a flush/yield)
	# --- everything else presentation-ish: logged stubs ---
	for h in [0x098399F2, 0x265E07D7, 0x30636D6E, 0x307F28BC, 0x3A3BFB29,
			0x4133D7A9, 0x4980F82C, 0x4E1EB9D0, 0x57EFA275, 0x70612DB5,
			0x8D8FB32E, 0x979D1F16, 0xA2743878, 0xA79731A2, 0xA7C6E918,
			0xB5A1E3C9, 0xBA383010, 0xC50DFD06, 0xCF2B1E50, 0xD01BE374,
			0xD4066E31, 0xDCC706EF, 0xDF644F85, 0xDFD5599E, 0xDFDBA8E4,
			0xE119D5BA, 0xE3605CFA, 0xF62E3CA7, 0xF63CB36C, 0x3FE05B39,
			0x0C070535, 0x15EEDEAA, 0x83A53FFA,  # music/sound stop+fadeout
			0x44BC7555, 0x60085FA4,                # mouse enable/disable
			0x76EE6C90, 0x4662E95D,               # do_event, draw_wait
			0x7A7B6ED4, 0x0C93FCB4,               # pic_key_set, set_effectspeed
			0x818A4B92, 0x81CE0485, 0x8C7F4C1E,   # fast mode reset/disable/enable
			0x6DE6CDFC,                           # invalidate_enable
			0x56BBBA3A, 0x5EB974F7, 0x3E11F2C5,   # grp_copy, pic_unpack, get_frontbuffer
			0x83D81F59, 0x8D84B83F,               # page_create/is_exist
			0x3B1D5537, 0x3F34D519, 0x63F660A2,   # sprite_*
			0x68EF2987, 0x69073588, 0x221C2CC2]:  # sprite_is_move/priority, movie_stop
		s[h] = _stub_recording(h)


func _stub_recording(hash: int) -> Callable:
	return func(_a: Array) -> Dictionary:
		stub_calls[hash] = int(stub_calls.get(hash, 0)) + 1
		return vint(0)


func _stub0(_a: Array) -> Dictionary:
	return vint(0)


# ------------------------------------------------------------------ files

func _file_open(args: Array) -> Dictionary:
	if args.is_empty() or not read_file.is_valid():
		return vint(0)
	var name := _as_bytes(args[0]).get_string_from_ascii()
	var data: PackedByteArray = read_file.call(name)
	if data.is_empty():
		events.append("file_open MISS " + name)
		return vint(0)
	var h := _next_handle
	_next_handle += 1
	_handles[h] = {"data": data, "pos": 0, "name": name}
	return vint(h)


func _file_write_open(args: Array) -> Dictionary:
	var h := _next_handle
	_next_handle += 1
	_handles[h] = {"data": PackedByteArray(), "pos": 0, "name": "write"}
	return vint(h)


func _file_close(args: Array) -> Dictionary:
	if not args.is_empty():
		_handles.erase(_as_int(args[0]))
	return vint(0)


func _file_puts(_args: Array) -> Dictionary:
	return vint(0)


# Scanner: tokens are separated by whitespace; // comments run to EOL.
func _scan_token(st: Dictionary) -> PackedByteArray:
	var data: PackedByteArray = st["data"]
	var pos := int(st["pos"])
	var n := data.size()
	while pos < n:
		var c := data[pos]
		if c == 0x2f and pos + 1 < n and data[pos + 1] == 0x2f:
			while pos < n and data[pos] != 0x0a:
				pos += 1
		elif c <= 0x20:
			pos += 1
		else:
			break
	var start := pos
	while pos < n and data[pos] > 0x20:
		pos += 1
	st["pos"] = pos
	return data.slice(start, pos)


func _file_read(args: Array) -> Dictionary:
	var st: Variant = _handles.get(_as_int(args[0]), null)
	if st == null:
		return vint(0)
	var tok := _scan_token(st)
	if tok.is_empty():
		return vint(0)
	return vint(tok.get_string_from_ascii().to_int())


func _file_read_str(args: Array) -> Dictionary:
	var st: Variant = _handles.get(_as_int(args[0]), null)
	if st == null:
		return vstr(PackedByteArray())
	return vstr(_scan_token(st))


func _file_read_line(args: Array) -> Dictionary:
	var st: Variant = _handles.get(_as_int(args[0]), null)
	if st == null:
		return vstr(PackedByteArray())
	var data: PackedByteArray = st["data"]
	var pos := int(st["pos"])
	var start := pos
	while pos < data.size() and data[pos] != 0x0a:
		pos += 1
	var line := data.slice(start, pos)
	if pos < data.size():
		pos += 1
	st["pos"] = pos
	while not line.is_empty() and (line[line.size() - 1] == 0x0d or line[line.size() - 1] <= 0x20):
		line.resize(line.size() - 1)
	return vstr(line)


# ------------------------------------------------------------------ dims

func _dim_build(sizes: Array, depth: int, kind: int) -> Dictionary:
	var n := 0
	if depth < sizes.size():
		n = int(sizes[depth])
	var items: Array = []
	if depth + 1 >= sizes.size():
		var dv: Dictionary
		match kind:
			K_SARR:
				dv = {"k": K_STRING, "v": PackedByteArray()}
			K_FARR:
				dv = {"k": K_FLOAT, "v": 0.0}
			_:
				dv = {"k": K_INT, "v": 0}
		for i in n:
			items.append(dv.duplicate())
	else:
		for i in n:
			items.append(_dim_build(sizes, depth + 1, kind))
	return {"k": kind, "v": items}


func _dim_create_i(args: Array) -> Dictionary:
	return _dim_build(args.map(func(v): return _as_int(v)), 0, K_IARR)


func _dim_create_s(args: Array) -> Dictionary:
	return _dim_build(args.map(func(v): return _as_int(v)), 0, K_SARR)


func _dim_create_f(args: Array) -> Dictionary:
	return _dim_build(args.map(func(v): return _as_int(v)), 0, K_FARR)


func _dim_copy(args: Array) -> Dictionary:
	if args.is_empty():
		return varr(K_IARR, [])
	return args[0]


# ------------------------------------------------------------------ strings

func _strleft(args: Array) -> Dictionary:
	if args.size() < 2:
		return vstr(PackedByteArray())
	var b := _as_bytes(args[0])
	var n: int = clampi(_as_int(args[1]), 0, b.size())
	return vstr(b.slice(0, n))


func _strright(args: Array) -> Dictionary:
	if args.size() < 2:
		return vstr(PackedByteArray())
	var b := _as_bytes(args[0])
	var n: int = clampi(_as_int(args[1]), 0, b.size())
	return vstr(b.slice(b.size() - n))


func _strstr(args: Array) -> Dictionary:
	if args.size() < 2:
		return vint(-1)
	var hay := _as_bytes(args[0])
	var needle := _as_bytes(args[1])
	if needle.is_empty() or needle.size() > hay.size():
		return vint(-1)
	for i in hay.size() - needle.size() + 1:
		var match_all := true
		for j in needle.size():
			if hay[i + j] != needle[j]:
				match_all = false
				break
		if match_all:
			return vint(i)
	return vint(-1)


func _itoa(args: Array) -> Dictionary:
	if args.is_empty():
		return vstr(PackedByteArray())
	return vstr(str(_as_int(args[0])).to_ascii_buffer())


func _min2(args: Array) -> Dictionary:
	if args.size() < 2:
		return vint(0)
	return vint(mini(_as_int(args[0]), _as_int(args[1])))


func _max2(args: Array) -> Dictionary:
	if args.size() < 2:
		return vint(0)
	return vint(maxi(_as_int(args[0]), _as_int(args[1])))


func _abs(args: Array) -> Dictionary:
	if args.is_empty():
		return vint(0)
	if int(args[0]["k"]) == K_FLOAT:
		return vfloat(absf(float(args[0]["v"])))
	return vint(absi(_as_int(args[0])))


func _strupr(args: Array) -> Dictionary:
	if args.is_empty():
		return vstr(PackedByteArray())
	var b := _as_bytes(args[0])
	var out := PackedByteArray()
	out.resize(b.size())
	for i in b.size():
		var c := b[i]
		out[i] = c - 32 if (c >= 0x61 and c <= 0x7a) else c
	return vstr(out)


func _rgb(args: Array) -> Dictionary:
	if args.size() < 3:
		return vint(0)
	return vint((_as_int(args[0]) & 0xff) | ((_as_int(args[1]) & 0xff) << 8) | ((_as_int(args[2]) & 0xff) << 16))


func _file_exists(args: Array) -> Dictionary:
	if args.is_empty() or not read_file.is_valid():
		return vint(0)
	var name := _as_bytes(args[0]).get_string_from_ascii()
	return vint(0 if (read_file.call(name) as PackedByteArray).is_empty() else 1)
