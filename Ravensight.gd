# Ravensight.gd — Ravensight SDK v2
# Global autoload script for tracking game events against the hosted
# Ravensight SaaS API (/api/v1).
#
# Setup: Project -> Project Settings -> Autoload -> add this script,
# name it "Ravensight", enable it. Then set `api_url` and `ingest_key`
# in the Inspector (or override them from code before the autoload's
# _ready() runs, e.g. via an early autoload).
#
# See GODOT_GUIDE.md at the repo root for the full quickstart.

extends Node

## --- Signals -------------------------------------------------------------

## Emitted once a session token has been issued and is ready to use.
signal session_ready
## Emitted when session creation fails outright (see `reason` for detail).
signal session_failed(reason: String)
## Emitted once, on boot, if the server-side kill switch has tracking off.
signal tracking_disabled(source: String)
## Emitted after a batch of events is accepted by the server.
signal events_flushed(count: int)
## Emitted when a batch flush attempt fails (will be retried automatically).
signal flush_failed(reason: String)
## Emitted when a feedback submission is accepted.
signal feedback_submitted
## Emitted when a feedback submission fails.
signal feedback_failed(reason: String)
## EXPERIMENTAL: emitted with the result of fetch_suggestions().
## Suggestions are AI-generated design hints and may change shape over time.
signal suggestions_received(suggestions: Array)

## --- Configuration ---------------------------------------------------------

## Base URL of your Ravensight instance, e.g. "https://api.yourgame.com".
## Do NOT include a trailing slash or "/api/v1" — that's appended for you.
@export var api_url: String = "https://your-ravensight-instance.example.com"

## Your game's PUBLISHABLE ingest key (format: gt_live_...), copied from the
## Ravensight dashboard when you created the game. This key is safe to ship
## inside your game binary — it can only create sessions and read the
## tracking kill switch. It can NOT read analytics, feedback, or manage your
## account. Rotate it from the dashboard if it ever needs to change.
@export var ingest_key: String = "gt_live_your_ingest_key_here"

## Reported to the server as the client's game version.
@export var game_version: String = "1.0.0"

## Maximum number of not-yet-sent events kept in memory while offline or
## between flushes. Oldest events are dropped first once this is exceeded.
@export var max_queue_size: int = 100

## --- Constants --------------------------------------------------------------

const MAX_BATCH_SIZE: int = 50          # server hard limit on /track/batch
const DEFAULT_RETRY_SECONDS: float = 10.0
const MAX_BACKOFF_SECONDS: float = 300.0  # cap exponential backoff at 5 min

## --- State -------------------------------------------------------------------

var device_id: String = ""

var session_token: String = ""
var session_expires_at: int = 0
var _session_request_pending: bool = false

## True unless the server-side kill switch (GET /api/v1/settings) disabled
## tracking for this game. Checked once at boot.
var tracking_enabled: bool = true

var pending_events: Array = []
var _flush_in_progress: bool = false

var _backoff_seconds: float = DEFAULT_RETRY_SECONDS
var _retry_timer: Timer

## --- Lifecycle ----------------------------------------------------------------

func _ready() -> void:
	device_id = _load_or_create_device_id()

	_retry_timer = Timer.new()
	_retry_timer.one_shot = true
	add_child(_retry_timer)
	_retry_timer.timeout.connect(_on_retry_timer_timeout)

	_check_server_settings()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if tracking_enabled:
			track_event("game_exited", {})
			# Best-effort: give the request a brief moment to leave before
			# the process exits. Not guaranteed to complete on all platforms.
			if _is_session_valid():
				await get_tree().create_timer(0.5).timeout

## --- Device ID persistence ----------------------------------------------------

func _load_or_create_device_id() -> String:
	var save_path := "user://device_id.save"
	if FileAccess.file_exists(save_path):
		var file := FileAccess.open(save_path, FileAccess.READ)
		if file:
			var saved_id := file.get_as_text()
			file.close()
			if saved_id.length() > 0:
				return saved_id

	var new_id := "%s_%s_%d" % [
		OS.get_unique_id(),
		OS.get_name(),
		Time.get_unix_time_from_system(),
	]

	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file:
		file.store_string(new_id)
		file.close()

	return new_id

## --- Server kill switch (GET /api/v1/settings) ---------------------------------

func _check_server_settings() -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_settings_response.bind(http))

	var headers := ["X-API-Key: " + ingest_key]
	var err := http.request(api_url + "/api/v1/settings", headers, HTTPClient.METHOD_GET)
	if err != OK:
		push_warning("Ravensight: settings check failed to start (error %d); assuming tracking enabled" % err)
		http.queue_free()
		_after_settings_checked()

func _on_settings_response(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()

	if response_code == 200:
		var parsed = _parse_json(body)
		if parsed is Dictionary and parsed.has("trackingEnabled"):
			tracking_enabled = bool(parsed["trackingEnabled"])
	else:
		push_warning("Ravensight: could not fetch settings (HTTP %d); assuming tracking enabled" % response_code)

	_after_settings_checked()

func _after_settings_checked() -> void:
	if tracking_enabled:
		# Kicks off session creation as a side effect of enqueuing the event.
		track_event("game_started", {})
	else:
		print("Ravensight: tracking disabled by server kill switch")
		tracking_disabled.emit("server")

## --- Session management (POST /api/v1/session) ---------------------------------

func _is_session_valid() -> bool:
	return session_token.length() > 0 and Time.get_unix_time_from_system() < session_expires_at

func _start_session() -> void:
	if _session_request_pending:
		return
	_session_request_pending = true

	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_session_response.bind(http))

	var headers := ["Content-Type: application/json", "X-API-Key: " + ingest_key]
	var body := JSON.stringify({
		"deviceId": device_id,
		"gameVersion": game_version,
		"platform": OS.get_name(),
	})

	var err := http.request(api_url + "/api/v1/session", headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_session_request_pending = false
		http.queue_free()
		push_error("Ravensight: failed to start session request (error %d)" % err)
		_schedule_retry()

func _on_session_response(_result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	_session_request_pending = false

	if response_code == 201:
		var parsed = _parse_json(body)
		if parsed is Dictionary and parsed.has("token"):
			session_token = str(parsed["token"])
			if parsed.has("expiresAt"):
				session_expires_at = int(parsed["expiresAt"])
			else:
				var expires_in := int(parsed.get("expiresIn", 86400))
				session_expires_at = int(Time.get_unix_time_from_system()) + expires_in

			_backoff_seconds = DEFAULT_RETRY_SECONDS
			print("Ravensight: session ready")
			session_ready.emit()
			_flush_pending()
		else:
			push_error("Ravensight: malformed session response")
			session_failed.emit("malformed_response")
			_schedule_retry()
	elif response_code == 429:
		var reason := _extract_error(body, "rate_limited")
		push_warning("Ravensight: session creation rate-limited (%s)" % reason)
		session_failed.emit(reason)
		_schedule_retry(_extract_retry_after(headers))
	else:
		var reason2 := _extract_error(body, "http_%d" % response_code)
		push_error("Ravensight: session creation failed (HTTP %d)" % response_code)
		session_failed.emit(reason2)
		_schedule_retry()

## --- Retry / backoff ------------------------------------------------------------

func _schedule_retry(explicit_wait_seconds: float = -1.0) -> void:
	var wait := explicit_wait_seconds if explicit_wait_seconds > 0.0 else _backoff_seconds
	_backoff_seconds = min(_backoff_seconds * 2.0, MAX_BACKOFF_SECONDS)

	_retry_timer.stop()
	_retry_timer.wait_time = max(wait, 0.5)
	_retry_timer.start()

func _on_retry_timer_timeout() -> void:
	if not tracking_enabled:
		return
	if not _is_session_valid():
		_start_session()
	else:
		_flush_pending()

## --- Public API: event tracking --------------------------------------------------

## Queue an event for delivery. Events are flushed in batches (up to 50 at a
## time) via POST /api/v1/track/batch as soon as a valid session is available.
## Safe to call before the session is ready — events are queued and sent once
## the session is established (or once tracking is confirmed enabled).
func track_event(event_name: String, data: Dictionary = {}) -> void:
	if not tracking_enabled:
		return

	_enqueue(event_name, data)

	if _is_session_valid():
		_flush_pending()
	elif not _session_request_pending:
		_start_session()

## Force an immediate flush attempt of any queued events (no-op if none are
## queued, no session is ready yet, or a flush is already in flight).
func flush() -> void:
	_flush_pending()

func _enqueue(event_name: String, data: Dictionary) -> void:
	if pending_events.size() >= max_queue_size:
		pending_events.pop_front()  # drop oldest to make room for newest
	pending_events.append({
		"event": event_name,
		"data": data,
		"timestamp": int(Time.get_unix_time_from_system()),
	})

func _flush_pending() -> void:
	if _flush_in_progress or pending_events.is_empty() or not _is_session_valid():
		return
	_flush_in_progress = true

	var batch_size: int = min(MAX_BATCH_SIZE, pending_events.size())
	var batch: Array = pending_events.slice(0, batch_size)

	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_batch_response.bind(http, batch_size))

	var headers := ["Content-Type: application/json", "X-Session-Token: " + session_token]
	var body := JSON.stringify({"events": batch})

	var err := http.request(api_url + "/api/v1/track/batch", headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_flush_in_progress = false
		http.queue_free()
		push_error("Ravensight: failed to start batch flush (error %d)" % err)
		_schedule_retry()

func _on_batch_response(_result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, batch_size: int) -> void:
	http.queue_free()
	_flush_in_progress = false

	if response_code == 202:
		pending_events = pending_events.slice(batch_size, pending_events.size())
		_backoff_seconds = DEFAULT_RETRY_SECONDS
		events_flushed.emit(batch_size)
		if not pending_events.is_empty():
			call_deferred("_flush_pending")
	elif response_code == 401:
		# Session expired or was revoked; drop it and start a new one. Queued
		# events are left in place and will be flushed once re-established.
		push_warning("Ravensight: session invalid/expired, refreshing")
		session_token = ""
		session_expires_at = 0
		_start_session()
	elif response_code == 429:
		var reason := _extract_error(body, "rate_limited")
		push_warning("Ravensight: track/batch rate-limited (%s)" % reason)
		flush_failed.emit(reason)
		_schedule_retry(_extract_retry_after(headers))
	else:
		var reason2 := _extract_error(body, "http_%d" % response_code)
		push_warning("Ravensight: batch flush failed (HTTP %d), will retry" % response_code)
		flush_failed.emit(reason2)
		_schedule_retry()

## --- Public API: feedback (POST /api/v1/feedback) --------------------------------

## Submit free-form player feedback. `category` and `rating` are optional;
## pass rating in 1-5 if you have one, or leave it 0 to omit it.
func submit_feedback(message: String, category: String = "", rating: int = 0) -> void:
	if not tracking_enabled:
		push_warning("Ravensight: tracking disabled, feedback not sent")
		feedback_failed.emit("tracking_disabled")
		return
	if message.is_empty():
		push_warning("Ravensight: feedback message is empty")
		feedback_failed.emit("empty_message")
		return
	if not _is_session_valid():
		push_warning("Ravensight: no valid session yet, cannot submit feedback")
		feedback_failed.emit("no_session")
		if not _session_request_pending:
			_start_session()
		return

	var payload := {"message": message}
	if not category.is_empty():
		payload["category"] = category
	if rating > 0:
		payload["rating"] = rating

	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_feedback_response.bind(http))

	var headers := ["Content-Type: application/json", "X-Session-Token: " + session_token]
	var err := http.request(api_url + "/api/v1/feedback", headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		http.queue_free()
		push_error("Ravensight: failed to submit feedback (error %d)" % err)
		feedback_failed.emit("request_error")

func _on_feedback_response(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if response_code == 201:
		feedback_submitted.emit()
	else:
		push_warning("Ravensight: feedback submission failed (HTTP %d)" % response_code)
		feedback_failed.emit(_extract_error(body, "http_%d" % response_code))

## --- EXPERIMENTAL: agent suggestions (GET /api/v1/agent/suggestions) -------------
##
## This hits an AI-generated suggestions endpoint that is still evolving on
## the server side (empty array until your game has accumulated enough data
## for weekly digests). Shape may change; treat this as experimental and
## don't build critical game logic around it.

func fetch_suggestions() -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_suggestions_response.bind(http))

	var headers := ["X-API-Key: " + ingest_key]
	var err := http.request(api_url + "/api/v1/agent/suggestions", headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		push_error("Ravensight: failed to fetch suggestions (error %d)" % err)
		suggestions_received.emit([])

func _on_suggestions_response(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if response_code == 200:
		var parsed = _parse_json(body)
		if parsed is Dictionary and parsed.has("suggestions") and parsed["suggestions"] is Array:
			suggestions_received.emit(parsed["suggestions"])
		else:
			suggestions_received.emit([])
	else:
		push_warning("Ravensight: fetch_suggestions failed (HTTP %d)" % response_code)
		suggestions_received.emit([])

## --- Helpers ------------------------------------------------------------------

func _parse_json(body: PackedByteArray):
	var json := JSON.new()
	var err := json.parse(body.get_string_from_utf8())
	if err != OK:
		return null
	return json.data

func _extract_error(body: PackedByteArray, fallback: String) -> String:
	var parsed = _parse_json(body)
	if parsed is Dictionary and parsed.has("error"):
		return str(parsed["error"])
	return fallback

## Parses a Retry-After header (delta-seconds form) if present. Returns -1.0
## when absent so callers fall back to their own exponential backoff.
func _extract_retry_after(headers: PackedStringArray) -> float:
	for h in headers:
		if h.to_lower().begins_with("retry-after:"):
			var parts := h.split(":", true, 1)
			if parts.size() == 2:
				var val := parts[1].strip_edges()
				if val.is_valid_int():
					return float(int(val))
	return -1.0
