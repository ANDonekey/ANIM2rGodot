class_name AudioDirector
extends Node
## BGM (.eog = 8-byte CRM header + Ogg Vorbis), dialogue voice,
## background voice (op 0x88, looping) and one-shot SE (op 0x8B).
## Streams are materialized into user://audio_cache/ once, because
## AudioStreamOggVorbis streams from files, not memory buffers.

var pkg: GamePackage
var current_bgm := -1
## Loop flag applied to BGM streams (the music room's repeat
## toggle; story BGM always loops).
var bgm_loop := true


func set_bgm_loop(on: bool) -> void:
	bgm_loop = on
	if _bgm.stream is AudioStreamOggVorbis:
		(_bgm.stream as AudioStreamOggVorbis).loop = on
var _voice_bus := -1
# Web mode: resources are fetched before they can play; a request
# token per channel drops fetches that a newer call superseded.
var _bgm_req := 0
var _bgm_want := -1  # track the script most recently asked for
var _voice_req := 0
var _se_pool: Array[AudioStreamPlayer] = []
var _se_rr := 0
var _se_gain := 0.8
## BGV (op 0x88) is a MULTI-CHANNEL looping ambience system: the
## original addresses channels 1/2 (environment beds, e.g. the fire
## crackle) and 6/9/10/11/12 (background-voice layers) independently,
## and op 0x89 stops one channel by number. The old single-player
## design made every new loop replace the previous one and gave 0x89
## nowhere to land, so a bed that the script had stopped kept looping
## for the rest of the session.
var _bgv: Dictionary = {}  # channel -> AudioStreamPlayer
var _bgv_req: Dictionary = {}  # channel -> supersede token
var _bgv_gain := 0.7

@onready var _bgm: AudioStreamPlayer = $BGM
@onready var _voice: AudioStreamPlayer = $Voice


func setup(p_pkg: GamePackage) -> void:
	pkg = p_pkg
	# Web exports default to Sample playback (since Godot 4.3),
	# whose WebAudio graph silently drops this game's audio on the
	# way to the destination (measured: buffer sources carry real
	# signal, destination receives exact zeros, on the public build;
	# a stock minimal project is unaffected). Stream playback routes
	# through the Godot mixer like desktop: buses, gains, peak
	# meters (lip sync) all behave identically.
	if OS.has_feature("web"):
		# playback_type: 0 Default, 1 Stream, 2 Sample (the enum
		# constants are not exposed to GDScript in 4.7).
		_bgm.playback_type = 1
		_voice.playback_type = 1
	DirAccess.make_dir_recursive_absolute("user://audio_cache")
	# Route voice to its own bus so the stage can read its peak level
	# for lip sync without the BGM polluting the measurement.
	_voice_bus = AudioServer.get_bus_index("Voice")
	if _voice_bus < 0:
		AudioServer.add_bus()
		_voice_bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_voice_bus, "Voice")
		AudioServer.set_bus_send(_voice_bus, "Master")
	_voice.bus = "Voice"
	# One-shot SE players (op 0x8B): a small pool, because the script
	# can fire two SE at the same beat (slots 1+2) and a shot must
	# never cut the BGV loop, the dialogue voice, or another shot.
	for i in 4:
		var p := AudioStreamPlayer.new()
		p.name = "SE%d" % i
		if OS.has_feature("web"):
			p.playback_type = 1
		p.volume_db = linear_to_db(maxf(_se_gain, 0.0001))
		add_child(p)
		_se_pool.append(p)


## Current voice loudness 0..1 (0 when silent); drives E-mote lip sync.
## Channel gains (0..1 linear) driven by the VOLUME settings.
func set_bgm_gain(f: float) -> void:
	_bgm.volume_db = linear_to_db(maxf(f, 0.0001))


func set_voice_gain(f: float) -> void:
	_voice.volume_db = linear_to_db(maxf(f, 0.0001))


func set_bgv_gain(f: float) -> void:
	_bgv_gain = f
	for ch in _bgv:
		(_bgv[ch] as AudioStreamPlayer).volume_db = linear_to_db(maxf(f, 0.0001))


func set_se_gain(f: float) -> void:
	_se_gain = f
	for p in _se_pool:
		p.volume_db = linear_to_db(maxf(f, 0.0001))


func voice_level() -> float:
	# Lip sync follows the dialogue voice only: BGV shares this bus
	# (ambience would otherwise drive the mouth on its own — the fire
	# loop kept talk active through the whole opening scene).
	if _voice_bus < 0 or not voice_playing():
		return 0.0
	var db := AudioServer.get_bus_peak_volume_left_db(_voice_bus, 0)
	if is_inf(db) or db < -45.0:
		return 0.0
	return clampf(db_to_linear(db) * 1.4, 0.0, 1.0)


static func _peel_eog(bytes: PackedByteArray) -> PackedByteArray:
	if bytes.size() > 12 and bytes[0] == 0x43 and bytes[1] == 0x52 \
			and bytes[2] == 0x4D and bytes[3] == 0:
		return bytes.slice(8)
	return bytes


func _stream(bytes: PackedByteArray, cache_key: String, loop: bool) -> AudioStreamOggVorbis:
	var path := "user://audio_cache/" + cache_key + ".ogg"
	if not FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(_peel_eog(bytes))
		f.close()
	var stream := AudioStreamOggVorbis.load_from_file(path)
	if stream:
		stream.loop = loop
	return stream


func play_bgm(track: int) -> void:
	if track == current_bgm and _bgm.playing:
		return
	_bgm_req += 1
	_bgm_want = track
	# Fire-and-forget: a BGM download can take a minute on a slow
	# link, and the result must still be played when it lands as
	# long as this track is what the script currently wants. The
	# old await-in-place design dropped every slow fetch whose
	# scene had already moved on, so BGM never started at all.
	_bgm_kick(track, _bgm_req)


func _bgm_kick(track: int, token: int) -> void:
	var bytes := pkg.bgm_bytes(track)
	if pkg.is_web() and bytes.is_empty():
		await pkg.ensure_bgm(track)
		bytes = pkg.bgm_bytes(track)
		if bytes.is_empty():
			await get_tree().create_timer(0.8).timeout
			await pkg.ensure_bgm(track)
			bytes = pkg.bgm_bytes(track)
	if bytes.is_empty():
		return
	if token != _bgm_req or _bgm_want != track:
		return  # superseded while downloading; bytes stay cached
	_bgm.stream = _stream(bytes, "bgm_%02d" % track, bgm_loop)
	_bgm.play()
	current_bgm = track


func stop_bgm() -> void:
	_bgm_req += 1
	_bgm_want = -1
	_bgm.stop()
	current_bgm = -1


func fade_bgm(_ms: int) -> void:
	stop_bgm()


func play_voice(voice_name: String) -> void:
	_voice_req += 1
	var token := _voice_req
	var bytes := pkg.voice_bytes(voice_name)
	if pkg.is_web() and bytes.is_empty():
		await pkg.ensure_voice(voice_name)
		if token != _voice_req:
			return
		bytes = pkg.voice_bytes(voice_name)
		if bytes.is_empty():
			# One late retry after a transient fetch failure:
			# the line must not stay muted for good.
			await get_tree().create_timer(0.8).timeout
			if token != _voice_req:
				return
			await pkg.ensure_voice(voice_name)
			if token != _voice_req:
				return
			bytes = pkg.voice_bytes(voice_name)
	if bytes.is_empty():
		return
	_voice.stream = _stream(bytes, "v_" + voice_name, false)
	_voice.play()


func stop_voice() -> void:
	_voice_req += 1
	_voice.stop()


## One BGV channel (op 0x88): looping ambience addressed by channel
## number. Channels are created on first use and live for the whole
## session (a scene may start and stop the same channel many times).
func _bgv_player(channel: int) -> AudioStreamPlayer:
	if _bgv.has(channel):
		return _bgv[channel]
	var p := AudioStreamPlayer.new()
	p.name = "BGV%d" % channel
	if OS.has_feature("web"):
		p.playback_type = 1
	p.bus = "Voice"
	p.volume_db = linear_to_db(maxf(_bgv_gain, 0.0001))
	add_child(p)
	_bgv[channel] = p
	_bgv_req[channel] = 0
	return p


func play_bgv(channel: int, voice_name: String) -> void:
	var p := _bgv_player(channel)
	_bgv_req[channel] = int(_bgv_req[channel]) + 1
	var token := int(_bgv_req[channel])
	var bytes := pkg.voice_bytes(voice_name)
	if pkg.is_web() and bytes.is_empty():
		await pkg.ensure_voice(voice_name)
		if token != int(_bgv_req[channel]):
			return
		bytes = pkg.voice_bytes(voice_name)
		if bytes.is_empty():
			await get_tree().create_timer(0.8).timeout
			if token != int(_bgv_req[channel]):
				return
			await pkg.ensure_voice(voice_name)
			if token != int(_bgv_req[channel]):
				return
			bytes = pkg.voice_bytes(voice_name)
	if bytes.is_empty():
		return
	# Ambience loops until the script stops it (fire crackle etc.);
	# a non-looping stream played the loop once and went silent.
	p.stream = _stream(bytes, "v_" + voice_name, true)
	p.play()


## op 0x89: stop one BGV channel. Channels that were never started are
## ignored (the script stops beds defensively on scene entry).
func stop_bgv(channel: int) -> void:
	if not _bgv.has(channel):
		return
	_bgv_req[channel] = int(_bgv_req[channel]) + 1
	(_bgv[channel] as AudioStreamPlayer).stop()


func stop_all_bgv() -> void:
	for ch in _bgv:
		_bgv_req[ch] = int(_bgv_req[ch]) + 1
		(_bgv[ch] as AudioStreamPlayer).stop()


## One-shot sound effects (op 0x8B): short wave-pack clips played
## once on the SE channel. Independent of voice and BGV: an SE
## trigger must not stop or replace either (the previous mapping
## of op 0x8B to "stop BGV" was a decode error — see script_vm).
func play_se(se_name: String) -> void:
	var bytes := pkg.voice_bytes(se_name)
	if pkg.is_web() and bytes.is_empty():
		await pkg.ensure_voice(se_name)
		bytes = pkg.voice_bytes(se_name)
		if bytes.is_empty():
			await get_tree().create_timer(0.8).timeout
			await pkg.ensure_voice(se_name)
			bytes = pkg.voice_bytes(se_name)
	if bytes.is_empty() or _se_pool.is_empty():
		return
	var p := _se_pool[_se_rr % _se_pool.size()]
	_se_rr += 1
	p.stream = _stream(bytes, "v_" + se_name, false)
	p.play()


func stop_se() -> void:
	for p in _se_pool:
		p.stop()


func any_voice_playing() -> bool:
	if _voice.playing:
		return true
	for ch in _bgv:
		if (_bgv[ch] as AudioStreamPlayer).playing:
			return true
	return false


## Diagnostic: BGV channels currently audible.
func bgv_channels_playing() -> Array:
	var out := []
	for ch in _bgv:
		if (_bgv[ch] as AudioStreamPlayer).playing:
			out.append(ch)
	out.sort()
	return out


## Line voice only (BGV ambience loops forever and must not block
## voice-wait logic).
func voice_playing() -> bool:
	return _voice.playing


## Diagnostic snapshot for the autoplay harness: is anything
## actually producing samples, and at what gain?
func debug_state() -> Dictionary:
	return {
		"bgm_playing": _bgm.playing,
		"bgm_has_stream": _bgm.stream != null,
		"bgm_pos": snappedf(_bgm.get_playback_position(), 0.1),
		"voice_playing": _voice.playing,
		"voice_has_stream": _voice.stream != null,
		"master_peak_db": maxf(
				AudioServer.get_bus_peak_volume_left_db(0, 0), -120.0),
		"voice_peak_db": maxf(
				AudioServer.get_bus_peak_volume_left_db(
						_voice_bus, 0), -120.0) if _voice_bus >= 0 else -120.0,
		"master_vol_db": snappedf(AudioServer.get_bus_volume_db(0), 0.1),
		"bgm_vol_db": snappedf(_bgm.volume_db, 0.1),
		"bgv_channels": bgv_channels_playing(),
		"mix_rate": AudioServer.get_mix_rate(),
	}


