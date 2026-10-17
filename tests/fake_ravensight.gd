# The SDK with its outside world replaced: a fake transport that records
# every request and answers only when a test says so, a fake clock, a
# private storage folder, and a quit that is recorded instead of performed.
extends "res://Ravensight.gd"

const TEST_STORAGE_DIR := "user://ravensight_tests/"

var fake_now: float = 1000.0
var fake_unix: int = 1800000000
var mobile: bool = false
## What _random() returns: 0.5 is a jitter factor of exactly 1.0, so the
## backoff waits are the unspread 10, 20, 40 seconds.
var fake_random: float = 0.5
var web: bool = false
var memory: float = 128.0
var ticks: int = 2500
## Every request: {method, path, headers, body, callback, answered}.
var requests: Array = []
var quit_codes: Array = []

func _init() -> void:
	super()
	# Tests run with a key unless they pass "ingest_key": "" to make().
	ingest_key = "gt_live_test"

func _random() -> float:
	return fake_random

func _now() -> float:
	return fake_now

func _unix_now() -> int:
	return fake_unix

func _storage_dir() -> String:
	return TEST_STORAGE_DIR

func _is_mobile() -> bool:
	return mobile

func _is_web() -> bool:
	return web

func _memory_mb() -> float:
	return memory

func _ticks_msec() -> int:
	return ticks

func _quit_tree(exit_code: int) -> void:
	quit_codes.append(exit_code)

func _process(_delta: float) -> void:
	# Timers run only when a test calls advance().
	pass

func _send(method: String, path: String, headers: Array, body: String, callback: Callable) -> void:
	requests.append({
		"method": method,
		"path": path,
		"headers": headers,
		"body": body,
		"callback": callback,
		"answered": false,
	})

## Moves both clocks forward and runs the timers.
func advance(seconds: float) -> void:
	fake_now += seconds
	fake_unix += int(seconds)
	_tick()

func unanswered() -> Array:
	return requests.filter(func(r): return not r["answered"])

## Answers the oldest unanswered request. Returns it, or {} if none.
func answer(code: int, body: Variant = {}, headers: Array = []) -> Dictionary:
	var open := unanswered()
	if open.is_empty():
		return {}
	var req: Dictionary = open[0]
	req["answered"] = true
	var text: String = body if body is String else JSON.stringify(body)
	req["callback"].call(code, PackedStringArray(headers), text.to_utf8_buffer())
	return req

## Answers requests until none is left (or `limit` answers), using the
## ordinary happy answers: settings on, a session, batches accepted.
func answer_all_ok(limit: int = 100) -> void:
	for i in limit:
		var open := unanswered()
		if open.is_empty():
			return
		var path: String = open[0]["path"]
		match path:
			"/settings":
				answer(200, {"trackingEnabled": true})
			"/session":
				answer(201, {"token": "tok_%d" % requests.size(), "expiresIn": 86400})
			"/track/batch":
				answer(202, {"accepted": true})
			"/feedback":
				answer(201, {"ok": true})
			_:
				answer(200, {"suggestions": []})

func paths() -> Array:
	return requests.map(func(r): return str(r["path"]).split("?")[0])

func header(req: Dictionary, name: String) -> String:
	for h in req["headers"]:
		if str(h).begins_with(name + ": "):
			return str(h).substr(name.length() + 2)
	return ""

func events_in(req: Dictionary) -> Array:
	var parsed = JSON.parse_string(req["body"])
	if parsed is Dictionary and parsed.has("events"):
		return parsed["events"]
	return []

func event_names(req: Dictionary) -> Array:
	return events_in(req).map(func(e): return e["event"])
