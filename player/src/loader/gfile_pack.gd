class_name GFilePack
extends RefCounted
## GFilePack reader (voice .pck and cg/psbpack.dat share the format):
##   [u32 count][count x (u32 zero, u32 offset, u32 size)]
##   [NUL-terminated ASCII name table][blobs at absolute offsets]
##
## Only the header (index + names) is read at open; entries are fetched
## on demand with seek+read, so 1 GB packs cost a few hundred KB of RAM.

var _f: FileAccess
var names: Array[String] = []
var _index: Dictionary = {}  # lowercase name -> [offset, size]

# Web mode: the pack lives behind an HTTP URL; the header is fetched
# with Range reads at open and entries are fetched on demand into
# _entry_cache (sync get_entry then serves the cache only). In a v2
# bundled package the pack is a span inside a bundle file, so every
# read is shifted by _web_off.
var _web: WebSource
var _web_url: String = ""
var _web_off: int = 0
var _entry_cache: Dictionary = {}  # lowercase name -> PackedByteArray
var _inflight: Dictionary = {}  # lowercase name -> true while fetching


static func open(path: String) -> GFilePack:
	var p := GFilePack.new()
	p._f = FileAccess.open(path, FileAccess.READ)
	if p._f == null:
		push_error("GFilePack: cannot open " + path)
		return null
	var count := int(p._f.get_32())
	var entries: Array = []
	entries.resize(count)
	for i in count:
		p._f.get_32()  # zero field
		var off := int(p._f.get_32())
		var size := int(p._f.get_32())
		entries[i] = [off, size]
	for i in count:
		var buf := PackedByteArray()
		while true:
			var ch := p._f.get_8()
			if ch == 0 or p._f.eof_reached():
				break
			buf.append(ch)
		var nm := buf.get_string_from_ascii()
		p.names.append(nm)
		p._index[nm.to_lower()] = entries[i]
	return p


## Web-mode open: two Range reads (entry table, then the full header
## up to the first blob) reproduce the desktop header parse exactly.
static func open_web(source: WebSource, url: String) -> GFilePack:
	return await open_web_span(source, url, 0)


## Like open_web, but the pack starts at base_off inside the URL's
## resource (anim-webpkg/2 bundles).
static func open_web_span(source: WebSource, url: String, base_off: int) -> GFilePack:
	var p := GFilePack.new()
	p._web = source
	p._web_url = url
	p._web_off = base_off
	var head: PackedByteArray = await source.fetch_range(url, base_off, 4)
	if head.size() < 4:
		push_error("GFilePack(web): cannot read count: " + url)
		return null
	var count := int(head.decode_u32(0))
	var idx_size := 4 + 12 * count
	var idx: PackedByteArray = await source.fetch_range(url, base_off, idx_size)
	if idx.size() < idx_size:
		push_error("GFilePack(web): short entry table: " + url)
		return null
	var entries: Array = []
	entries.resize(count)
	var data_start := 0x7fffffff
	for i in count:
		var off := int(idx.decode_u32(4 + 12 * i + 4))
		var size := int(idx.decode_u32(4 + 12 * i + 8))
		entries[i] = [off, size]
		data_start = mini(data_start, off)
	var hdr: PackedByteArray = await source.fetch_range(url, base_off, data_start)
	if hdr.size() < data_start:
		push_error("GFilePack(web): short header: " + url)
		return null
	var pos := idx_size
	for i in count:
		var buf := PackedByteArray()
		while pos < hdr.size() and hdr[pos] != 0:
			buf.append(hdr[pos])
			pos += 1
		pos += 1  # NUL
		var nm := buf.get_string_from_ascii()
		p.names.append(nm)
		p._index[nm.to_lower()] = entries[i]
	return p


## Build a web pack from an index embedded in the package manifest
## (anim-webpkg/2 "packs"): no header round trips at open. Entries
## are still fetched lazily by Range, exactly like open_web_span.
static func from_index(source: WebSource, url: String, base_off: int,
		names_arr: Array, entries_arr: Array) -> GFilePack:
	var p := GFilePack.new()
	p._web = source
	p._web_url = url
	p._web_off = base_off
	for i in names_arr.size():
		var nm: String = str(names_arr[i])
		var e: Array = entries_arr[i]
		p.names.append(nm)
		p._index[nm.to_lower()] = [int(e[0]), int(e[1])]
	return p


## Fetch one entry over HTTP into the cache (web mode); returns the
## bytes. Native mode just defers to get_entry.
func get_entry_async(entry_name: String) -> PackedByteArray:
	var key := entry_name.to_lower()
	if _entry_cache.has(key):
		return _entry_cache[key]
	if _web == null:
		return get_entry(entry_name)
	var e: Variant = _index.get(key)
	if e == null:
		return PackedByteArray()
	# Dedupe concurrent fetches of the same entry.
	while _inflight.has(key):
		await _web.get_tree().process_frame
		if _entry_cache.has(key):
			return _entry_cache[key]
	_inflight[key] = true
	var bytes: PackedByteArray = await _web.fetch_range(_web_url, _web_off + int(e[0]), int(e[1]))
	_inflight.erase(key)
	# Failed fetches are NOT cached (see GamePackage._fetch_file):
	# an empty result here used to silence the entry for the whole
	# session after one transient HTTP error.
	if not bytes.is_empty():
		_entry_cache[key] = bytes
	return bytes


func entry_count() -> int:
	return names.size()


func has(name: String) -> bool:
	return _index.has(name.to_lower())


func get_entry(name: String) -> PackedByteArray:
	var key := name.to_lower()
	if _entry_cache.has(key):
		return _entry_cache[key]
	if _f == null:
		return PackedByteArray()  # web mode, not fetched yet
	var e: Variant = _index.get(key)
	if e == null:
		return PackedByteArray()
	_f.seek(e[0])
	return _f.get_buffer(e[1])
