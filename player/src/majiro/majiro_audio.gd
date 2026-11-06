class_name MajiroAudio
extends Node
## Sound host for MajiroVm (design spec section 7): four fixed SE
## channels (sound..sound4) plus the programmable sound_ch, voice
## (+voice_ch), and the music BGM channel with its push/pop stack.
##
## Resources are native OGG (voice.arc / data arcs). Volumes use
## the engine's 0..255 scale. *_wait syscalls suspend the calling
## thread on the VM's wait flag until the channel goes silent.

var vm: MajiroVm
var vfs: MajiroVfs
var stub_calls := {}

var _players := {}    # key -> {node, name (raw bytes), disp, loop, vol, fade}
var _stream_cache := {}
var _music_stack: Array = []
var family_vol := {"se": 255, "voice": 255, "music": 255}
var _time := 0.0


func bind(p_vm: MajiroVm, p_vfs: MajiroVfs) -> void:
	vm = p_vm
	vfs = p_vfs


func _process(delta: float) -> void:
	_time += delta
	for key in _players:
		var rec: Dictionary = _players[key]
		var fade: Dictionary = rec["fade"]
		if not fade.is_empty():
			var t := 1.0
			if int(fade["dur"]) > 0:
				t = clampf((_time - float(fade["start"])) / (float(fade["dur"]) / 1000.0), 0.0, 1.0)
			rec["vol"] = lerpf(float(fade["from"]), float(fade["to"]), t)
			_apply_vol(key)
			if t >= 1.0:
				rec["fade"] = {}
				if int(fade["to"]) == 0 and bool(fade.get("stop", false)):
					(rec["node"] as AudioStreamPlayer).stop()
	if vm != null:
		for t in vm._threads:
			if int(t.get("wait", 0)) != 0 and t.has("aud_wait"):
				var rec2: Variant = _players.get(String(t["aud_wait"]), null)
				if rec2 == null or not (rec2["node"] as AudioStreamPlayer).playing:
					t.erase("aud_wait")
					t["wait"] = 0


func _record(hash: int) -> Callable:
	return func(_a: Array) -> Dictionary:
		stub_calls[hash] = int(stub_calls.get(hash, 0)) + 1
		return MajiroVm.vint(0)


static func _ai(v: Dictionary) -> int:
	return MajiroStage._ai(v)


static func _ab(v: Dictionary) -> PackedByteArray:
	return MajiroStage._ab(v)


func _ch(key: String, family: String) -> Dictionary:
	if _players.has(key):
		return _players[key]
	var node := AudioStreamPlayer.new()
	add_child(node)
	var rec := {"node": node, "name": PackedByteArray(), "disp": "",
			"loop": false, "vol": 255, "fade": {}, "family": family}
	_players[key] = rec
	return rec


func _family_of(key: String) -> String:
	if key.begins_with("voice"):
		return "voice"
	if key == "music":
		return "music"
	return "se"


func _apply_vol(key: String) -> void:
	var rec: Dictionary = _players[key]
	var lin := clampf(float(rec["vol"]) / 255.0, 0.0, 1.0) \
			* clampf(float(family_vol[_family_of(key)]) / 255.0, 0.0, 1.0)
	(rec["node"] as AudioStreamPlayer).volume_db = linear_to_db(maxf(lin, 0.0001)) if lin > 0.0 else -80.0


func _load_stream(raw_name: PackedByteArray) -> AudioStream:
	var disp := MajiroText.decode_cp932(raw_name)
	if _stream_cache.has(disp):
		return _stream_cache[disp]
	var bytes := vfs.read_file_bytes(raw_name)
	if bytes.is_empty():
		for ext in [".ogg", ".mp3", ".wav"]:
			var cand: PackedByteArray = raw_name + ext.to_ascii_buffer()
			bytes = vfs.read_file_bytes(cand)
			if not bytes.is_empty():
				break
	var stream: AudioStream = null
	if not bytes.is_empty():
		stream = AudioStreamOggVorbis.load_from_buffer(bytes)
		if stream == null:
			stream = AudioStreamMP3.load_from_buffer(bytes)
		if stream == null:
			var wav := AudioStreamWAV.new()
			wav.data = bytes
			wav.format = AudioStreamWAV.FORMAT_16_BITS
			wav.mix_rate = 44100
			stream = wav
	_stream_cache[disp] = stream
	return stream


func _play(key: String, raw_name: PackedByteArray, loop: bool) -> void:
	var rec := _ch(key, _family_of(key))
	var stream := _load_stream(raw_name)
	rec["name"] = raw_name
	rec["disp"] = MajiroText.decode_cp932(raw_name)
	rec["loop"] = loop
	rec["fade"] = {}
	var node: AudioStreamPlayer = rec["node"]
	node.stream = stream
	if stream is AudioStreamOggVorbis:
		# LoopMode: 0 = disabled, 1 = forward (set dynamically: the
		# property is a typed enum and rejects plain int assignment)
		stream.set("loop_mode", 1 if loop else 0)
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = loop
	_apply_vol(key)
	if stream != null:
		node.play()


func _stop(key: String) -> void:
	var rec := _ch(key, _family_of(key))
	(rec["node"] as AudioStreamPlayer).stop()
	rec["fade"] = {}


func _fade(key: String, to_vol: int, ms: int, stop_at_zero: bool) -> void:
	var rec := _ch(key, _family_of(key))
	if ms <= 0:
		rec["vol"] = clampi(to_vol, 0, 255)
		rec["fade"] = {}
		_apply_vol(key)
		if to_vol == 0 and stop_at_zero:
			(rec["node"] as AudioStreamPlayer).stop()
		return
	rec["fade"] = {"from": int(rec["vol"]), "to": clampi(to_vol, 0, 255),
			"start": _time, "dur": ms, "stop": stop_at_zero}


func _suspend_until_silent(key: String) -> Dictionary:
	var rec := _ch(key, _family_of(key))
	if not (rec["node"] as AudioStreamPlayer).playing:
		return MajiroVm.vint(0)
	var t: Dictionary = vm._cur
	t["wait"] = 1
	t["aud_wait"] = key
	var frames: Array = t["frames"]
	if not frames.is_empty():
		var fr: Dictionary = frames[frames.size() - 1]
		fr["pc"] = int(fr["pc"]) - 8
	t["syscall_restore"] = true
	return MajiroVm.vint(0)


func _play_fixed(idx: int) -> Callable:
	return func(a: Array) -> Dictionary:
		if a.size() >= 1:
			_play("se:%d" % idx, _ab(a[0]), _ai(a[1]) != 0 if a.size() >= 2 else false)
		return MajiroVm.vint(0)


func _play_ch(a: Array) -> Dictionary:
	# sound_ch(ch, name$[, loop])
	if a.size() >= 2:
		_play("se:%d" % _ai(a[0]), _ab(a[1]), _ai(a[2]) != 0 if a.size() >= 3 else false)
	return MajiroVm.vint(0)


func _stop_fixed(idx: int) -> Callable:
	return func(_a: Array) -> Dictionary: _stop("se:%d" % idx); return MajiroVm.vint(0)


func _vol_fixed(idx: int) -> Callable:
	return func(a: Array) -> Dictionary:
		var rec := _ch("se:%d" % idx, "se")
		rec["vol"] = clampi(_ai(a[0]), 0, 255) if not a.is_empty() else 255
		_apply_vol("se:%d" % idx)
		return MajiroVm.vint(0)


func _stat_fixed(idx: int) -> Callable:
	return func(_a: Array) -> Dictionary:
		var rec := _ch("se:%d" % idx, "se")
		return MajiroVm.vint(1 if (rec["node"] as AudioStreamPlayer).playing else 0)


func _wait_fixed(idx: int) -> Callable:
	return func(_a: Array) -> Dictionary: return _suspend_until_silent("se:%d" % idx)


func _fade_fixed(idx: int, out: bool) -> Callable:
	return func(a: Array) -> Dictionary:
		if out:
			_fade("se:%d" % idx, 0, _ai(a[0]) if not a.is_empty() else 0, true)
		else:
			_fade("se:%d" % idx, _ai(a[0]) if not a.is_empty() else 255,
					_ai(a[1]) if a.size() >= 2 else 0, false)
		return MajiroVm.vint(0)


func _getfn_fixed(idx: int) -> Callable:
	return func(_a: Array) -> Dictionary:
		var rec := _ch("se:%d" % idx, "se")
		return MajiroVm.vstr(rec["name"])


func _isloop_fixed(idx: int) -> Callable:
	return func(_a: Array) -> Dictionary:
		var rec := _ch("se:%d" % idx, "se")
		return MajiroVm.vint(1 if bool(rec["loop"]) else 0)


func attach() -> void:
	var s := vm.syscalls
	# fixed SE channels: sound, sound2, sound3, sound4
	var play_h := [0xF62E3CA7, 0x708B0256, 0xED84E320, 0x884949E0]
	var stop_h := [0x83A53FFA, 0x546F69C3, 0x838DE99B, 0xC9B362D0]
	var vol_h := [0x201D3D29, 0xE799EAC8, 0x08CB5C29, 0xE9E5564D]
	var stat_h := [0x777AA894, 0xA0B0FEAD, 0x77527EF5, 0x3D6CF5BE]
	var wait_h := [0x5785A054, 0x804FF66D, 0x57AD7635, 0x1D93FD7E]
	var fade_h := [0xC0C15D7C, 0x170B0B45, 0xC0E98B1D, 0x8AD70056]
	var fout_h := [0x926C13E5, 0x2E861C51, 0x39AE7891, 0x5C7746D1]
	var getfn_h := [0x5BF8F175, 0xE712FEC1, 0xF03A9A01, 0x95E3A441]
	var isloop_h := [0x5C4020E6, 0xE0AA2F52, 0xF7824B92, 0x925B75D2]
	for i in range(4):
		s[play_h[i]] = _play_fixed(i)
		s[stop_h[i]] = _stop_fixed(i)
		s[vol_h[i]] = _vol_fixed(i)
		s[stat_h[i]] = _stat_fixed(i)
		s[wait_h[i]] = _wait_fixed(i)
		s[fade_h[i]] = _fade_fixed(i, false)
		s[fout_h[i]] = _fade_fixed(i, true)
		s[getfn_h[i]] = _getfn_fixed(i)
		s[isloop_h[i]] = _isloop_fixed(i)
		s[[0x7F918815, 0xB8155FF4, 0x5747E915, 0xB669E371][i]] = _record([0x7F918815, 0xB8155FF4, 0x5747E915, 0xB669E371][i])  # *_pan (unsupported)
	# programmable SE channel
	s[0x8424CF12] = _play_ch                 # sound_ch
	s[0xDFCF9F75] = func(a: Array) -> Dictionary: _stop("se:%d" % _ai(a[0])); return MajiroVm.vint(0)  # sound_ch_stop
	s[0xF9D7B692] = func(a: Array) -> Dictionary: var rec := _ch("se:%d" % _ai(a[0]), "se"); rec["vol"] = clampi(_ai(a[1]), 0, 255) if a.size() >= 2 else 255; _apply_vol("se:%d" % _ai(a[0])); return MajiroVm.vint(0)  # sound_ch_vol
	s[0x2B10081B] = func(a: Array) -> Dictionary: var rec := _ch("se:%d" % _ai(a[0]), "se"); return MajiroVm.vint(1 if (rec["node"] as AudioStreamPlayer).playing else 0)  # sound_ch_stat
	s[0x0BEF00DB] = func(a: Array) -> Dictionary: return _suspend_until_silent("se:%d" % _ai(a[0]))  # sound_ch_wait
	s[0x9CABFDF3] = func(a: Array) -> Dictionary: _fade("se:%d" % _ai(a[0]), _ai(a[1]) if a.size() >= 2 else 255, _ai(a[2]) if a.size() >= 3 else 0, false); return MajiroVm.vint(0)  # sound_ch_fade
	s[0x7B657BAB] = func(a: Array) -> Dictionary: _fade("se:%d" % _ai(a[0]), 0, _ai(a[1]) if a.size() >= 2 else 0, true); return MajiroVm.vint(0)  # sound_ch_fadeout
	s[0xB2F1993B] = func(a: Array) -> Dictionary: var rec := _ch("se:%d" % _ai(a[0]), "se"); return MajiroVm.vstr(rec["name"])  # sound_ch_get_fn$
	s[0xA65B03AE] = _record(0xA65B03AE)      # sound_ch_pan
	# voice + voice_ch
	s[0x32D0236C] = func(a: Array) -> Dictionary:
		if not a.is_empty():
			_play("voice:0", _ab(a[0]), _ai(a[1]) != 0 if a.size() >= 2 else false)
		return MajiroVm.vint(0)  # voice
	s[0x8E8167F2] = func(a: Array) -> Dictionary:
		if a.size() >= 2:
			_play("voice:%d" % _ai(a[0]), _ab(a[1]), _ai(a[2]) != 0 if a.size() >= 3 else false)
		return MajiroVm.vint(0)  # voice_ch
	s[0x05D6ED69] = func(_a: Array) -> Dictionary: _stop("voice:0"); return MajiroVm.vint(0)  # voice_stop
	s[0x5A981E41] = func(a: Array) -> Dictionary: _stop("voice:%d" % _ai(a[0])); return MajiroVm.vint(0)  # voice_ch_stop
	s[0x801D7AF9] = func(a: Array) -> Dictionary: var rec := _ch("voice:0", "voice"); rec["vol"] = clampi(_ai(a[0]), 0, 255) if not a.is_empty() else 255; _apply_vol("voice:0"); return MajiroVm.vint(0)  # voice_vol
	s[0xCB665AC0] = func(a: Array) -> Dictionary: var rec := _ch("voice:%d" % _ai(a[0]), "voice"); rec["vol"] = clampi(_ai(a[1]), 0, 255) if a.size() >= 2 else 255; _apply_vol("voice:%d" % _ai(a[0])); return MajiroVm.vint(0)  # voice_ch_vol
	s[0xF1097A07] = func(_a: Array) -> Dictionary: var rec := _ch("voice:0", "voice"); return MajiroVm.vint(1 if (rec["node"] as AudioStreamPlayer).playing else 0)  # voice_stat
	s[0xAE47892F] = func(a: Array) -> Dictionary: var rec := _ch("voice:%d" % _ai(a[0]), "voice"); return MajiroVm.vint(1 if (rec["node"] as AudioStreamPlayer).playing else 0)  # voice_ch_stat
	s[0xD1F672C7] = func(_a: Array) -> Dictionary: return _suspend_until_silent("voice:0")  # voice_wait
	s[0x8EB881EF] = func(a: Array) -> Dictionary: return _suspend_until_silent("voice:%d" % _ai(a[0]))  # voice_ch_wait
	s[0x46B28FEF] = func(a: Array) -> Dictionary: _fade("voice:0", _ai(a[0]) if not a.is_empty() else 255, _ai(a[1]) if a.size() >= 2 else 0, false); return MajiroVm.vint(0)  # voice_fade
	s[0x19FC7CC7] = func(a: Array) -> Dictionary: _fade("voice:%d" % _ai(a[0]), _ai(a[1]) if a.size() >= 2 else 255, _ai(a[2]) if a.size() >= 3 else 0, false); return MajiroVm.vint(0)  # voice_ch_fade
	s[0x173B92D1] = func(a: Array) -> Dictionary: _fade("voice:0", 0, _ai(a[0]) if not a.is_empty() else 0, true); return MajiroVm.vint(0)  # voice_fadeout
	s[0x8F905B3F] = func(a: Array) -> Dictionary: _fade("voice:%d" % _ai(a[0]), 0, _ai(a[1]) if a.size() >= 2 else 0, true); return MajiroVm.vint(0)  # voice_ch_fadeout
	s[0xDEAF7041] = func(_a: Array) -> Dictionary: var rec := _ch("voice:0", "voice"); return MajiroVm.vstr(rec["name"])  # voice_get_fn$
	s[0x4604B9AF] = func(a: Array) -> Dictionary: var rec := _ch("voice:%d" % _ai(a[0]), "voice"); return MajiroVm.vstr(rec["name"])  # voice_ch_get_fn$
	for h in [0xDF91CFC5, 0x94EAEFFC, 0xBFA74901, 0x90D5298A, 0xB3FFDFFA, 0x15D07DF8, 0x649CFC79]:
		s[h] = _record(h)  # voice pan/raw/setup/text_setup/musicdown/is_exist
	# music (BGM) + stack
	s[0x4980F82C] = _sc_music                # music
	s[0xA589DBD1] = _sc_music_push           # music_push
	s[0xF86FC950] = _sc_music_pop            # music_pop
	s[0xABB7FCFB] = _sc_music                # music_replace
	s[0x0C070535] = func(_a: Array) -> Dictionary: _stop("music"); return MajiroVm.vint(0)  # music_stop
	s[0xE7B90DF5] = func(a: Array) -> Dictionary: var rec := _ch("music", "music"); rec["vol"] = clampi(_ai(a[0]), 0, 255) if not a.is_empty() else 255; _apply_vol("music"); return MajiroVm.vint(0)  # music_vol
	s[0x4F6367B3] = func(a: Array) -> Dictionary: _fade("music", _ai(a[0]) if not a.is_empty() else 255, _ai(a[1]) if a.size() >= 2 else 0, false); return MajiroVm.vint(0)  # music_fade
	s[0x15EEDEAA] = func(a: Array) -> Dictionary: _fade("music", 0, _ai(a[0]) if not a.is_empty() else 0, true); return MajiroVm.vint(0)  # music_fadeout
	s[0x379FDB39] = func(a: Array) -> Dictionary: _fade("music", 0, _ai(a[0]) if not a.is_empty() else 0, true); return _suspend_until_silent("music")  # music_fadeout_wait
	s[0xD8279A9B] = func(_a: Array) -> Dictionary: return _suspend_until_silent("music")  # music_wait
	s[0xF8D8925B] = func(_a: Array) -> Dictionary: var rec := _ch("music", "music"); return MajiroVm.vint(1 if (rec["node"] as AudioStreamPlayer).playing else 0)  # music_stat
	s[0x91CEACF2] = func(_a: Array) -> Dictionary: _music_stack.clear(); return MajiroVm.vint(0)  # music_stat_reset
	s[0x2626FE02] = func(_a: Array) -> Dictionary: var rec := _ch("music", "music"); (rec["node"] as AudioStreamPlayer).stream_paused = true; return MajiroVm.vint(0)  # music_pause
	s[0xD011FF32] = func(_a: Array) -> Dictionary: var rec := _ch("music", "music"); (rec["node"] as AudioStreamPlayer).stream_paused = false; return MajiroVm.vint(0)  # music_resume
	# family volume setters (config)
	s[0x072E738C] = func(a: Array) -> Dictionary: family_vol["se"] = clampi(_ai(a[0]), 0, 255) if not a.is_empty() else 255; _refresh_family("se"); return MajiroVm.vint(0)  # set_soundvolume
	s[0x0C7A0E97] = func(a: Array) -> Dictionary: family_vol["music"] = clampi(_ai(a[0]), 0, 255) if not a.is_empty() else 255; _refresh_family("music"); return MajiroVm.vint(0)  # set_musicvolume
	s[0x6EAEC2A0] = func(a: Array) -> Dictionary: family_vol["voice"] = clampi(_ai(a[0]), 0, 255) if not a.is_empty() else 255; _refresh_family("voice"); return MajiroVm.vint(0)  # set_voicevolume
	# remaining sound-domain syscalls stay recording stubs
	for h in [0x45AD5F4D, 0x978047DB, 0xE3605CFA, 0x80F94706]:
		s[h] = _record(h)


func _refresh_family(family: String) -> void:
	for key in _players:
		if _family_of(key) == family:
			_apply_vol(key)


func _sc_music(a: Array) -> Dictionary:
	if not a.is_empty():
		_play("music", _ab(a[0]), _ai(a[1]) != 0 if a.size() >= 2 else true)
	return MajiroVm.vint(0)


func _sc_music_push(a: Array) -> Dictionary:
	var rec := _ch("music", "music")
	_music_stack.append({"name": rec["name"], "loop": bool(rec["loop"]),
			"pos": (rec["node"] as AudioStreamPlayer).get_playback_position(),
			"playing": (rec["node"] as AudioStreamPlayer).playing})
	if not a.is_empty():
		_play("music", _ab(a[0]), _ai(a[1]) != 0 if a.size() >= 2 else true)
	return MajiroVm.vint(0)


func _sc_music_pop(_a: Array) -> Dictionary:
	if _music_stack.is_empty():
		_stop("music")
		return MajiroVm.vint(0)
	var top: Dictionary = _music_stack.pop_back()
	_stop("music")
	if not (top["name"] as PackedByteArray).is_empty() and bool(top["playing"]):
		_play("music", top["name"], bool(top["loop"]))
		var rec := _ch("music", "music")
		(rec["node"] as AudioStreamPlayer).seek(float(top["pos"]))
	return MajiroVm.vint(0)
