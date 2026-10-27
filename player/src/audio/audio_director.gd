class_name AudioDirector
extends Node
## BGM (.eog = 8-byte CRM header + Ogg Vorbis), dialogue voice and
## background voice (op 0x88). Streams are materialized into
## user://audio_cache/ once, because AudioStreamOggVorbis streams from
## files, not memory buffers.

var pkg: GamePackage
var current_bgm := -1

@onready var _bgm: AudioStreamPlayer = $BGM
@onready var _voice: AudioStreamPlayer = $Voice
@onready var _bgv: AudioStreamPlayer = $BGV


func setup(p_pkg: GamePackage) -> void:
	pkg = p_pkg
	DirAccess.make_dir_recursive_absolute("user://audio_cache")


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
	var bytes := pkg.bgm_bytes(track)
	if bytes.is_empty():
		return
	_bgm.stream = _stream(bytes, "bgm_%02d" % track, true)
	_bgm.play()
	current_bgm = track


func stop_bgm() -> void:
	_bgm.stop()
	current_bgm = -1


func fade_bgm(_ms: int) -> void:
	stop_bgm()


func play_voice(voice_name: String) -> void:
	var bytes := pkg.voice_bytes(voice_name)
	if bytes.is_empty():
		return
	_voice.stream = _stream(bytes, "v_" + voice_name, false)
	_voice.play()


func stop_voice() -> void:
	_voice.stop()


func play_bgv(voice_name: String) -> void:
	var bytes := pkg.voice_bytes(voice_name)
	if bytes.is_empty():
		return
	_bgv.stream = _stream(bytes, "v_" + voice_name, false)
	_bgv.play()


func stop_bgv() -> void:
	_bgv.stop()


func any_voice_playing() -> bool:
	return _voice.playing or _bgv.playing
