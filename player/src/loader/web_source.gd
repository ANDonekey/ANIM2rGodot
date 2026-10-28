class_name WebSource
extends Node
## HTTP fetch helper for online packages: whole-file fetches and
## HTTP Range reads, both awaitable. Pure HTTPRequest, so it works on
## every platform (on web it maps to fetch/XHR); the desktop build can
## therefore exercise the whole online data path against a local
## server, which is how this layer is regression-tested.
##
## All package URLs are expected to be same-origin (or CORS-enabled):
## Range reads in particular need a 206-capable static host.

signal _done(id: int, body: PackedByteArray)

var _seq := 0
var _pending: Dictionary = {}  # id -> PackedByteArray


func fetch(url: String) -> PackedByteArray:
	return await _request(url, PackedStringArray())


func fetch_range(url: String, start: int, length: int) -> PackedByteArray:
	if length <= 0:
		return PackedByteArray()
	var headers := PackedStringArray(
			["Range: bytes=%d-%d" % [start, start + length - 1]])
	return await _request(url, headers)


func _request(url: String, headers: PackedStringArray) -> PackedByteArray:
	_seq += 1
	var id := _seq
	var http := HTTPRequest.new()
	http.timeout = 300.0
	http.accept_gzip = false  # gzip would corrupt Range offsets
	add_child(http)
	var err := http.request(url, headers)
	if err != OK:
		http.queue_free()
		push_warning("WebSource: request failed to start (%d): %s" % [err, url])
		return PackedByteArray()
	http.request_completed.connect(
			func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
				if result == HTTPRequest.RESULT_SUCCESS and (code == 200 or code == 206):
					_pending[id] = body
				else:
					push_warning("WebSource: HTTP %d (result %d) for %s" % [code, result, url])
					_pending[id] = PackedByteArray()
				_done.emit(id))
	while not _pending.has(id):
		await _done
	var body: PackedByteArray = _pending[id]
	_pending.erase(id)
	http.queue_free()
	return body
