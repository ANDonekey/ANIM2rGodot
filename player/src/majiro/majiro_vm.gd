class_name MajiroVm
extends RefCounted
## Majiro virtual machine core (see docs/majiro-format.md §10).
##
## Values are Dictionaries {"k": kind, "v": Variant}; kind follows MjoType
## (0 int, 1 float, 2 string, 3 int array, 4 float array, 5 string array).
## Strings stay raw bytes (PackedByteArray); the text layer owns decoding.
## Variables are (scope, name hash) -> Array of value cells; the operand
## offset indexes the cells, offset -2 is the array-length pseudo element.
## Scopes: 0 persistent, 1 savefile, 2 thread, 3 local (per frame).
##
## The host supplies script loading through `vfs`:
##   vfs.call(script_name_without_extension) -> MajiroMjo or null
## and presentation through syscall handlers registered in `syscalls`:
##   handler(args: Array) -> Value Dictionary
## Unhandled syscalls return int 0 and are logged once in `unknown_syscalls`.

const K_INT := 0
const K_FLOAT := 1
const K_STRING := 2
const K_IARR := 3
const K_FARR := 4
const K_SARR := 5

const SC_PERSISTENT := 0
const SC_SAVEFILE := 1
const SC_THREAD := 2
const SC_LOCAL := 3

const HASH_THREAD_BEGIN := 0xF2F9DAA8
const HASH_THREAD_BEGIN_CHILD := 0xAE497F1A
const HASH_THREAD_END := 0x4EF903F3
const HASH_LOAD_LIBRARY := 0x10DB0A43
const HASH_LOAD_LIBRARY2 := 0x10DB0A44
const HASH_EXEC := 0x718EF651
const HASH_SCRIPT_CALL := 0xCD00D280

var vfs: Callable
var syscalls: Dictionary = {}
var trace: Array = []
var errors: Array = []
## Test-harness event log (menu returns, $exec calls, area clicks);
## the player prints and clears it in its periodic dump.
var unknown_syscalls: Dictionary = {}
## Bounded ring of the most recent executed instructions,
## kept for error reports and test diagnostics.
var debug_ring: Array = []
var stats: Dictionary = {"steps": 0, "max_depth": 0, "calls": 0, "syscalls": 0}

var _scripts: Array = [] # load order: [{name, mjo}]
var _by_name: Dictionary = {}
var _lib_mains_started := {}
var _persist: Dictionary = {}
var _save: Dictionary = {}
var _persist_synth: Dictionary = {}
var _save_synth: Dictionary = {}
var _threads: Array = []
var _cur: Dictionary = {}
var _halted := false


static func vint(i: int) -> Dictionary:
	return {"k": K_INT, "v": i}


static func vfloat(f: float) -> Dictionary:
	return {"k": K_FLOAT, "v": f}


static func vstr(b: PackedByteArray) -> Dictionary:
	return {"k": K_STRING, "v": b}


static func varr(kind: int, items: Array) -> Dictionary:
	return {"k": kind, "v": items}


static func vdefault(kind: int) -> Dictionary:
	match kind:
		K_FLOAT:
			return vfloat(0.0)
		K_STRING:
			return vstr(PackedByteArray())
		K_IARR, K_FARR, K_SARR:
			return {"k": kind, "v": []}
		_:
			return vint(0)


static func i32(x: int) -> int:
	x = x & 0xFFFFFFFF
	return x - 0x100000000 if x >= 0x80000000 else x


func _init(loader: Callable) -> void:
	vfs = loader


# ---------------------------------------------------------------- scripts

func load_script(script_name: String) -> Variant:
	if _by_name.has(script_name):
		return _by_name[script_name]
	var mjo: Variant = vfs.call(script_name)
	if mjo == null:
		errors.append("load_script: not found: " + script_name)
		return null
	var rec := {"name": script_name, "mjo": mjo}
	_scripts.append(rec)
	_by_name[script_name] = rec
	return rec


func _resolve(hash: int, cur_rec: Variant) -> Variant:
	if cur_rec != null:
		var hit: Variant = _find_in(cur_rec, hash)
		if hit != null:
			return hit
	for i in range(_scripts.size() - 1, -1, -1):
		var rec: Dictionary = _scripts[i]
		if cur_rec != null and rec["name"] == cur_rec["name"]:
			continue
		var hit2: Variant = _find_in(rec, hash)
		if hit2 != null:
			return hit2
	return null


func _find_in(rec: Dictionary, hash: int) -> Variant:
	var mjo: MajiroMjo = rec["mjo"]
	for f in mjo.functions:
		if int(f["hash"]) == hash:
			return {"rec": rec, "offset": int(f["offset"])}
	return null


func loaded_script_names() -> Array:
	var out: Array = []
	for rec in _scripts:
		out.append(rec["name"])
	return out


# ---------------------------------------------------------------- storage

func _store(scope: int, frame: Variant) -> Dictionary:
	match scope:
		SC_PERSISTENT:
			return _persist
		SC_SAVEFILE:
			return _save
		SC_THREAD:
			return _cur["tvars"]
		SC_LOCAL:
			if frame != null:
				return frame["locals"]
			return _persist
	return _persist


const HASH_SYS_NUMPARAMS := 0xA704BDBD # $__SYS__NumParams


func _synth_dict(scope: int, frame: Variant) -> Dictionary:
	match scope:
		SC_PERSISTENT:
			return _persist_synth
		SC_SAVEFILE:
			return _save_synth
		SC_THREAD:
			var t: Dictionary = _cur
			if not t.has("synth"):
				t["synth"] = {}
			return t["synth"]
		SC_LOCAL:
			if frame != null:
				if not frame.has("synth"):
					frame["synth"] = {}
				return frame["synth"]
			return _persist_synth
	return _persist_synth


func _cells(store: Dictionary, hash: int, create: bool) -> Variant:
	if store.has(hash):
		return store[hash]
	if not create:
		return null
	var cells: Array = []
	store[hash] = cells
	return cells


func _cell_get(scope: int, frame: Variant, hash: int, off: int, kind: int) -> Dictionary:
	if off == -1:
		var sd := _synth_dict(scope, frame)
		return sd.get(hash, vdefault(kind))
	if scope == SC_LOCAL and frame != null:
		if off <= -2:
			# negative local offsets address the frame's arguments:
			# -2 = arg0, -3 = arg1, ...
			var ai := -off - 2
			var fargs: Array = frame["args"]
			if ai < 0 or ai >= fargs.size():
				return vdefault(kind)
			return fargs[ai]
		var fcells: Array = frame["cells"]
		if off < 0 or off >= fcells.size():
			return vdefault(kind)
		return fcells[off]
	var store := _store(scope, frame)
	var cells: Variant = _cells(store, hash, false)
	if cells == null or off < 0 or off >= cells.size():
		return vdefault(kind)
	return cells[off]


func _cell_set(scope: int, frame: Variant, hash: int, off: int, kind: int, val: Dictionary) -> void:
	if off == -1:
		_synth_dict(scope, frame)[hash] = val
		return
	if scope == SC_LOCAL and frame != null:
		if off <= -2:
			var ai := -off - 2
			var fargs: Array = frame["args"]
			if ai >= 0 and ai < fargs.size():
				fargs[ai] = val
			return
		var fcells: Array = frame["cells"]
		while fcells.size() <= off:
			fcells.append(vdefault(kind))
		fcells[off] = val
		return
	var store := _store(scope, frame)
	var cells: Variant = _cells(store, hash, true)
	if off == -2:
		var n: int = val["v"]
		while cells.size() > n:
			cells.pop_back()
		while cells.size() < n:
			cells.append(vdefault(kind))
		return
	while cells.size() <= off:
		cells.append(vdefault(kind))
	cells[off] = val


# ---------------------------------------------------------------- values

func _as_int(v: Dictionary) -> int:
	match int(v["k"]):
		K_INT:
			return int(v["v"])
		K_FLOAT:
			return int(float(v["v"]))
		K_STRING:
			return (v["v"] as PackedByteArray).size()
	return 0


func _as_float(v: Dictionary) -> float:
	match int(v["k"]):
		K_FLOAT:
			return float(v["v"])
		K_INT:
			return float(int(v["v"]))
	return 0.0


func _as_str(v: Dictionary) -> PackedByteArray:
	match int(v["k"]):
		K_STRING:
			return v["v"]
		K_INT:
			return str(int(v["v"])).to_ascii_buffer()
		K_FLOAT:
			return str(float(v["v"])).to_ascii_buffer()
	return PackedByteArray()


func _truthy(v: Dictionary) -> bool:
	match int(v["k"]):
		K_INT:
			return int(v["v"]) != 0
		K_FLOAT:
			return float(v["v"]) != 0.0
		K_STRING:
			return (v["v"] as PackedByteArray).size() > 0
	return false


# ---------------------------------------------------------------- threads

const HASH_INIT_GLOBAL := 0xB1BB8ADC # hash32("$init@GLOBAL")
const HASH_MAIN_GLOBAL := 0x1D128F30 # hash32("$main@GLOBAL")


func boot(script_name: String) -> bool:
	var rec: Variant = load_script(script_name)
	if rec == null:
		return false
	# Phase 1 (engine boot order, measured from WinMain): the boot script's
	# $init@GLOBAL runs first -- it issues the load_library syscalls that
	# make the library functions resolvable.
	var init_hit: Variant = _resolve(HASH_INIT_GLOBAL, rec)
	if init_hit != null:
		var t1 := {"stack": [], "frames": [], "tvars": {}, "done": false, "wait": 0}
		_threads.append(t1)
		_cur = t1
		_push_frame(t1, init_hit["rec"], int(init_hit["offset"]), 0, -1)
		run(2000000)
		_threads.erase(t1)
	# Phase 2: $$main at the script's entrypoint offset.
	var thread := {
		"stack": [], "frames": [], "tvars": {}, "done": false, "wait": 0,
	}
	_threads.append(thread)
	_cur = thread
	_push_frame(thread, rec, (rec["mjo"] as MajiroMjo).entrypoint_offset, 0, -1)
	return true




func _push_frame(thread: Dictionary, rec: Dictionary, offset: int, argc: int, ret_pc: int) -> void:
	var frames: Array = thread["frames"]
	var stack: Array = thread["stack"]
	var base := stack.size() - argc
	var fargs: Array = stack.slice(base, base + argc)
	fargs.reverse()
	frames.append({
		"rec": rec, "pc": offset, "base": base, "entry": offset,
		"argc": argc, "args": fargs,
		"ret_pc": ret_pc, "locals": {}, "cells": [], "line": 0,
	})
	stats["max_depth"] = maxi(int(stats["max_depth"]), frames.size())


func run(max_steps: int) -> void:
	var steps := 0
	while steps < max_steps and not _halted:
		var progressed := false
		for t in _threads:
			if t["done"] or int(t.get("wait", 0)) != 0:
				continue
			_cur = t
			steps += _step_thread(t, max_steps - steps)
			progressed = true
			if _halted:
				break
		if not progressed:
			break
	stats["steps"] = int(stats["steps"]) + steps


func _step_thread(thread: Dictionary, budget: int) -> int:
	var n := 0
	var stack: Array = thread["stack"]
	while n < budget and not thread["done"] and not _halted and int(thread.get("wait", 0)) == 0:
		var frames: Array = thread["frames"]
		if frames.is_empty():
			thread["done"] = true
			break
		var frame: Dictionary = frames[frames.size() - 1]
		var rec: Dictionary = frame["rec"]
		var mjo: MajiroMjo = rec["mjo"]
		var pc: int = frame["pc"]
		if pc < 0 or pc >= mjo.code.size():
			errors.append("pc out of range in " + String(rec["name"]))
			thread["done"] = true
			break
		var ins := MajiroInsn.decode(mjo.code, pc)
		debug_ring.append("%s:0x%x %s" % [String(rec["name"]), pc, String(ins["mn"])])
		if debug_ring.size() > 96:
			debug_ring.pop_front()
		frame["pc"] = pc + int(ins["size"])
		n += 1
		_exec(thread, frame, ins, pc)
	return n


# ---------------------------------------------------------------- exec

func _pop(thread: Dictionary) -> Dictionary:
	var stack: Array = thread["stack"]
	if stack.is_empty():
		errors.append("stack underflow")
		_halted = true
		return vint(0)
	return stack.pop_back()


func _push(thread: Dictionary, v: Dictionary) -> void:
	(thread["stack"] as Array).append(v)


var text_gate: Callable

## Sink for engine built-in events the VM itself must raise
## (stage.fire_event): set by MajiroStage.attach.
var event_sink: Callable


## Suspend a thread at a text/proc opcode whose console gate is
## closed: flag the wait and rewind the pc over the opcode so it
## re-executes (and re-checks the gate) once the host wakes it.
func _gate_suspend(thread: Dictionary, frame: Dictionary, ins: Dictionary) -> void:
	thread["wait"] = 1
	thread["text_wait"] = true
	frame["pc"] = int(frame["pc"]) - int(ins["size"])


func _exec(thread: Dictionary, frame: Dictionary, ins: Dictionary, at: int) -> void:
	var op: int = ins["op"]
	var mn: String = ins["mn"]
	var stack: Array = thread["stack"]
	if op >= 0x100 and op < 0x1B0:
		_exec_arith(thread, mn)
		return
	if (op >= 0x1B0 and op < 0x270) or (op >= 0x270 and op < 0x328):
		_exec_store(thread, frame, ins, mn)
		return
	match op:
		0x800: # ldc.i
			_push(thread, vint(i32(int(ins["iv"]))))
		0x801: # ldstr
			_push(thread, vstr(ins["sraw"]))
		0x802: # ld
			_exec_ld(thread, frame, ins)
		0x803: # ldc.r
			_push(thread, vfloat(float(ins["fv"])))
		0x80F, 0x810: # call / callp
			_exec_call(thread, frame, ins, op == 0x810)
		0x829: # alloca
			frame["local_types"] = ins["types"]
		0x82B: # ret
			_exec_ret(thread)
		0x82C: # br (targets are relative to the instruction END, measured)
			frame["pc"] = at + int(ins["size"]) + int(ins["jo"])
		0x82D: # brtrue
			if _truthy(_pop(thread)):
				frame["pc"] = at + int(ins["size"]) + int(ins["jo"])
		0x82E: # brfalse
			if not _truthy(_pop(thread)):
				frame["pc"] = at + int(ins["size"]) + int(ins["jo"])
		0x82F: # pop
			_pop(thread)
		0x830: # br.case: intern the subject, jump to the check chain (FUN_00411620 inline + FUN_00425c00)
			thread["case_subject"] = _pop(thread)
			frame["pc"] = at + int(ins["size"]) + int(ins["jo"])
		0x831, 0x832, 0x833, 0x838, 0x839: # bXX.case: jump to next check when subject REL const(TOS, kept) holds
			_exec_case_check(thread, frame, ins, at, op)
		0x834, 0x835, 0x836, 0x837:
			if op == 0x834 or op == 0x835:
				_exec_syscall(thread, ins, op == 0x835)
			elif op == 0x836: # argcheck
				if int(frame["argc"]) != (ins["types"] as Array).size():
					errors.append("argcheck mismatch: frame argc %d vs %d" % [int(frame["argc"]), (ins["types"] as Array).size()])
			elif op == 0x837: # ldelem
				_exec_ldelem(thread, frame, ins)
		0x83A: # line
			frame["line"] = int(ins["ln"])
		0x83B: # bsel.1: register button-1 target (FUN_004133e0)
			_exec_bsel(thread, frame, ins, at, 0)
		0x83C: # bsel.3: register button-3 target (FUN_00413440, by family symmetry)
			_exec_bsel(thread, frame, ins, at, 2)
		0x83D: # bsel.2: register button-2 target (FUN_004134a0, by family symmetry)
			_exec_bsel(thread, frame, ins, at, 1)
		0x843: # bsel.x: register one target for all buttons (FUN_00413500)
			_exec_bsel_x(thread, frame, ins, at)
		0x845: # bsel.4: record an anchor target in the frame (interpreter inline)
			frame["bsel_anchor"] = at + int(ins["size"]) + int(ins["jo"])
		0x83E: # conv.i
			_push(thread, vint(i32(_as_int(_pop(thread)))))
		0x83F: # conv.r
			_push(thread, vfloat(_as_float(_pop(thread))))
		0x840: # text
			if text_gate.is_valid() and not bool(text_gate.call()):
				_gate_suspend(thread, frame, ins)
				return
			trace.append({"ev": "text", "s": ins["sraw"]})
		0x841: # proc
			if text_gate.is_valid() and not bool(text_gate.call()):
				_gate_suspend(thread, frame, ins)
				return
			trace.append({"ev": "proc"})
		0x842: # ctrl
			trace.append({"ev": "ctrl", "s": ins["sraw"]})
		0x844: # bsel.clr: clear the frame's button targets (interpreter inline)
			frame["bsel"] = [0, 0, 0]
		0x846: # bsel.jmp.4: unwind to the nearest frame holding an anchor (FUN_00413600)
			_exec_bsel_jmp4(thread)
		0x847: # bsel.5 (FUN_00413640, asm-verified): arm the current
			# frame's destructor (state slot +0x24 in the exe's frame
			# context). The destructor runs on frame return and on
			# thread kill (mjil: "@destructor").
			frame["dtor"] = at + int(ins["size"]) + int(ins["jo"])
		0x850: # switch (FUN_00413370): out-of-range index selects the LAST entry (default)
			var v := _as_int(_pop(thread))
			var cases: Array = ins["cases"]
			if cases.size() > 0:
				var idx: int = v if (v >= 0 and v < cases.size()) else cases.size() - 1
				# each case offset is relative to the end of its own entry
				frame["pc"] = at + 8 + 4 * idx + int(cases[idx])
		_:
			errors.append("unimplemented opcode 0x%03x (%s) at %s:0x%x" % [op, mn, String(frame["rec"]["name"]), at])
			_halted = true


func _exec_arith(thread: Dictionary, mn: String) -> void:
	if mn == "notl":
		_push(thread, vint(0 if _truthy(_pop(thread)) else 1))
		return
	if mn == "not":
		_push(thread, vint(i32(~_as_int(_pop(thread)))))
		return
	if mn == "neg.i":
		_push(thread, vint(i32(-_as_int(_pop(thread)))))
		return
	if mn == "neg.r":
		_push(thread, vfloat(-_as_float(_pop(thread))))
		return
	var b := _pop(thread)
	var a := _pop(thread)
	var dot := mn.rfind(".")
	var base := mn if dot < 0 else mn.substr(0, dot)
	var ty := "i" if dot < 0 else mn.substr(dot + 1)
	if base.begins_with("c"):
		var r := false
		if ty == "s":
			var x := _as_str(a)
			var y := _as_str(b)
			match base:
				"cle": r = _bytes_cmp(x, y) <= 0
				"clt": r = _bytes_cmp(x, y) < 0
				"cge": r = _bytes_cmp(x, y) >= 0
				"cgt": r = _bytes_cmp(x, y) > 0
				"ceq": r = x == y
				"cne": r = x != y
		elif ty.ends_with("arr"):
			match base:
				"ceq": r = _deep_eq(a, b)
				"cne": r = not _deep_eq(a, b)
		elif ty == "r":
			var x := _as_float(a)
			var y := _as_float(b)
			match base:
				"cle": r = x <= y
				"clt": r = x < y
				"cge": r = x >= y
				"cgt": r = x > y
				"ceq": r = x == y
				"cne": r = x != y
		else:
			var x := _as_int(a)
			var y := _as_int(b)
			match base:
				"cle": r = x <= y
				"clt": r = x < y
				"cge": r = x >= y
				"cgt": r = x > y
				"ceq": r = x == y
				"cne": r = x != y
		_push(thread, vint(1 if r else 0))
		return
	if ty == "r":
		var x := _as_float(a)
		var y := _as_float(b)
		var r := 0.0
		match base:
			"mul": r = x * y
			"div": r = x / y
			"add": r = x + y
			"sub": r = x - y
		_push(thread, vfloat(r))
		return
	if ty == "s":
		if base == "add":
			var out := PackedByteArray()
			out.append_array(_as_str(a))
			out.append_array(_as_str(b))
			_push(thread, vstr(out))
		return
	var x := _as_int(a)
	var y := _as_int(b)
	var r := 0
	match base:
		"mul": r = i32(x * y)
		"div": r = 0 if y == 0 else i32(x / y)
		"rem": r = 0 if y == 0 else i32(x % y)
		"add": r = i32(x + y)
		"sub": r = i32(x - y)
		"shr": r = i32(x >> (y & 31))
		"shl": r = i32(x << (y & 31))
		"xor": r = i32(x ^ y)
		"andl": r = 1 if (x != 0 and y != 0) else 0
		"orl": r = 1 if (x != 0 or y != 0) else 0
		"and": r = i32(x & y)
		"or": r = i32(x | y)
	_push(thread, vint(r))


func _bytes_cmp(x: PackedByteArray, y: PackedByteArray) -> int:
	var n := mini(x.size(), y.size())
	for i in range(n):
		if x[i] != y[i]:
			return -1 if x[i] < y[i] else 1
	if x.size() == y.size():
		return 0
	return -1 if x.size() < y.size() else 1


func _deep_eq(a: Dictionary, b: Dictionary) -> bool:
	if int(a["k"]) != int(b["k"]):
		return false
	if a["v"] is Array:
		var x: Array = a["v"]
		var y: Array = b["v"]
		if x.size() != y.size():
			return false
		for i in range(x.size()):
			if not _deep_eq(x[i], y[i]):
				return false
		return true
	return a["v"] == b["v"]


func _top(thread: Dictionary) -> Dictionary:
	var stack: Array = thread["stack"]
	if stack.is_empty():
		errors.append("stack underflow (peek)")
		_halted = true
		return vint(0)
	return stack[stack.size() - 1]


# bXX.case (FUN_00413970 / FUN_00413a00): compare the interned case subject
# against the constant on TOS (kept, not popped); jump to the next check
# when the named relation holds, otherwise fall through into the case body.
func _exec_case_check(thread: Dictionary, frame: Dictionary, ins: Dictionary, at: int, op: int) -> void:
	var subj: Dictionary = thread.get("case_subject", vint(0))
	var c := _top(thread)
	var cmp := 0  # sign of (subject - const)
	if int(subj["k"]) == K_STRING or int(c["k"]) == K_STRING:
		cmp = _bytes_cmp(_as_str(subj), _as_str(c))
	elif int(subj["k"]) == K_FLOAT or int(c["k"]) == K_FLOAT:
		var d := _as_float(subj) - _as_float(c)
		cmp = 0 if d == 0.0 else (1 if d > 0.0 else -1)
	else:
		var d := _as_int(subj) - _as_int(c)
		cmp = 0 if d == 0 else (1 if d > 0 else -1)
	var rel := false
	match op:
		0x831: rel = cmp != 0  # bne.case
		0x832: rel = cmp >= 0  # bge.case
		0x833: rel = cmp <= 0  # ble.case
		0x838: rel = cmp < 0   # blt.case
		0x839: rel = cmp > 0   # bgt.case
	if rel:
		frame["pc"] = at + int(ins["size"]) + int(ins["jo"])


# bsel.1/2/3 (FUN_004133e0 family): register this frame's jump target for a
# button; if the button's latch (set by the input/wait layer) is already
# set, consume it and jump immediately. Headless runs never set latches.
func _exec_bsel(thread: Dictionary, frame: Dictionary, ins: Dictionary, at: int, slot: int) -> void:
	var target := at + int(ins["size"]) + int(ins["jo"])
	var targets: Array = frame.get("bsel", [0, 0, 0])
	targets[slot] = target
	frame["bsel"] = targets
	var latch: Array = thread.get("bsel_latch", [false, false, false])
	if bool(latch[slot]):
		latch[slot] = false
		thread["bsel_latch"] = latch
		targets[slot] = 0
		frame["pc"] = target


# bsel.x (FUN_00413500): one target registered for all three buttons;
# latches are probed in the exe's order (1, 3, 2).
func _exec_bsel_x(thread: Dictionary, frame: Dictionary, ins: Dictionary, at: int) -> void:
	var target := at + int(ins["size"]) + int(ins["jo"])
	frame["bsel"] = [target, target, target]
	var latch: Array = thread.get("bsel_latch", [false, false, false])
	for slot in [0, 2, 1]:
		if bool(latch[slot]):
			latch[slot] = false
			thread["bsel_latch"] = latch
			var targets: Array = frame["bsel"]
			targets[slot] = 0
			frame["pc"] = target
			return


# bsel.jmp.4 (FUN_00413600): unwind the frame stack to the nearest frame
# holding a bsel.4 anchor and jump to it.
func _exec_bsel_jmp4(thread: Dictionary) -> void:
	var frames: Array = thread["frames"]
	for i in range(frames.size() - 1, -1, -1):
		var f: Dictionary = frames[i]
		var anchor := int(f.get("bsel_anchor", 0))
		if anchor != 0:
			f["bsel_anchor"] = 0
			thread["frames"] = frames.slice(0, i + 1)
			f["pc"] = anchor
			return


func _flags(ins: Dictionary) -> Dictionary:
	var f: int = ins["flags"]
	return {
		"modifier": f & 0x7, "invert": (f >> 3) & 0x3, "scope": (f >> 5) & 0x7,
		"type": (f >> 8) & 0x7, "dim": (f >> 11) & 0x3,
	}


func _exec_ld(thread: Dictionary, frame: Dictionary, ins: Dictionary) -> void:
	if int(ins["hash"]) == HASH_SYS_NUMPARAMS:
		_push(thread, vint(int(frame["argc"])))
		return
	var fl := _flags(ins)
	var scope: int = fl["scope"]
	var kind: int = fl["type"]
	var off: int = ins["voff"]
	if off == -2 and scope != SC_LOCAL:
		var store := _store(scope, frame)
		var cells: Variant = _cells(store, int(ins["hash"]), false)
		_push(thread, vint(0 if cells == null else (cells as Array).size()))
		return
	var val := _cell_get(scope, frame, int(ins["hash"]), off, kind)
	match int(fl["modifier"]):
		1: # preincrement
			val = _bump(val, 1)
			_cell_set(scope, frame, int(ins["hash"]), off, kind, val)
		2: # predecrement
			val = _bump(val, -1)
			_cell_set(scope, frame, int(ins["hash"]), off, kind, val)
		3: # postincrement
			_cell_set(scope, frame, int(ins["hash"]), off, kind, _bump(val, 1))
		4: # postdecrement
			_cell_set(scope, frame, int(ins["hash"]), off, kind, _bump(val, -1))
	match int(fl["invert"]):
		1:
			if int(val["k"]) == K_FLOAT:
				val = vfloat(-float(val["v"]))
			else:
				val = vint(i32(-_as_int(val)))
		2:
			val = vint(0 if _truthy(val) else 1)
		3:
			val = vint(i32(~_as_int(val)))
	_push(thread, val)


func _bump(val: Dictionary, d: int) -> Dictionary:
	if int(val["k"]) == K_FLOAT:
		return vfloat(float(val["v"]) + float(d))
	return vint(i32(_as_int(val) + d))


func _exec_store(thread: Dictionary, frame: Dictionary, ins: Dictionary, mn: String) -> void:
	var fl := _flags(ins)
	var scope: int = fl["scope"]
	var hash: int = ins["hash"]
	var off: int = ins["voff"]
	var kind: int = fl["type"]
	var pop_after := mn.begins_with("stp.") or mn.begins_with("stelemp.")
	var is_elem := mn.begins_with("stelem")
	var rest := mn.substr(mn.find(".") + 1)
	var opty := rest
	if rest.find(".") >= 0:
		opty = rest.substr(0, rest.find("."))
	var stack: Array = thread["stack"]
	if is_elem:
		var dim: int = maxi(int(fl["dim"]), 1)
		var idxs: Array = []
		for i in range(dim):
			idxs.push_front(_as_int(_pop(thread)))
		var val: Dictionary = stack[stack.size() - 1]
		_elem_set(scope, frame, hash, off, kind, idxs, _apply_op(opty, _elem_get(scope, frame, hash, off, kind, idxs), val))
		if pop_after:
			_pop(thread)
		return
	var val2: Dictionary = stack[stack.size() - 1]
	if opty == "" or rest == opty:
		_cell_set(scope, frame, hash, off, kind, val2)
	else:
		_cell_set(scope, frame, hash, off, kind, _apply_op(opty, _cell_get(scope, frame, hash, off, kind), val2))
	if pop_after:
		_pop(thread)


func _elem_get(scope: int, frame: Variant, hash: int, off: int, kind: int, idxs: Array) -> Dictionary:
	var root := _cell_get(scope, frame, hash, off, K_IARR)
	if not (root["v"] is Array):
		return vdefault(kind)
	var node: Variant = root
	for ix in idxs:
		if not (node is Dictionary) or not (node["v"] is Array):
			return vdefault(kind)
		var arr: Array = node["v"]
		if ix < 0 or ix >= arr.size():
			return vdefault(kind)
		node = arr[ix]
	return node


func _elem_set(scope: int, frame: Variant, hash: int, off: int, kind: int, idxs: Array, val: Dictionary) -> void:
	var root := _cell_get(scope, frame, hash, off, K_IARR)
	if not (root["v"] is Array):
		root = varr(K_IARR, [])
	var node: Dictionary = root
	for n in range(idxs.size()):
		var ix: int = idxs[n]
		var arr: Array = node["v"]
		while arr.size() <= ix:
			arr.append(vdefault(K_IARR if n < idxs.size() - 1 else kind))
		if n == idxs.size() - 1:
			arr[ix] = val
		else:
			node = arr[ix]
	_cell_set(scope, frame, hash, off, K_IARR, root)


func _exec_ldelem(thread: Dictionary, frame: Dictionary, ins: Dictionary) -> void:
	var fl := _flags(ins)
	var dim: int = maxi(int(fl["dim"]), 1)
	var idxs: Array = []
	for i in range(dim):
		idxs.push_front(_as_int(_pop(thread)))
	_push(thread, _elem_get(int(fl["scope"]), frame, int(ins["hash"]), int(ins["voff"]), int(fl["type"]), idxs))


func _apply_op(opty: String, cur: Dictionary, val: Dictionary) -> Dictionary:
	if opty == "" or opty in ["i", "r", "s", "iarr", "rarr", "sarr"]:
		return val
	if int(val["k"]) == K_FLOAT or int(cur["k"]) == K_FLOAT:
		var x := _as_float(cur)
		var y := _as_float(val)
		match opty:
			"mul": return vfloat(x * y)
			"div": return vfloat(x / y)
			"add": return vfloat(x + y)
			"sub": return vfloat(x - y)
		return val
	if opty == "add" and (int(val["k"]) == K_STRING or int(cur["k"]) == K_STRING):
		var out := PackedByteArray()
		out.append_array(_as_str(cur))
		out.append_array(_as_str(val))
		return vstr(out)
	var x := _as_int(cur)
	var y := _as_int(val)
	match opty:
		"mul": return vint(i32(x * y))
		"div": return vint(0 if y == 0 else i32(x / y))
		"rem": return vint(0 if y == 0 else i32(x % y))
		"add": return vint(i32(x + y))
		"sub": return vint(i32(x - y))
		"shl": return vint(i32(x << (y & 31)))
		"shr": return vint(i32(x >> (y & 31)))
		"and": return vint(i32(x & y))
		"xor": return vint(i32(x ^ y))
		"or": return vint(i32(x | y))
	return val


func _exec_call(thread: Dictionary, frame: Dictionary, ins: Dictionary, pop_result: bool) -> void:
	var hash: int = ins["hash"]
	var argc: int = ins["ac"]
	var hit: Variant = _resolve(hash, frame["rec"])
	stats["calls"] = int(stats["calls"]) + 1
	if hit == null:
		errors.append("call to unresolved function 0x%08x" % hash)
		_halted = true
		return
	_push_frame(thread, hit["rec"], int(hit["offset"]), argc, int(frame["pc"]))
	# mark how to treat the return value via a frame flag
	var frames: Array = thread["frames"]
	frames[frames.size() - 1]["pop_result"] = pop_result


func _exec_ret(thread: Dictionary) -> void:
	var frames: Array = thread["frames"]
	var top_frame: Dictionary = frames[frames.size() - 1]
	if int(top_frame.get("dtor", 0)) != 0 and not bool(top_frame.get("in_dtor", false)):
		# Run the frame's bsel.5 destructor instead of returning:
		# the frame stays live (its locals/args are the destructor's
		# context); the destructor's own ret completes the return.
		top_frame["in_dtor"] = true
		top_frame["pc"] = int(top_frame["dtor"])
		return
	var frame: Dictionary = frames.pop_back()
	var stack: Array = thread["stack"]
	var base: int = frame["base"]
	var result := vint(0)
	if stack.size() > base + int(frame["argc"]):
		result = stack[stack.size() - 1]
	while stack.size() > base:
		stack.pop_back()
	if frames.is_empty():
		thread["done"] = true
		return
	if not bool(frame.get("pop_result", false)):
		stack.append(result)
	var caller: Dictionary = frames[frames.size() - 1]
	caller["pc"] = int(frame["ret_pc"])


func _exec_syscall(thread: Dictionary, ins: Dictionary, pop_result: bool) -> void:
	var hash: int = ins["hash"]
	var argc: int = ins["ac"]
	var stack: Array = thread["stack"]
	var args: Array = []
	if stack.size() < argc:
		errors.append("SYSCALL ARG UNDERFLOW hash=0x%08x argc=%d stack=%d ring=%s" % [hash, argc, stack.size(), " | ".join(debug_ring.slice(maxi(0, debug_ring.size() - 6)))])
		_halted = true
		return
	for i in range(argc):
		args.append(stack[stack.size() - argc + i])
	for i in range(argc):
		stack.pop_back()
	stats["syscalls"] = int(stats["syscalls"]) + 1
	var result := vint(0)
	var transferred := false
	if hash == HASH_LOAD_LIBRARY or hash == HASH_LOAD_LIBRARY2:
		if args.size() >= 1 and int(args[0]["k"]) == K_STRING:
			var nm := (args[0]["v"] as PackedByteArray).get_string_from_ascii()
			var first_load := not _by_name.has(nm)
			var lib: Variant = load_script(nm)
			if lib != null:
				result = vint(1)
				# Engine behavior: loading a library also boots its
				# $$main entrypoint as a resident thread -- the
				# console record builds its window pages/sprites
				# there, pic's main stores the frontbuffer handle,
				# etc. Resolve-only loading left the console dead
				# (console_set never fired; found 2026-11-05).
				if first_load and not _lib_mains_started.has(nm):
					_lib_mains_started[nm] = true
					var lt := {"stack": [], "frames": [], "tvars": {},
							"done": false, "wait": 0}
					_threads.append(lt)
					_push_frame(lt, lib, (lib["mjo"] as MajiroMjo).entrypoint_offset, 0, -1)
	elif hash == HASH_THREAD_BEGIN or hash == HASH_THREAD_BEGIN_CHILD:
		result = _thread_begin(thread, args)
	elif hash == HASH_THREAD_END:
		_thread_end(thread, args)
	elif hash == HASH_EXEC:
		transferred = _exec_script(thread, args)
	elif hash == 0x1BB47604 or hash == 0x4D849AA6 or hash == 0xF8004993 or hash == 0x44B5C4ED:
		# save_enable / save_menu_enable / save_point / save_menu_disable:
		# save-system
		# bookkeeping flags; no presentation effect in the player yet.
		pass
	elif hash == HASH_SCRIPT_CALL:
		transferred = _call_script(thread, args)
	elif hash == 0x6E83677A:
		# get_variable(name$): variable access by source name;
		# the compiled hash is plain CRC-32 over the name bytes
		# (verified: crc32("#musicvol@CONFIG") == 0x5731EA89).
		result = _variable_by_name(args, false)
	elif hash == 0xCD290AEF:
		# set_variable(name$, value)
		_variable_by_name(args, true)
	elif syscalls.has(hash):
		var rargs: Array = args.duplicate()
		rargs.reverse()
		result = (syscalls[hash] as Callable).call(rargs)
	else:
		unknown_syscalls["0x%08x" % hash] = true
	if thread.get("syscall_restore", false):
		# The handler suspended this thread (pc already rewound by the
		# host): restore the argument slice so the re-executed syscall
		# sees the same stack as the first pass.
		thread.erase("syscall_restore")
		for a in args:
			stack.append(a)
	elif not pop_result and not transferred:
		stack.append(result)


## exec(filename, rest...): transfer the calling thread's execution
## to the named script's entrypoint (exe FUN_0040ff60). The filename
## is the top stack value; the remaining arguments stay on the value
## stack as the new script's initial argument slice, the current
## call stack is abandoned, and the script stores carry over. The
## new script's code runs in this same thread. Returns true when the
## transfer happened (the caller must not push a syscall result).
func _exec_script(thread: Dictionary, args: Array) -> bool:
	if args.is_empty() or int(args[args.size() - 1]["k"]) != K_STRING:
		return false
	var nm := MajiroText.decode_cp932(args[args.size() - 1]["v"] as PackedByteArray)
	var rec: Variant = load_script(nm)
	if rec == null and nm != nm.to_lower():
		rec = load_script(nm.to_lower())
	if rec == null:
		errors.append("exec: script not found: " + nm)
		return false
	var extras: Array = args.slice(0, args.size() - 1)
	thread["frames"] = []
	thread["stack"] = extras.duplicate()
	thread["done"] = false
	thread["wait"] = 0
	_push_frame(thread, rec, (rec["mjo"] as MajiroMjo).entrypoint_offset, extras.size(), -1)
	# The engine fires its built-in HOT_RESET event on a scenario
	# transfer: console/pic/menu/yazlib records re-initialise from
	# it (for the console: console_renewal reloads sysdata.cfg).
	# Nobody in the scripts fires it; it is the exe's own event
	# (found 2026-11-05). Args (is_load=0, name, 0): the fresh
	# branch of $$hot_reset@CONSOLE uses the literal sysdata.cfg.
	if event_sink.is_valid():
		event_sink.call("HOT_RESET", [vint(0), vstr(PackedByteArray()), vint(0)])
	return true


## call(filename, rest...): call the named script's entrypoint as a
## subroutine (exe FUN_0040fc30). The filename is the top stack
## value; the remaining arguments become the callee frame's argument
## slice; when the callee's top-level code returns, execution
## resumes in the caller and the return value propagates through
## the normal ret path. This is how the scenario master script
## (starless.mjo) sequences its chapter records. Returns true when
## the frame was pushed (the caller must not push a syscall result).
func _call_script(thread: Dictionary, args: Array) -> bool:
	if args.is_empty() or int(args[args.size() - 1]["k"]) != K_STRING:
		return false
	var nm := MajiroText.decode_cp932(args[args.size() - 1]["v"] as PackedByteArray)
	var rec: Variant = load_script(nm)
	if rec == null and nm != nm.to_lower():
		rec = load_script(nm.to_lower())
	if rec == null:
		errors.append("call: script not found: " + nm)
		return false
	var extras: Array = args.slice(0, args.size() - 1)
	var stack: Array = thread["stack"]
	for a in extras:
		stack.append(a)
	var frames: Array = thread["frames"]
	var ret_pc := -1
	if not frames.is_empty():
		ret_pc = int(frames[frames.size() - 1]["pc"])
	_push_frame(thread, rec, (rec["mjo"] as MajiroMjo).entrypoint_offset, extras.size(), ret_pc)
	return true


var _next_tid := 1


# thread_begin(func_args..., function_hash) -> thread id.
# The function's name hash is the LAST argument (an ldc.i immediate);
# the preceding arguments become the new thread's call arguments.


func _thread_begin(_parent: Dictionary, args: Array) -> Dictionary:
	if args.is_empty():
		return vint(0)
	var hash := _as_int(args[args.size() - 1]) & 0xFFFFFFFF
	var fargs: Array = args.slice(0, args.size() - 1)
	var frames0: Array = _cur["frames"]
	var cur_rec: Variant = frames0[frames0.size() - 1]["rec"] if not frames0.is_empty() else null
	var hit: Variant = _resolve(hash, cur_rec)
	if hit == null:
		errors.append("thread_begin: unresolved function 0x%08x" % hash)
		return vint(0)
	var tid := _next_tid
	_next_tid += 1
	var t := {"stack": [], "frames": [], "tvars": {}, "done": false, "wait": 0, "tid": tid}
	for a in fargs:
		(t["stack"] as Array).append(a)
	_threads.append(t)
	var saved := _cur
	_cur = t
	_push_frame(t, hit["rec"], int(hit["offset"]), fargs.size(), -1)
	_cur = saved
	return vint(tid)


## CRC-32 (IEEE, reflected) over raw bytes -- the Majiro name hash.
static func _crc32(data: PackedByteArray) -> int:
	var crc := 0xFFFFFFFF
	for b in data:
		crc ^= int(b)
		for i in 8:
			crc = (crc >> 1) ^ (0xEDB88320 if (crc & 1) != 0 else 0)
	return int((crc ^ 0xFFFFFFFF) & 0xFFFFFFFF)


## get_variable / set_variable: `args` arrive in stack (push) order,
## so the name string is the LAST element; for set, the value is the
## first. '#' names live in the persistent synth store, others in
## the savefile synth store; an existing cell wins over the sigil.
func _variable_by_name(args: Array, is_set: bool) -> Dictionary:
	if args.is_empty() or int(args[args.size() - 1]["k"]) != K_STRING:
		return vint(0)
	var nm := args[args.size() - 1]["v"] as PackedByteArray
	var hash := _crc32(nm)
	var sigil_persist := not nm.is_empty() and int(nm[0]) == 0x23  # '#'
	if is_set:
		if args.size() < 2:
			return vint(0)
		var val: Dictionary = args[0]
		if _persist_synth.has(hash) or (sigil_persist and not _save_synth.has(hash)):
			_persist_synth[hash] = val
		else:
			_save_synth[hash] = val
		return vint(0)
	if _persist_synth.has(hash):
		return _persist_synth[hash]
	if _save_synth.has(hash):
		return _save_synth[hash]
	return vint(0)


func _thread_end(thread: Dictionary, args: Array) -> void:
	var tid := _as_int(args[0]) if not args.is_empty() else int(thread.get("tid", 0))
	if tid == int(thread.get("tid", 0)):
		thread["done"] = true
		return
	for t in _threads:
		if int(t.get("tid", -1)) == tid:
			_kill_thread(t)
			return


## Terminate a thread: an armed bsel.5 destructor on its top frame
## runs first (the thread resumes at the destructor and ends when
## its frames unwind); otherwise the thread just ends.
func _kill_thread(t: Dictionary) -> void:
	var frames: Array = t["frames"]
	if not frames.is_empty():
		var fr: Dictionary = frames[frames.size() - 1]
		if int(fr.get("dtor", 0)) != 0 and not bool(fr.get("in_dtor", false)):
			fr["in_dtor"] = true
			fr["pc"] = int(fr["dtor"])
			t["wait"] = 0
			t.erase("syscall_restore")
			return
	t["done"] = true


## Host-side entry for engine callbacks (areaevent, console_on, ...):
## starts a fresh thread running the script function `hash` with
## `args` given in SOURCE order (first parameter first), mirroring
## thread_begin without the trailing-hash argument convention.
## _thread_begin expects the arguments in stack (push) order, which
## is source order reversed -- passing them through unreversed made
## every host-spawned callback receive its arguments flipped (the
## buttonmenu click handler stored yl=30 as the selected item id,
## so menu selections never latched; found via the event probes).
func spawn_function(hash: int, args: Array) -> int:
	var full: Array = args.duplicate()
	full.reverse()
	full.append(vint(hash))
	return _as_int(_thread_begin(_cur, full))
