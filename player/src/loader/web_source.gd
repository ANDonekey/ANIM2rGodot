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
	return await _request(url, PackedStringArray(), -1, 0)


func fetch_range(url: String, start: int, length: int) -> PackedByteArray:
	if length <= 0:
		return PackedByteArray()
	var headers := PackedStringArray(
			["Range: bytes=%d-%d" % [start, start + length - 1]])
	return await _request(url, headers, start, length)


## One logical request with retries: the static host (r2.dev) is
## known to throw transient 500s, and a single failed fetch used to
## silence the corresponding audio file for the whole session.
## Range requests additionally validate the body: a 200 response
## (Range ignored by an intermediary) is only usable when it holds
## the requested window, which is then sliced out.
func _request(url: String, headers: PackedStringArray,
		range_start: int, range_len: int) -> PackedByteArray:
	for attempt in 3:
		if attempt > 0:
			await get_tree().create_timer(0.6 * attempt).timeout
		var body := await _request_once(url, headers)
		if body.is_empty():
			continue
		if range_start < 0:
			return body
		if body.size() == range_len:
			return body
		if body.size() > range_len and body.size() >= range_start + range_len:
			# Full-body 200 for a Range request: slice the window.
			return body.slice(range_start, range_start + range_len)
		push_warning("WebSource: bad range body (%d bytes, want %d) for %s"
				% [body.size(), range_len, url])
	push_warning("WebSource: giving up after retries: %s" % url)
	return PackedByteArray()


func _request_once(url: String, headers: PackedStringArray) -> PackedByteArray:
	_seq += 1
	var id := _seq
	var http := HTTPRequest.new()
	http.timeout = 120.0
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
