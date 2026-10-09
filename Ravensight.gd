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
## Emitted on boot if the server-side kill switch has tracking off (source
## "server") or the player has opted out (source "player"), and again when
## set_tracking_enabled(false) is called.
signal tracking_disabled(source: String)
## Emitted after a batch of events is delivered (the server answered 2xx).
## `count` is the number sent; the server may store fewer, e.g. it drops
## events whose timestamp is older than 90 days.
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
## Emitted every time track_event() queues an event, with the data actually
## queued (playtest tags included, in a playtest run). Lets something else in
## the running game mirror tracked events, e.g. a playtest driver watching
## gameplay from outside the process.
signal event_tracked(event_name: String, data: Dictionary)

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
## Where this install's random device id lives (see _load_or_create_device_id).
const DEVICE_ID_PATH: String = "user://device_id.save"
## Present only while the player has opted out (see set_tracking_enabled).
const OPTOUT_PATH: String = "user://ravensight_optout.save"

## --- State -------------------------------------------------------------------

var device_id: String = ""

var session_token: String = ""
var session_expires_at: int = 0
var _session_request_pending: bool = false
## Bumped every time _start_session() actually dispatches a request. Bound
## into that request's callback so _on_session_response() can tell a stale
## response (from a request superseded by a newer one, e.g. set_playtest_
## context() switching identity mid-flight) from the current one, and
## ignore it instead of letting it clobber session state.
var _session_request_generation: int = 0

## True unless the server-side kill switch (GET /api/v1/settings) disabled
## tracking for this game, or the player opted out through
## set_tracking_enabled(false). The SDK keeps it in sync; read it any time,
## but change it through set_tracking_enabled() so the choice persists.
var tracking_enabled: bool = true
## The kill switch's last answer, kept apart from the player's choice so that
## re-enabling after an opt-out can never override a server-side "off".
var _server_tracking_enabled: bool = true
## The player's persisted opt-out, read from OPTOUT_PATH in _ready() before
## anything can queue or send an event.
var _player_opted_out: bool = false

var pending_events: Array = []
var _flush_in_progress: bool = false
# When a 400 forced a split, flushes use this reduced batch size until the
# poison event is isolated and dropped (0 = no split active).
var _split_batch_size: int = 0

var _backoff_seconds: float = DEFAULT_RETRY_SECONDS
var _retry_timer: Timer

## --- Playtest mode ------------------------------------------------------------
##
## Set from RAVENSIGHT_PLAYTEST_TOKEN (or a --ravensight-playtest-token=
## launch arg) when this run is being driven by the Ravensight CLI's
## playtest runner. Empty in a normal player build, which never sends the
## playtest header or tags below.

## The playtest auth token, sent as the X-Ravensight-Playtest header. Empty
## outside a playtest run.
var playtest_token := ""
var _playtest_run_id: String = ""
## Tags merged into every tracked event's data while playtest_token is set;
## see set_playtest_context().
var _playtest_tags := {}
## Set when the server has permanently rejected this run's playtest token or
## reports the job closed (see _is_fatal_playtest_reason()). Once true,
## _start_session() refuses to POST /session again for the rest of the run,
## and track_event()'s own fallback to start one is skipped too - otherwise
## the very next tracked event (continuous, in a driven playtest run) would
## reopen a session attempt with the same already-rejected token. Events
## tracked while blocked simply stay queued; nothing flushes them, since no
## session is ever established. Cleared only by a fresh set_playtest_
## context() call, which represents a genuinely new attempt.
var _playtest_blocked: bool = false

## --- Lifecycle ----------------------------------------------------------------

func _ready() -> void:
	_apply_playtest_env()

	if playtest_token.is_empty():
		device_id = _load_or_create_device_id()
		# The player's opt-out is honoured before anything can queue or send
		# an event. A playtest run ignores it: that traffic is the studio's
		# own synthetic run under a throwaway identity, and a flag left on a
		# developer's machine must not silently empty a paid run.
		_player_opted_out = FileAccess.file_exists(OPTOUT_PATH)
		tracking_enabled = not _player_opted_out
	else:
		# A playtest run gets a throwaway id derived from its run id and is
		# never persisted: it must never be confused with, or pollute, a
		# real player's device_id.save history.
		device_id = "pt-" + _playtest_run_id

	_retry_timer = Timer.new()
	_retry_timer.one_shot = true
	add_child(_retry_timer)
	_retry_timer.timeout.connect(_on_retry_timer_timeout)

	if _player_opted_out:
		# Nothing leaves the device, not even the settings check.
		print("Ravensight: tracking disabled by player opt-out")
		tracking_disabled.emit("player")
	else:
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
	# An id saved by any earlier version is kept exactly as it is, whatever
	# its shape, so existing players keep their history. Only a fresh
	# install gets the random id below.
	if FileAccess.file_exists(DEVICE_ID_PATH):
		var file := FileAccess.open(DEVICE_ID_PATH, FileAccess.READ)
		if file:
			var saved_id := file.get_as_text()
			file.close()
			if saved_id.length() > 0:
				return saved_id

	var new_id := _generate_device_id()
	_save_device_id(new_id)
	return new_id

## A new device id: 16 random bytes as lowercase hex, a dash, and the
## lowercased OS name (kept because the per-OS split in analytics reads it),
## e.g. "3f1c...9a-windows". It identifies this install of this game and
## nothing else.
##
## Earlier versions built the id from OS.get_unique_id(), a value derived
## from the device's hardware or OS install. The product promises a random
## device id with no hardware identifier, so that is gone. No id, old or
## new, was ever linked to an account: Ravensight has no player accounts.
func _generate_device_id() -> String:
	var random_bytes := Crypto.new().generate_random_bytes(16)
	return "%s-%s" % [random_bytes.hex_encode(), OS.get_name().to_lower()]

func _save_device_id(id: String) -> void:
	var file := FileAccess.open(DEVICE_ID_PATH, FileAccess.WRITE)
	if file:
		file.store_string(id)
		file.close()

## --- Playtest mode setup --------------------------------------------------------

## Reads RAVENSIGHT_PLAYTEST_TOKEN/RUN_ID/JOB_ID/PERSONA from the environment
## (set by the Ravensight CLI's playtest runner before it launches the game),
## or a --ravensight-playtest-token= user arg for the token, and applies them
## the same way set_playtest_context() would. A no-op when none are present,
## which is every normal player build.
func _apply_playtest_env() -> void:
	var token := OS.get_environment("RAVENSIGHT_PLAYTEST_TOKEN")
	if token.is_empty():
		token = _get_cmdline_arg_value("ravensight-playtest-token")
	if token.is_empty():
		return

	set_playtest_context({
		"token": token,
		"run_id": OS.get_environment("RAVENSIGHT_PLAYTEST_RUN_ID"),
		"job_id": OS.get_environment("RAVENSIGHT_PLAYTEST_JOB_ID"),
		"persona": OS.get_environment("RAVENSIGHT_PLAYTEST_PERSONA"),
	})

func _get_cmdline_arg_value(arg_name: String) -> String:
	var prefix := "--%s=" % arg_name
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""

## Switches this SDK instance into playtest mode: sessions are opened with
## the playtest header and platform, device_id becomes a throwaway id that is
## never persisted, and every tracked event is tagged as synthetic. Called
## automatically at boot from the RAVENSIGHT_PLAYTEST_* environment (see
## _apply_playtest_env()); call it directly if you wire a driver up some
## other way, e.g. attaching to an already-running game.
##
## ctx keys: "token" and "run_id" are required; "job_id", "persona" and
## "tier" are optional (persona/job_id default to "", tier defaults to
## "T2_driven_build"). Restarts the session if one is already open or in
## flight, so every event from this point on carries the new tags.
func set_playtest_context(ctx: Dictionary) -> void:
	var token := str(ctx.get("token", ""))
	var run_id := str(ctx.get("run_id", ""))
	if token.is_empty() or run_id.is_empty():
		push_warning("Ravensight: set_playtest_context() needs both token and run_id")
		return

	playtest_token = token
	_playtest_run_id = run_id
	device_id = "pt-" + run_id
	# A fresh context is a fresh attempt, even if the previous one ended in
	# a fatal rejection.
	_playtest_blocked = false
	# A playtest run ignores the player's opt-out (see _ready()); the flag
	# on disk is left exactly as the player set it.
	if _player_opted_out:
		_player_opted_out = false
		tracking_enabled = _server_tracking_enabled

	_playtest_tags = {
		"synthetic": true,
		"persona": str(ctx.get("persona", "")),
		"pt_job": str(ctx.get("job_id", "")),
		"pt_run": run_id,
		"pt_source": "sdk",
		"pt_tier": str(ctx.get("tier", "T2_driven_build")),
	}

	var had_session := not session_token.is_empty() or _session_request_pending
	if had_session:
		session_token = ""
		session_expires_at = 0
		# If a session request for the old identity is still in flight,
		# clearing _session_request_pending here lets _start_session()'s
		# own re-entrancy guard pass so a new request goes out immediately.
		# That new request bumps _session_request_generation, so when the
		# stale one eventually completes, _on_session_response() sees an
		# outdated generation and ignores it instead of racing the new
		# session into session_token.
		_session_request_pending = false
		_start_session()

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
			_server_tracking_enabled = bool(parsed["trackingEnabled"])
	else:
		push_warning("Ravensight: could not fetch settings (HTTP %d); assuming tracking enabled" % response_code)

	_after_settings_checked()

func _after_settings_checked() -> void:
	# The server switch wins when it says off, and so does the player's
	# opt-out. Both have to be on for anything to be sent.
	tracking_enabled = _server_tracking_enabled and not _player_opted_out
	if not _server_tracking_enabled:
		print("Ravensight: tracking disabled by server kill switch")
		tracking_disabled.emit("server")
	elif tracking_enabled:
		# Kicks off session creation as a side effect of enqueuing the event.
		track_event("game_started", {})

## --- Session management (POST /api/v1/session) ---------------------------------

func _is_session_valid() -> bool:
	return session_token.length() > 0 and Time.get_unix_time_from_system() < session_expires_at

func _start_session() -> void:
	# A previous attempt was fatally rejected (bad/expired playtest token, or
	# a closed job) - never POST /session again for the rest of this run.
	# Only a fresh set_playtest_context() call clears this.
	if _playtest_blocked:
		return
	# Opted out or killed server-side: no session is ever opened.
	if not tracking_enabled:
		return
	if _session_request_pending:
		return
	_session_request_pending = true
	_session_request_generation += 1
	var generation := _session_request_generation

	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_session_response.bind(http, generation))

	var headers := ["Content-Type: application/json", "X-API-Key: " + ingest_key]
	var platform := OS.get_name()
	if not playtest_token.is_empty():
		headers.append("X-Ravensight-Playtest: " + playtest_token)
		platform = "ravensight-playtest"

	var body := JSON.stringify({
		"deviceId": device_id,
		"gameVersion": game_version,
		"platform": platform,
	})

	var err := http.request(api_url + "/api/v1/session", headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		_session_request_pending = false
		http.queue_free()
		push_error("Ravensight: failed to start session request (error %d)" % err)
		_schedule_retry()

func _on_session_response(_result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest, generation: int) -> void:
	http.queue_free()

	# A newer session attempt has started since this request went out (e.g.
	# set_playtest_context() switched identity mid-flight). This response
	# describes an identity we've already abandoned - ignore it entirely
	# rather than letting it clear the newer request's pending flag or,
	# worse, overwrite session_token/session_expires_at with a session the
	# server never tagged as synthetic while queued events already carry
	# playtest tags.
	if generation != _session_request_generation:
		return

	_session_request_pending = false

	if response_code == 201:
		var parsed = _parse_json(body)
		if parsed is Dictionary and parsed.has("token"):
			session_token = str(parsed["token"])
			# The server sends expiresIn (seconds) and expiresAt (an ISO
			# string, which int() would mangle). expiresIn is the contract.
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
	elif response_code == 403 and _is_fatal_playtest_reason(body):
		var reason3 := _extract_error(body, "http_403")
		# The playtest token is bad or the job has already closed: neither
		# resolves itself. Skipping _schedule_retry() only stops the timer-
		# driven retry; track_event()'s and _start_session()'s own
		# fallbacks would otherwise reopen a session on the very next
		# tracked event, so set the persistent guard too - see
		# _playtest_blocked.
		_playtest_blocked = true
		push_error("Ravensight: playtest session refused (%s)" % reason3)
		session_failed.emit(reason3)
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

	var queued_data := _enqueue(event_name, data)
	event_tracked.emit(event_name, queued_data)

	if _is_session_valid():
		_flush_pending()
	elif not _session_request_pending and not _playtest_blocked:
		# _playtest_blocked means an earlier fatal rejection already killed
		# this run's session attempts; leave the event queued rather than
		# reopening a request with the same rejected token.
		_start_session()

## Force an immediate flush attempt of any queued events (no-op if none are
## queued, no session is ready yet, or a flush is already in flight).
func flush() -> void:
	_flush_pending()

## --- Public API: player privacy -------------------------------------------------
##
## Ravensight ships no consent UI. If your game shows its own consent or
## privacy screen, or a settings toggle, wire it to the two calls below.

## Turns tracking off or on for this player and remembers the choice across
## launches (a flag file at OPTOUT_PATH). While off: no session is opened,
## track_event() drops the event, anything already queued is discarded, and
## nothing is sent, not even the settings check on the next boot. Turning it
## back on re-reads the server kill switch, which still wins when it says
## off, then opens a new session and sends game_started as on boot.
func set_tracking_enabled(enabled: bool) -> void:
	_player_opted_out = not enabled
	_write_optout_flag(_player_opted_out)

	if _player_opted_out:
		tracking_enabled = false
		_drop_session()
		pending_events.clear()
		_retry_timer.stop()
		print("Ravensight: tracking disabled by player opt-out")
		tracking_disabled.emit("player")
	else:
		_check_server_settings()

## True when events are being collected: the player has not opted out and
## the server kill switch is on. The same answer as reading tracking_enabled.
func is_tracking_enabled() -> bool:
	return tracking_enabled

## Forgets this install's analytics identity: deletes the saved device id,
## generates a fresh random one, and drops the current session token and the
## in-memory queue, so the next tracked event opens a new session under the
## new id. Wire this to a "reset my analytics identity" setting if you offer
## one. Events already on the server stay under the old id, which nothing
## links back to this player. A no-op in a playtest run, whose id is a
## throwaway that is never saved.
func reset_device_id() -> void:
	if not playtest_token.is_empty():
		return
	DirAccess.remove_absolute(DEVICE_ID_PATH)
	device_id = _generate_device_id()
	_save_device_id(device_id)
	_drop_session()
	pending_events.clear()

func _write_optout_flag(opted_out: bool) -> void:
	if opted_out:
		var file := FileAccess.open(OPTOUT_PATH, FileAccess.WRITE)
		if file:
			file.store_string("1")
			file.close()
	elif FileAccess.file_exists(OPTOUT_PATH):
		DirAccess.remove_absolute(OPTOUT_PATH)

## Ends the current session without touching the queue. Bumping the request
## generation makes _on_session_response() ignore any session request still
## in flight for the old identity (see _session_request_generation).
func _drop_session() -> void:
	session_token = ""
	session_expires_at = 0
	_session_request_pending = false
	_session_request_generation += 1

## Queues the event and returns the data dictionary actually stored (a
## tagged copy in a playtest run, the original otherwise), so callers such
## as track_event() can mirror exactly what will be sent.
func _enqueue(event_name: String, data: Dictionary) -> Dictionary:
	if pending_events.size() >= max_queue_size:
		pending_events.pop_front()  # drop oldest to make room for newest

	var event_data := data
	if not playtest_token.is_empty():
		# Never mutate the caller's dictionary: duplicate before tagging.
		event_data = data.duplicate()
		event_data.merge(_playtest_tags, true)

	pending_events.append({
		"event": event_name,
		"data": event_data,
		"timestamp": int(Time.get_unix_time_from_system()),
	})

	return event_data

func _flush_pending() -> void:
	if not tracking_enabled:
		return
	if _flush_in_progress or pending_events.is_empty() or not _is_session_valid():
		return
	_flush_in_progress = true

	var batch_size: int = min(MAX_BATCH_SIZE, pending_events.size())
	if _split_batch_size > 0:
		batch_size = mini(batch_size, _split_batch_size)
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
		_split_batch_size = 0
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
	elif response_code == 400:
		# The server refuses the whole batch when any event in it violates a
		# ceiling. Halve until the poison event is isolated, then drop it -
		# one bloated event must never cost the rest of its batch, and
		# retrying the identical payload forever would deliver nothing.
		var reason400 := _extract_error(body, "http_400")
		if batch_size <= 1:
			pending_events = pending_events.slice(batch_size, pending_events.size())
			push_warning("Ravensight: dropped one rejected event (%s)" % reason400)
			flush_failed.emit(reason400)
			if not pending_events.is_empty():
				call_deferred("_flush_pending")
		else:
			_split_batch_size = maxi(1, batch_size / 2)
			push_warning("Ravensight: batch rejected (%s), splitting to %d" % [reason400, _split_batch_size])
			call_deferred("_flush_pending")
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

## True for the two playtest auth failures that will never clear up on their
## own: a bad/expired token, or a job the CLI has already closed out.
func _is_fatal_playtest_reason(body: PackedByteArray) -> bool:
	var reason := _extract_error(body, "")
	return reason == "invalid_playtest_token" or reason == "playtest_job_closed"

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
