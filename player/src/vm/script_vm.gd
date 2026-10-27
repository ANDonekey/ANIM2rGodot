class_name ScriptVM
extends RefCounted
## sce bytecode interpreter. Spec: docs/sce-format.md.
##
## Execution model: run_until_event() executes records until a
## presentable event (say / narrate / choice) is ready, collecting stage
## effects into pending_effects on the way. Semantics were pinned against
## an independent Python autoplay oracle on the sample game
## (tests/test_vm.gd compares the full canonical event stream).
##
## Engine-mapped flag reads (measured from the Loop / SleepTime /
## ClickWait / SeWait subroutines in the sample script):
##   0xA2 (bank, idx)        flag <- clock_ms()
##   0xA9 (bank, idx)        flag <- advance latch (ClickWait)
##   0xA4 (bank, idx)        flag <- advance latch (wait abort)
##   0xA3 (ch, bank, idx)    flag <- channel playing state (SeWait)
##   0x22/0xA5/0xA6          flag <- 0 (v1: state queries not modeled)
## In virtual_clock mode (tests / autoplay) the clock advances 33 ms per
## 0xA2 and the advance latch always reads 1, mirroring the oracle.

const STEP_BUDGET := 200000

var sce: SceScript
var flags_local: PackedInt64Array
var flags_global: PackedInt64Array
var pc: int = 0
var call_stack: Array = []
var finished: bool = false
var pending_effects: Array = []

var virtual_clock: bool = false
var advance_requested: bool = false  # realtime advance latch (consumed)
var skip_mode: bool = false
var channel_playing: bool = false  # realtime SeWait source

var _vclock: int = 0
var _boot_ticks: int = 0
var _choice_dests: Array = []  # record indices per option of pending choice


func _init(p_script: SceScript = null) -> void:
	_boot_ticks = Time.get_ticks_msec()
	sce = p_script
	flags_local = PackedInt64Array()
	flags_local.resize(65536)
	flags_global = PackedInt64Array()
	flags_global.resize(65536)
	if sce != null and sce.record_index.has(8):
		pc = sce.record_index[8]


func _flags(bank_byte: int) -> PackedInt64Array:
	return flags_local if bank_byte == 0x40 else flags_global


func _eval(e: Array) -> int:
	if e[0] == "flag":
		return _flags(e[1])[e[2]]
	var v: int = e[2]
	return v - 4294967296 if v >= 2147483648 else v


static func _cdiv(a: int, b: int) -> int:
	if b == 0:
		return 0
	return a / b  # GDScript int division truncates toward zero (C-like)


static func _cmod(a: int, b: int) -> int:
	if b == 0:
		return 0
	return a - (a / b) * b


func _now() -> int:
	if virtual_clock:
		_vclock += 33
		return _vclock
	return Time.get_ticks_msec() - _boot_ticks


func _take_advance() -> int:
	if virtual_clock:
		return 1
	if advance_requested:
		advance_requested = false
		return 1
	return 0


func _effect(kind: String, fields: Dictionary = {}) -> void:
	var e := {"kind": kind}
	e.merge(fields)
	pending_effects.append(e)


## Drain and return the stage effects collected since the last call.
func drain_effects() -> Array:
	var out := pending_effects
	pending_effects = []
	return out


## Analyze the case-block pattern after a Select record (same shape the
## Ren'Py converter verified 50/50): [0xC9 k][goto dest][goto END] * n.
## Returns [dests (offsets), end_record_index] or [] when unstructured.
func _select_block(rec_i: int, n_pairs: int) -> Array:
	var recs := sce.records
	var j := rec_i + 1
	var dests: Array = []
	var end_off := -1
	for k in n_pairs:
		if j + 2 >= recs.size():
			return []
		if recs[j].op != 0xC9 or recs[j].ops[0] != k + 1:
			return []
		var g1: SceScript.Rec = recs[j + 1]
		var g2: SceScript.Rec = recs[j + 2]
		if g1.op != 0x0B or g2.op != 0x0B:
			return []
		if end_off == -1:
			end_off = g2.ops[0]
		elif g2.ops[0] != end_off:
			return []
		dests.append(g1.ops[0])
		j += 3
	if j >= recs.size() or recs[j].off != end_off:
		return []
	return [dests, j]


## After a {"kind": "choice"} event, pick option `k` (0-based).
func choose(k: int) -> void:
	if k >= 0 and k < _choice_dests.size():
		pc = _choice_dests[k]


func run_until_event() -> Dictionary:
	if finished:
		return {"kind": "end"}
	var steps := 0
	# In realtime mode, yield quickly during waits (the caller retries
	# next frame with an advanced clock); virtual mode runs through.
	var budget := STEP_BUDGET if virtual_clock else 4000
	while pc >= 0 and pc < sce.records.size():
		steps += 1
		if steps > budget:
			return {"kind": "stall", "pc": pc}
		var r: SceScript.Rec = sce.records[pc]
		var op := r.op
		var ops := r.ops
		match op:
			0x0B:  # Goto
				pc = sce.record_index[ops[0]]
			0x0C:  # Gosub
				call_stack.append(pc + 1)
				pc = sce.record_index[ops[0]]
			0x0D:  # Return
				if call_stack.is_empty():
					finished = true
					return {"kind": "end"}
				pc = call_stack.pop_back()
			0x1E:  # FlagSet
				_flags(ops[0])[ops[1]] = _eval(ops[2])
				pc += 1
			0x19, 0x1A, 0x1B, 0x1C, 0x1D:  # Add/Sub/Mul/Div/Mod
				var f := _flags(ops[0])
				var cur: int = f[ops[1]]
				var v := _eval(ops[2])
				match op:
					0x19: cur += v
					0x1A: cur -= v
					0x1B: cur *= v
					0x1C: cur = _cdiv(cur, v)
					0x1D: cur = _cmod(cur, v)
				f[ops[1]] = cur
				pc += 1
			0x26:  # FlagRand (stubbed to lower bound in virtual mode)
				_flags(ops[0])[ops[1]] = ops[2] if virtual_clock else randi_range(ops[2], ops[3])
				pc += 1
			0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F:
				var lhs: int = _flags(ops[0])[ops[1]]
				var rhs := _eval(ops[2])
				var c := (op - 0x27) % 6
				var take := false
				match c:
					0: take = lhs == rhs
					1: take = lhs != rhs
					2: take = lhs < rhs
					3: take = lhs > rhs
					4: take = lhs <= rhs
					5: take = lhs >= rhs
				pc = sce.record_index[ops[3]] if take else pc + 1
			0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32:  # conditional Gosub (inferred)
				var lhs2: int = _flags(ops[0])[ops[1]]
				var rhs2 := _eval(ops[2])
				var c2 := op - 0x2D
				var take2 := false
				match c2:
					0: take2 = lhs2 == rhs2
					1: take2 = lhs2 != rhs2
					2: take2 = lhs2 < rhs2
					3: take2 = lhs2 > rhs2
					4: take2 = lhs2 <= rhs2
					5: take2 = lhs2 >= rhs2
				if take2:
					call_stack.append(pc + 1)
					pc = sce.record_index[ops[3]]
				else:
					pc += 1
			0xA2:  # clock -> flag
				_flags(ops[0])[ops[1]] = _now()
				pc += 1
			0xA9:  # advance latch (ClickWait)
				_flags(ops[0])[ops[1]] = _take_advance()
				pc += 1
			0xA4:  # wait-abort latch (oracle: 0 in virtual mode)
				_flags(ops[0])[ops[1]] = 0 if virtual_clock else _take_advance()
				pc += 1
			0xA3:  # channel playing state -> flag (ops: u16 ch, bank, idx)
				_flags(ops[1])[ops[2]] = 1 if channel_playing else 0
				pc += 1
			0x22, 0xA5, 0xA6:  # state queries, unmodeled in v1
				_flags(ops[0])[ops[1]] = 0
				pc += 1
			0xC0, 0xC8:  # Select
				var pairs: Array = ops[0][1]
				var blk := _select_block(pc, pairs.size())
				if blk.is_empty():
					_effect("select_broken")
					pc += 1
				else:
					_choice_dests = []
					for d in blk[0]:
						_choice_dests.append(sce.record_index[d])
					var options: Array = []
					for pr in pairs:
						options.append({"value": pr[0], "text": sce.pool_str(pr[1])})
					pc += 1  # past the Select; choose() repositions anyway
					return {"kind": "choice", "options": options}
			0xD2:  # voiced dialogue
				pc += 1
				return {"kind": "say", "speaker": sce.pool_str(ops[1]),
						"text": sce.pool_str(ops[2]), "voice": sce.pool_str(ops[0])}
			0xD3, 0xD4:  # dialogue
				pc += 1
				return {"kind": "say", "speaker": sce.pool_str(ops[0]),
						"text": sce.pool_str(ops[1]), "voice": ""}
			0xD5:  # narration
				pc += 1
				return {"kind": "narrate", "text": sce.pool_str(ops[0])}
			0xD6:  # text block (absent in sample; entries queued as says)
				pc += 1
				var speaker := ""
				for e in ops[0][1]:
					if e[0] == "speaker":
						speaker = sce.pool_str(e[1])
					else:
						pending_effects.append({"kind": "say_block", "speaker": speaker,
								"text": sce.pool_str(e[2])})
			0x4B:
				_effect("image", {"name": sce.pool_str(ops[0])})
				pc += 1
			0x21:
				_effect("movie", {"name": sce.pool_str(ops[0])})
				pc += 1
			0x8E, 0x8F:
				_effect("movie", {"name": sce.pool_str(ops[1])})
				pc += 1
			0x82:
				_effect("bgm_play", {"track": ops[0]})
				pc += 1
			0x83:
				_effect("bgm_stop")
				pc += 1
			0x84:
				_effect("bgm_fade", {"ms": ops[0]})
				pc += 1
			0x88:
				_effect("voice_play", {"name": sce.pool_str(ops[1])})
				pc += 1
			0x8B:
				_effect("voice_stop", {"name": sce.pool_str(ops[1])})
				pc += 1
			0x52:
				_effect("emote_load", {"slot": _eval(ops[0]), "name": sce.pool_str(ops[1])})
				pc += 1
			0x57:
				_effect("emote_unload", {"slot": _eval(ops[0])})
				pc += 1
			0x5F:
				_effect("emote_load_hc", {"slot": _eval(ops[0]), "name": sce.pool_str(ops[1])})
				pc += 1
			0x61:
				_effect("emote_hc2", {"slot": _eval(ops[0]), "a": ops[1], "b": ops[2]})
				pc += 1
			0x7C:
				_effect("emote_pose", {"slot": _eval(ops[0]), "label": sce.pool_str(ops[1]), "time": ops[2]})
				pc += 1
			0x16:
				_effect("snapshot", {"slot": ops[0]})
				pc += 1
			0x1F:
				_effect("gallery", {"name": sce.pool_str(ops[0])})
				pc += 1
			0x65:
				_effect("trans_begin")
				pc += 1
			0x66:
				_effect("trans_end")
				pc += 1
			0x67, 0x68:
				_effect("paramset", {"id": ops[0], "value": ops[1],
						"tail": ops[2] if ops.size() > 2 else []})
				pc += 1
			0xAC:
				_effect("bgv", {"x": _eval(ops[0]), "y": _eval(ops[1])})
				pc += 1
			0xDC:
				_effect("scene_end")
				pc += 1
			_:
				pc += 1
	finished = true
	return {"kind": "end"}
