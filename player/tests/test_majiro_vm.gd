extends SceneTree
## Majiro VM boot trace against the STARLESS package.
##   godot --headless --path player -s tests/test_majiro_vm.gd -- <game_dir>
## Boots start.mjo with stub syscalls, runs a step budget, and reports the
## execution picture: loaded libraries, call depth, trace events, and any
## fatal-class errors (unresolved calls, bad pc, unimplemented opcodes).

var _arc: MajiroArc
var _cache := {}
var _index := {}
var _file_arcs: Array = []  # [{arc, index}] in search order
var _names := {}


func _read_file(fname: String) -> PackedByteArray:
	var key := fname.to_lower()
	for entry in _file_arcs:
		var index: Dictionary = entry["index"]
		if index.has(key):
			return (entry["arc"] as MajiroArc).read_at(int(index[key]))
	return PackedByteArray()


func _load_script(script_name: String) -> Variant:
	if _cache.has(script_name):
		return _cache[script_name]
	# The engine's loader case-folds names (UserTrans -> usertrans.mjo).
	var key := (script_name + ".mjo").to_lower()
	var bytes := PackedByteArray()
	if _index.has(key):
		bytes = _arc.read_at(int(_index[key]))
	if bytes.is_empty():
		_cache[script_name] = null
		return null
	var mjo := MajiroMjo.new()
	if not mjo.load(bytes):
		_cache[script_name] = null
		return null
	_cache[script_name] = mjo
	return mjo


func _ascii(b: PackedByteArray) -> String:
	var out := ""
	for i in range(mini(b.size(), 60)):
		var c := b[i]
		out += char(c) if c >= 0x20 and c < 0x7F else "."
	return out


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("usage: test_majiro_vm.gd -- <game_dir>")
		quit(2)
		return
	_arc = MajiroArc.new()
	if not _arc.open(args[0].path_join("scenario.arc")):
		printerr("FAIL scenario.arc opens")
		quit(1)
		return
	for idx in range(_arc.entry_count()):
		_index[_arc.raw_name(idx).get_string_from_ascii().to_lower()] = idx
	for arc_name in ["updateCHS", "scenario", "fastdata", "data1", "data2", "data3", "data4", "stream", "voice"]:
		var a := MajiroArc.new()
		if a.open(args[0].path_join(arc_name + ".arc")):
			var index := {}
			for idx in range(a.entry_count()):
				index[MajiroText.decode_cp932(a.raw_name(idx)).to_lower()] = idx
			_file_arcs.append({"arc": a, "index": index})
	if FileAccess.file_exists("res://src/majiro/majiro_syscall_names.json"):
		_names = JSON.parse_string(FileAccess.get_file_as_string("res://src/majiro/majiro_syscall_names.json"))
	var vm := MajiroVm.new(Callable(self, "_load_script"))
	var host := MajiroHost.new()
	host.read_file = Callable(self, "_read_file")
	host.attach(vm)
	if not vm.boot("start"):
		printerr("FAIL boot")
		quit(1)
		return
	vm.run(300000)
	print("loaded scripts (%d): %s" % [vm.loaded_script_names().size(), ", ".join(vm.loaded_script_names())])
	print("stats: ", vm.stats)
	print("trace events: ", vm.trace.size())
	var shown := 0
	for ev in vm.trace:
		if shown >= 20:
			break
		if ev["ev"] == "proc":
			print("  [proc]")
			shown += 1
		else:
			print("  [%s] %s" % [ev["ev"], _ascii(ev["s"])])
			shown += 1
	var keys := vm.unknown_syscalls.keys()
	keys.sort()
	var labeled: Array = []
	for k in keys.slice(0, 40):
		var hexpart := String(k).trim_prefix("0x")
		if _names.has(hexpart):
			labeled.append("%s(%s)" % [k, _names[hexpart]])
		else:
			labeled.append(String(k))
	print("unknown/unhandled (%d): %s" % [keys.size(), ", ".join(labeled)])
	print("host stub calls: ", host.stub_calls.size(), " kinds, events: ", host.events.size())
	for e in host.events.slice(0, 5):
		print("  host: ", e)
	var fatal := 0
	for e in vm.errors:
		if String(e).begins_with("argcheck"):
			continue
		fatal += 1
		if fatal <= 10:
			printerr("ERR ", e)
	if fatal > 0:
		print("last steps:")
		for line in vm.debug_ring:
			print("   ", line)
	print("errors: %d total, %d fatal-class" % [vm.errors.size(), fatal])
	if fatal == 0 and int(vm.stats["steps"]) > 5000:
		print("test_majiro_vm: PASS")
		quit(0)
	else:
		printerr("test_majiro_vm: FAIL")
		quit(1)
