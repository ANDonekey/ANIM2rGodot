class_name AudioDirector
extends Node
## BGM (.eog = 8-byte CRM header + Ogg Vorbis), dialogue voice and
## background voice (op 0x88). Streams are materialized into
## user://audio_cache/ once, because AudioStreamOggVorbis streams from
## files, not memory buffers.

var pkg: GamePackage
var current_bgm := -1
var _voice_bus := -1
# Web mode: resources are fetched before they can play; a request
# token per channel drops fetches that a newer call superseded.
var _bgm_req := 0
var _voice_req := 0
var _bgv_req := 0

@onready var _bgm: AudioStreamPlayer = $BGM
@onready var _voice: AudioStreamPlayer = $Voice
@onready var _bgv: AudioStreamPlayer = $BGV


func setup(p_pkg: GamePackage) -> void:
	pkg = p_pkg
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
	_bgv.bus = "Voice"


## Current voice loudness 0..1 (0 when silent); drives E-mote lip sync.
func voice_level() -> float:
	if _voice_bus < 0 or not any_voice_playing():
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
	var token := _bgm_req
	if pkg.is_web() and pkg.bgm_bytes(track).is_empty():
		await pkg.ensure_bgm(track)
		if token != _bgm_req:
			return
	var bytes := pkg.bgm_bytes(track)
	if bytes.is_empty():
		return
	_bgm.stream = _stream(bytes, "bgm_%02d" % track, true)
	_bgm.play()
	current_bgm = track


func stop_bgm() -> void:
	_bgm_req += 1
	_bgm.stop()
	current_bgm = -1


func fade_bgm(_ms: int) -> void:
	stop_bgm()


func play_voice(voice_name: String) -> void:
	_voice_req += 1
	var token := _voice_req
	if pkg.is_web() and pkg.voice_bytes(voice_name).is_empty():
		await pkg.ensure_voice(voice_name)
		if token != _voice_req:
			return
	var bytes := pkg.voice_bytes(voice_name)
	if bytes.is_empty():
		return
	_voice.stream = _stream(bytes, "v_" + voice_name, false)
	_voice.play()


func stop_voice() -> void:
	_voice_req += 1
	_voice.stop()


func play_bgv(voice_name: String) -> void:
	_bgv_req += 1
	var token := _bgv_req
	if pkg.is_web() and pkg.voice_bytes(voice_name).is_empty():
		await pkg.ensure_voice(voice_name)
		if token != _bgv_req:
			return
	var bytes := pkg.voice_bytes(voice_name)
	if bytes.is_empty():
		return
	_bgv.stream = _stream(bytes, "v_" + voice_name, false)
	_bgv.play()


func stop_bgv() -> void:
	_bgv_req += 1
	_bgv.stop()


func any_voice_playing() -> bool:
	return _voice.playing or _bgv.playing
