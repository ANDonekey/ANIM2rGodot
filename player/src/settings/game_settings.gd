class_name GameSettings
extends RefCounted
## Persistent CONFIG / VOLUME settings, mirroring the original
## engine's two settings screens. Defaults are the factory values
## measured on a fresh original install (toggle states from the
## CONFIG screenshot, slider knob positions measured pixel-wise:
## opacity 50 / text speed 85 / auto speed 0; volumes 100/80/80/
## 70/70/70/70; character volumes ~85).

const PATH := "user://settings.json"

var config: Dictionary
var volume: Dictionary
var chars: Dictionary


static func defaults_config() -> Dictionary:
	return {
		"screen_mode": 0,  # 0 window / 1 fullscreen
		"screen_effect": 0,  # 0 on / 1 off
		"skip_unread": 1,  # 0 skip / 1 don't
		"skip_after_choice": 1,
		"h_anime": 0,
		"pubic": 0,  # 0 show / 1 hide
		"voice_cut": 1,
		"backlog_style": 0,  # 0 full screen / 1 on window
		"confirm_dialog": 0,  # 0 show / 1 hide
		"voice_bar": 0,
		"auto_bar": 0,
		"font": 0,
		"window_opacity": 50,  # message window transparency %
		"text_speed": 85,
		"auto_speed": 0,
	}


static func defaults_volume() -> Dictionary:
	return {
		"master": 100, "bgm": 80, "se": 80, "bgv": 70,
		"bgv_duck": 70, "env": 70, "env_h": 70,
		"play_master": true, "play_bgm": true, "play_se": true,
		"play_bgv": true, "play_bgv_duck": true, "play_env": true,
		"play_env_h": true,
	}


static func defaults_chars() -> Dictionary:
	return {
		"chinatsu": {"volume": 85, "play": true},
		"fumiko": {"volume": 85, "play": true},
	}


func _init() -> void:
	config = defaults_config()
	volume = defaults_volume()
	chars = defaults_chars()
	load_settings()


func load_settings() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if not (data is Dictionary):
		return
	_merge(config, data.get("config", {}))
	_merge(volume, data.get("volume", {}))
	var saved_chars: Dictionary = data.get("chars", {})
	for key in chars.keys():
		if saved_chars.has(key):
			_merge(chars[key], saved_chars[key])


func _merge(dst: Dictionary, src: Dictionary) -> void:
	for key in src.keys():
		if dst.has(key):
			dst[key] = src[key]


func save_settings() -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"config": config, "volume": volume, "chars": chars}))
	f.close()


func reset_config() -> void:
	config = defaults_config()
	save_settings()


func reset_volume() -> void:
	volume = defaults_volume()
	chars = defaults_chars()
	save_settings()
