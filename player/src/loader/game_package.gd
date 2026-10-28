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

# Web mode (online package): indexes hold package-relative paths and
# every resource is fetched over HTTP into _file_cache on first use
# (the ensure_* functions) or at open (sce/define). Sync getters then
# read the caches, so callers above this layer do not change.
var _web: WebSource
var _base: String = ""
var _file_cache: Dictionary = {}  # relpath -> raw bytes
var _inflight: Dictionary = {}  # relpath -> true while a fetch runs
# anim-webpkg/2 (bundled): every file is a span inside a bundle file.
var _bundles: Array = []  # bundle relpaths, index = bundle id
var _spans: Dictionary = {}  # relpath -> [bundle id, offset, size]
# Preprocessing flags from the manifest ("pre"): the builder already
# decrypted sce/define/cg and/or channel-swapped the PSB textures, so
# the per-byte / per-pixel main-thread work is skipped at runtime.
var _pre_decrypted := false
var _pre_swapped := false


func pre_swapped() -> bool:
	return _pre_swapped


func is_web() -> bool:
	return _web != null


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
	return _decrypt_bytes(FileAccess.get_file_as_bytes(path))


static func _decrypt_bytes(raw: PackedByteArray) -> PackedByteArray:
	if raw.is_empty():
		return raw
	if GSecret.is_gsecret(raw):
		return GSecret.decrypt(raw)
	# "Fake header + plaintext" variant (patched localizations):
	# same 20-byte header size, body already plaintext.
	return raw.slice(20)


## Open an online (preprocessed) package: base_url points at the
## package root that serves manifest.json (see web_package_build.py).
func open_web(source: WebSource, base_url: String) -> bool:
	_web = source
	_base = base_url
	if not _base.ends_with("/"):
		_base += "/"
	root = _base
	var mbytes: PackedByteArray = await source.fetch(_base + "manifest.json")
	var parsed: Variant = JSON.parse_string(mbytes.get_string_from_utf8())
	if not (parsed is Dictionary) or parsed.get("format", "") not in ["anim-webpkg/1", "anim-webpkg/2"]:
		push_error("GamePackage(web): bad manifest at " + _base)
		return false
	var pre: Dictionary = parsed.get("pre", {})
	_pre_decrypted = bool(pre.get("decrypted", false))
	_pre_swapped = bool(pre.get("swapped", false))
	var files: Dictionary = parsed["files"]
	if parsed["format"] == "anim-webpkg/2":
		_bundles = parsed["bundles"]
		for rel_v in files:
			_spans[rel_v] = files[rel_v]
	sce_name = parsed.get("sce", "")
	define_name = parsed.get("define", "")
	if sce_name == "":
		push_error("GamePackage(web): manifest has no sce")
		return false
	var psb_rel := ""
	var voice_rel := ""
	for rel_v in files:
		var rel: String = rel_v
		var low: String = rel.to_lower()
		if low.begins_with("cg/") and low.ends_with(".gax"):
			_cg[rel.get_file().get_basename().to_lower()] = rel
		elif low == "cg/psbpack.dat":
			psb_rel = rel
		elif low.begins_with("voice/") and low.ends_with(".pck"):
			voice_rel = rel
		elif low.begins_with("bgm/") and low.ends_with(".eog"):
			_bgm[int(rel.get_file().get_basename())] = rel
	var movies: Dictionary = parsed.get("movies", {})
	for orig in movies:
		_movies[orig.to_lower()] = movies[orig]
	if psb_rel != "":
		_psb_pack = await _open_pack_web(psb_rel)
	if voice_rel != "":
		_voice_pack = await _open_pack_web(voice_rel)
	var sce_raw: PackedByteArray = await _fetch_file(sce_name)
	_sce_cache = sce_raw if _pre_decrypted else _decrypt_bytes(sce_raw)
	if define_name != "":
		var def_raw: PackedByteArray = await _fetch_file(define_name)
		_define_cache = def_raw if _pre_decrypted else _decrypt_bytes(def_raw)
	return not _sce_cache.is_empty()


## Open a GFilePack that lives in the web package: as a loose file
## (v1) or as a span inside a bundle (v2).
func _open_pack_web(rel: String) -> GFilePack:
	if _spans.has(rel):
		var s: Array = _spans[rel]
		return await GFilePack.open_web_span(
				_web, _base + _bundles[int(s[0])], int(s[1]))
	return await GFilePack.open_web(_web, _base + rel)


func _fetch_file(rel: String) -> PackedByteArray:
	if _file_cache.has(rel):
		return _file_cache[rel]
	# Dedupe concurrent fetches of the same file: without this,
	# a repeated request (e.g. BGM re-asserted by the script)
	# restarted the whole download and starved the first one.
	while _inflight.has(rel):
		await _web.get_tree().process_frame
		if _file_cache.has(rel):
			return _file_cache[rel]
	_inflight[rel] = true
	var bytes: PackedByteArray
	if _spans.has(rel):
		var s: Array = _spans[rel]
		var url: String = _base + str(_bundles[int(s[0])])
		var size := int(s[2])
		if size > 8 * 1024 * 1024:
			# Large files (BGM tracks run to 30 MB) go in
			# parallel 4 MiB chunks: a transient failure costs
			# one chunk, not the whole track; no single
			# request can time out; and parallel chunks keep
			# a high-latency link busy.
			var chunk_n := 4 * 1024 * 1024
			var total := (size + chunk_n - 1) / chunk_n
			var parts: Array = []
			parts.resize(total)
			var done := [0]
			for i in total:
				var n := mini(chunk_n, size - i * chunk_n)
				_fetch_part(url, int(s[1]) + i * chunk_n, n,
						parts, i, done)
			while int(done[0]) < total:
				await _web.get_tree().process_frame
			var ok := true
			for p in parts:
				if p == null or (p as PackedByteArray).size() == 0:
					ok = false
					break
			if ok:
				bytes = PackedByteArray()
				for p in parts:
					bytes.append_array(p)
			else:
				bytes = PackedByteArray()
		else:
			bytes = await _web.fetch_range(url, int(s[1]), size)
	else:
		bytes = await _web.fetch(_base + rel)
	_inflight.erase(rel)
	# Failed fetches are NOT cached: caching an empty result used
	# to poison the file for the rest of the session.
	if not bytes.is_empty():
		_file_cache[rel] = bytes
	return bytes


func _cached_file(rel: String) -> PackedByteArray:
	return _file_cache.get(rel, PackedByteArray())


## Prefetch one cg image so image_bytes() can serve it synchronously.
func ensure_image(image_name: String) -> void:
	if not is_web():
		return
	var rel: Variant = _cg.get(image_name.get_basename().to_lower())
	if rel != null:
		await _fetch_file(rel)


func ensure_bgm(track: int) -> void:
	if not is_web():
		return
	var rel: Variant = _bgm.get(track)
	if rel != null:
		await _fetch_file(rel)


## One chunk of a parallel large-file fetch (see _fetch_file).
func _fetch_part(url: String, start: int, n: int, parts: Array,
		idx: int, done: Array) -> void:
	var chunk: PackedByteArray = await _web.fetch_range(url, start, n)
	parts[idx] = chunk if chunk.size() == n else PackedByteArray()
	done[0] = int(done[0]) + 1


func _pack_entry_name(pack: GFilePack, entry_name: String, ext: String) -> String:
	var nm := entry_name.get_file()
	if pack.has(nm):
		return nm
	return nm + ext


func ensure_psb(model_name: String) -> void:
	if not is_web() or _psb_pack == null:
		return
	await _psb_pack.get_entry_async(_pack_entry_name(_psb_pack, model_name, ".psb"))


func ensure_voice(voice_name: String) -> void:
	if not is_web() or _voice_pack == null:
		return
	await _voice_pack.get_entry_async(_pack_entry_name(_voice_pack, voice_name, ".eog"))


## Transcoded (.ogv) path for a movie in web mode, "" when the package
## has no transcoded version of it.
func movie_ogv_rel(movie_name: String) -> String:
	var p: Variant = _movies.get(movie_name.get_file().to_lower())
	return p if p != null and is_web() else ""


## Download a transcoded movie into user:// and return its local path
## (VideoStreamTheora plays from files, not buffers). "" on failure.
func ensure_movie(movie_name: String) -> String:
	var rel := movie_ogv_rel(movie_name)
	if rel == "":
		return ""
	var dir := "user://movie_cache"
	DirAccess.make_dir_recursive_absolute(dir)
	var local := dir + "/" + rel.get_file()
	if FileAccess.file_exists(local):
		return local
	var bytes: PackedByteArray = await _fetch_file(rel)
	if bytes.is_empty():
		return ""
	var f := FileAccess.open(local, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	f.close()
	return local


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
	if is_web():
		return _cached_file(p) if _pre_decrypted \
				else _decrypt_bytes(_cached_file(p))
	return _decrypted(p)


## Raw PSB bytes for a model name from the script pool ("Mchina110" or
## "Mchina110.psb"), out of cg/psbpack.dat.
func psb_bytes(model_name: String) -> PackedByteArray:
	if _psb_pack == null:
		return PackedByteArray()
	return _psb_pack.get_entry(_pack_entry_name(_psb_pack, model_name, ".psb"))


## Raw (still CRM-wrapped) voice entry bytes; the audio layer peels the
## 8-byte CRM header. Names in the script have no extension.
func voice_bytes(voice_name: String) -> PackedByteArray:
	if _voice_pack == null:
		return PackedByteArray()
	return _voice_pack.get_entry(_pack_entry_name(_voice_pack, voice_name, ".eog"))


## Raw .eog bytes for a BGM track number (bgm/NN.eog).
func bgm_bytes(track: int) -> PackedByteArray:
	var p: Variant = _bgm.get(track)
	if p == null:
		return PackedByteArray()
	if is_web():
		return _cached_file(p)
	return FileAccess.get_file_as_bytes(p)


func movie_path(movie_name: String) -> String:
	var p: Variant = _movies.get(movie_name.get_file().to_lower())
	return p if p != null else ""
