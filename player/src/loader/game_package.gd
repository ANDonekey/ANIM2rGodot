class_name GamePackage
extends RefCounted
## Opens an original ANIM game data directory and serves its resources
## on demand (nothing is pre-decoded wholesale; sce/define are small and
## cached after first decrypt, packs are indexed by header only).
##
## Layout (sample-verified): root holds *_sce.dat / *_define.dat /
## *_save.dat; subdirs cg/ (*.gax + psbpack.dat), voice/ (*.pck),
## bgm/ (*.eog), movie/ (*.mpg).

var root: String = ""
var sce_name: String = ""
var define_name: String = ""

var _cg: Dictionary = {}  # lowercase basename w/o ext -> full path (.gax)
var _movies: Dictionary = {}  # lowercase name -> full path
var _bgm: Dictionary = {}  # track number -> full path
var _psb_pack: GFilePack
var _voice_pack: GFilePack
var _sce_cache: PackedByteArray
var _define_cache: PackedByteArray


static func _list_dir(path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(path)
	if d == null:
		return out
	d.list_dir_begin()
	var nm := d.get_next()
	while nm != "":
		out.append(nm)
		nm = d.get_next()
	d.list_dir_end()
	return out


func open(dir: String) -> bool:
	root = dir
	for nm in _list_dir(dir):
		var low := nm.to_lower()
		if low.ends_with("_sce.dat"):
			sce_name = nm
		elif low.ends_with("_define.dat"):
			define_name = nm
	if sce_name == "":
		push_error("GamePackage: no *_sce.dat in " + dir)
		return false
	for nm in _list_dir(dir.path_join("cg")):
		if nm.to_lower().ends_with(".gax"):
			_cg[nm.get_basename().to_lower()] = dir.path_join("cg").path_join(nm)
		elif nm.to_lower() == "psbpack.dat":
			_psb_pack = GFilePack.open(dir.path_join("cg").path_join(nm))
	for nm in _list_dir(dir.path_join("voice")):
		if nm.to_lower().ends_with(".pck"):
			_voice_pack = GFilePack.open(dir.path_join("voice").path_join(nm))
	for nm in _list_dir(dir.path_join("bgm")):
		if nm.to_lower().ends_with(".eog"):
			_bgm[int(nm.get_basename())] = dir.path_join("bgm").path_join(nm)
	for nm in _list_dir(dir.path_join("movie")):
		_movies[nm.to_lower()] = dir.path_join("movie").path_join(nm)
	return true


func cg_count() -> int:
	return _cg.size()


func psb_count() -> int:
	return _psb_pack.entry_count() if _psb_pack else 0


func voice_count() -> int:
	return _voice_pack.entry_count() if _voice_pack else 0


func bgm_count() -> int:
	return _bgm.size()


func movie_count() -> int:
	return _movies.size()


func _decrypted(path: String) -> PackedByteArray:
	var raw := FileAccess.get_file_as_bytes(path)
	if raw.is_empty():
		return raw
	if GSecret.is_gsecret(raw):
		return GSecret.decrypt(raw)
	# "Fake header + plaintext" variant (patched localizations):
	# same 20-byte header size, body already plaintext.
	return raw.slice(20)


func sce_bytes() -> PackedByteArray:
	if _sce_cache.is_empty():
		_sce_cache = _decrypted(root.path_join(sce_name))
	return _sce_cache


func define_bytes() -> PackedByteArray:
	if _define_cache.is_empty():
		_define_cache = _decrypted(root.path_join(define_name))
	return _define_cache


## Decrypted PNG bytes for a cg image name from the script pool
## (names appear as e.g. "BG110" / "bg110" / "AN001a_s").
func image_bytes(image_name: String) -> PackedByteArray:
	var p: Variant = _cg.get(image_name.get_basename().to_lower())
	if p == null:
		return PackedByteArray()
	return _decrypted(p)


## Raw PSB bytes for a model name from the script pool ("Mchina110" or
## "Mchina110.psb"), out of cg/psbpack.dat.
func psb_bytes(model_name: String) -> PackedByteArray:
	if _psb_pack == null:
		return PackedByteArray()
	var nm := model_name.get_file()
	if _psb_pack.has(nm):
		return _psb_pack.get_entry(nm)
	return _psb_pack.get_entry(nm + ".psb")


## Raw (still CRM-wrapped) voice entry bytes; the audio layer peels the
## 8-byte CRM header. Names in the script have no extension.
func voice_bytes(voice_name: String) -> PackedByteArray:
	if _voice_pack == null:
		return PackedByteArray()
	var nm := voice_name.get_file()
	if _voice_pack.has(nm):
		return _voice_pack.get_entry(nm)
	return _voice_pack.get_entry(nm + ".eog")


## Raw .eog bytes for a BGM track number (bgm/NN.eog).
func bgm_bytes(track: int) -> PackedByteArray:
	var p: Variant = _bgm.get(track)
	if p == null:
		return PackedByteArray()
	return FileAccess.get_file_as_bytes(p)


func movie_path(movie_name: String) -> String:
	var p: Variant = _movies.get(movie_name.get_file().to_lower())
	return p if p != null else ""
