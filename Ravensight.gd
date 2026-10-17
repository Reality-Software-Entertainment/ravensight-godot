# Ravensight.gd: Ravensight SDK for Godot 4
# Global autoload script for tracking game events against the hosted
# Ravensight API (/api/v1).
#
# Setup: Project -> Project Settings -> Autoload -> add this script,
# name it "Ravensight", enable it. Then set `ingest_key` (and `api_url` if
# you do not use https://api.ravensight.io) before the autoload's _ready()
# runs, e.g. from an earlier autoload, by editing the defaults below, or
# through the project setting ravensight/ingest_key. With no key the SDK is
# inert: no files, no requests, every call a no-op.
#
# Full guide: https://ravensight.io/docs/#godot-sdk

extends Node

## The SDK version. Bumped with every tagged release.
const VERSION := "0.3.0"

## --- Signals -------------------------------------------------------------

## Emitted once a session token has been issued and is ready to use.
signal session_ready
## Emitted when opening a session fails. `reason` is "invalid_key" when the
## ingest key was refused, otherwise the server's error code (or "offline").
signal session_failed(reason: String)
## Emitted when tracking turns off: source "server" for the kill switch,
## "player" for the player's opt-out (set_tracking_enabled(false)) or, with
## consent = "opt_in", for a start with no yes saved yet, "init" when the
## game turned the SDK off (enabled = false or set_enabled(false)), "key"
## when the server refused the ingest key and the run ended.
signal tracking_disabled(source: String)
## Emitted whenever get_status_reason() changes. `reason` is one of
## "no_key", "disabled", "invalid_key", "tracking_disabled", "offline",
## "rate_limited", "session_failed", "playtest_job_closed", or "" when
## nothing is wrong.
signal status_changed(reason: String)
## Emitted after a batch of events is delivered (the server answered 2xx).
## `count` is the number sent; the server may store fewer, e.g. it drops
## events whose timestamp is older than 90 days.
signal events_flushed(count: int)
## Emitted when a batch flush attempt fails (it is retried automatically,
## except a single event the server refuses with 400, which is dropped).
## Also emitted with "event_too_large" for an event whose data is over
## MAX_EVENT_BYTES as JSON, which is dropped before it is queued.
signal flush_failed(reason: String)
## Emitted when a feedback submission is accepted.
signal feedback_submitted
## Emitted when a feedback submission fails, locally ("disabled",
## "empty_message", "invalid_category", "invalid_rating", "no_session") or
## on the server (its error code).
signal feedback_failed(reason: String)
## EXPERIMENTAL: emitted with the result of fetch_suggestions().
## Suggestions are AI-generated design hints and may change shape over time.
signal suggestions_received(suggestions: Array)
## Emitted every time an event is queued, with the data actually queued
## (playtest tags included, in a playtest run). Lets something else in the
## running game mirror tracked events, e.g. a playtest driver watching
## gameplay from outside the process.
signal event_tracked(event_name: String, data: Dictionary)

## --- Configuration ---------------------------------------------------------

## The Ravensight API host. With or without a trailing "/api/v1" and with or
## without a trailing slash: see api_base(). Empty means the default.
@export var api_url: String = "https://api.ravensight.io"

## Your game's PUBLISHABLE ingest key (gt_live_... or, for a build anyone
## can download, a public gt_pub_... key), copied from the Ravensight
## dashboard. This key is safe to ship inside your game binary: it can open
## sessions, read the tracking kill switch and read this game's design
## suggestions. It can NOT read analytics, feedback, or manage your account.
## Rotate it from the dashboard if it ever needs to change.
## Empty (the default) falls back to the project setting
## ravensight/ingest_key; empty there too, the SDK is inert for the run: it
## writes no files, makes no request and every call is a quiet no-op.
@export var ingest_key: String = ""

## True silences the one warning an inert start (no key) prints.
@export var optional: bool = false

## "opt_out" (the default): tracking runs until the player turns it off.
## "opt_in": nothing happens before the player's yes through
## set_tracking_enabled(true): no device id, no settings check, no session,
## and events tracked before the yes are dropped. The yes is saved at
## OPTIN_PATH. Anything else counts as "opt_out".
@export var consent: String = "opt_out"

## A short label of your own for this build, such as "native-release",
## "web-itch" or "steam-demo", sent on the session as `distribution`. At
## most 40 characters (UTF-16 units, as the server counts them), no control
## characters; anything else is not sent (one warning). Empty sends nothing.
@export var distribution: String = ""

## Reported to the server as the client's game version.
@export var game_version: String = "1.0.0"

## False turns the SDK off for this run: no request of any kind, nothing
## queued, no game_started, until set_enabled(true). Never saved. For a
## player's own choice use set_tracking_enabled(), which is saved.
@export var enabled: bool = true

## Maximum number of not-yet-sent events kept in memory while offline or
## between flushes. Oldest events are dropped first once this is exceeded
## (a queued game_started is kept).
@export var max_queue_size: int = 500

## Seconds an event may wait so it can go out with others. 50 waiting
## events are sent at once without waiting.
@export var flush_interval: float = 5.0

## On Android and iOS: how long the app may sit in the background before
## the session counts as over (game_exited at the moment it went to the
## background, then a new session with game_started on return).
@export var session_timeout: float = 1800.0

## --- Constants --------------------------------------------------------------

const MAX_BATCH_SIZE: int = 50          # server hard limit on /track/batch
const DEFAULT_RETRY_SECONDS: float = 10.0
const MAX_BACKOFF_SECONDS: float = 300.0  # cap exponential backoff at 5 min
## Backoff waits are spread by plus or minus this fraction, so many games
## that failed together do not retry together. Retry-After is never spread.
const JITTER: float = 0.2
## The largest event the API accepts, measured as the server measures it:
## the JSON of the event's data. Bigger events are dropped before queueing.
const MAX_EVENT_BYTES: int = 8192
const MAX_DISTRIBUTION_LENGTH: int = 40
const CONSENT_OPT_OUT := "opt_out"
const CONSENT_OPT_IN := "opt_in"
## Every request gives up after this long and counts as offline.
const REQUEST_TIMEOUT_SECONDS: float = 15.0
## A batch 401 reopens the session at most this many times in a row.
const MAX_REAUTH_ATTEMPTS: int = 2
## The categories the feedback endpoint accepts. Anything else is refused
## before it is sent.
const FEEDBACK_CATEGORIES: Array[String] = ["bug", "suggestion", "complaint", "praise", "playtest", "other"]
## Where this install's random device id lives (see _load_or_create_device_id).
const DEVICE_ID_PATH: String = "user://device_id.save"
## Present only while the player has opted out (see set_tracking_enabled).
const OPTOUT_PATH: String = "user://ravensight_optout.save"
## With consent = "opt_in": present only once the player has said yes.
const OPTIN_PATH: String = "user://ravensight_optin.save"
## Present only while the app is in the background on Android or iOS.
const BACKGROUND_MARKER_PATH: String = "user://ravensight_bg.save"
const INVALID_KEY_MESSAGE := "Ravensight: ingest key refused (invalid_key), sending stopped for this run. Check your gt_live_ key."

## --- State -------------------------------------------------------------------

var device_id: String = ""

## The open session's token, or "" until one opens. Read it if your game
## server should join the same session (send it as `joinToken`, see the
## HTTP API). Never write it.
var session_token: String = ""
var session_expires_at: int = 0
var _session_request_pending: bool = false
## Bumped every time a session is requested or dropped. Bound into each
## session request's callback so a stale response (from a request
## superseded by a newer one, e.g. set_playtest_context() switching identity
## mid-flight) is ignored instead of clobbering session state.
var _session_request_generation: int = 0

## Read-only: true while events are collected and sent. False when the game
## turned the SDK off (enabled), the player opted out, the server kill
## switch is off, or a playtest run was refused.
var tracking_enabled: bool:
	get:
		return _is_active()
	set(_value):
		push_warning("Ravensight: tracking_enabled is read-only, use set_tracking_enabled() or set_enabled()")

## The player's persisted opt-out, read from OPTOUT_PATH when the SDK is
## constructed, before anything can queue or send an event.
var _player_opted_out: bool = false
## The server kill switch said off (settings check or a 403
## tracking_disabled). Final for the rest of the run.
var _killed: bool = false
## The server refused the ingest key (401 or 403 that is not the kill
## switch or a playtest refusal). Final for the rest of the run.
var _key_refused: bool = false
## Started with no ingest key: inert for the rest of the run.
var _no_key: bool = false
## The distribution label actually sent, after validation.
var _distribution: String = ""
## rs_event_id parts: a per-launch nonce from the secure random source and
## a counter.
var _event_nonce: String = ""
var _event_counter: int = 0
var _settings_checked: bool = false
var _settings_pending: bool = false
## Set at the end of _ready(). Before that, track_event() only queues.
var _is_ready: bool = false

var pending_events: Array = []
var _flush_in_progress: bool = false
## Bumped every time the queue is discarded (opt-out, reset_device_id(), the
## kill switch). Bound into each batch request's callback so a response for
## a batch taken from the old queue is ignored, instead of slicing that
## many events off the front of the new one.
var _queue_generation: int = 0
## When a 400 forced a split, flushes use this reduced batch size until the
## poison event is isolated and dropped (0 = no split active).
var _split_batch_size: int = 0
## When above 0, the first this-many queued events belong to the current
## session and the session is dropped once they are delivered (the mobile
## background rule: game_exited goes out under the old session, then a new
## one opens for game_started).
var _session_boundary: int = 0
## _now() when the oldest unsent event was queued, or -1.
var _first_queued_at: float = -1.0
var _reauth_attempts: int = 0

var _backoff_seconds: float = DEFAULT_RETRY_SECONDS
## _now() at which the retry wait ends, or -1 when none is running.
var _retry_at: float = -1.0
## True when the running wait came from the server (Retry-After), which an
## explicit flush() does not cut short.
var _retry_from_server: bool = false

var _started_queued: bool = false
var _exit_queued: bool = false
## Unix time the SDK was constructed: game_started's timestamp.
var _start_unix: int = 0
## Unix time the app went to the background on Android or iOS, or 0.
var _backgrounded_at: int = 0

var _status_reason: String = ""
## The latest transient failure: "", "offline", "rate_limited" or
## "session_failed". get_status_reason() reports it when nothing worse holds.
var _transient_reason: String = ""
var _logged_once: Dictionary = {}

## --- Quit handling --------------------------------------------------------------

## When true (the default), the SDK takes over the window close so the last
## events, including game_exited, can be sent: it sets the SceneTree's
## auto_accept_quit to false in _ready(), and on a close request it flushes,
## then quits once the flush is answered or after
## QUIT_FLUSH_TIMEOUT_SECONDS, whichever comes first. The Android back
## button is handled the same way when the project's
## application/config/quit_on_go_back setting is on. Set this to false
## before the autoload is ready if your game manages the window close
## itself, e.g. with a confirm dialog; the SDK then only flushes on a close
## request, and your game quits with Ravensight.quit(), which sends
## game_exited.
## It is also treated as false when auto_accept_quit is already off at
## _ready().
@export var handle_quit: bool = true

## Longest the SDK delays a quit while it waits for the final flush.
const QUIT_FLUSH_TIMEOUT_SECONDS: float = 1.5

## True when the SDK owns the window close (see handle_quit).
var _owns_close_quit: bool = false
## True when the SDK owns the Android back button quit (see handle_quit).
var _owns_go_back_quit: bool = false
## Set once the flush then quit sequence has started.
var _quitting: bool = false
var _quit_called: bool = false
var _quit_deadline: float = -1.0
var _quit_exit_code: int = 0

## --- Playtest mode ------------------------------------------------------------
##
## Set from RAVENSIGHT_PLAYTEST_TOKEN and RAVENSIGHT_PLAYTEST_RUN_ID (or the
## --ravensight-playtest-token= and --ravensight-playtest-run-id= launch
## args) when this run is driven by the Ravensight CLI's playtest runner.
## Empty in a normal player build, which never sends the playtest header or
## tags below.

## The playtest auth token, sent as the X-Ravensight-Playtest header on every
## request. Empty outside a playtest run.
var playtest_token := ""
## Tags merged into every tracked event's data while playtest_token is set;
## see set_playtest_context().
var _playtest_tags := {}
## Set when the server has permanently rejected this run's playtest token,
## reports the job closed, or a token arrived without a run id. Nothing is
## sent for the rest of the run. Cleared only by a fresh
## set_playtest_context() call, which is a genuinely new attempt.
var _playtest_blocked: bool = false
var _playtest_reason: String = ""

## --- Lifecycle ----------------------------------------------------------------

func _init() -> void:
	_start_unix = _unix_now()
	_apply_playtest_env()
	if playtest_token.is_empty():
		# Read only: a saved id is used, but none is created before _ready()
		# knows there is a key and, with consent = "opt_in", a yes.
		device_id = _read_saved_device_id()
		# Read now, so a track_event() or set_tracking_enabled() from an
		# earlier autoload already sees the player's choice.
		_player_opted_out = not _saved_choice()

func _ready() -> void:
	_is_ready = true
	if ingest_key.strip_edges().is_empty():
		ingest_key = str(ProjectSettings.get_setting("ravensight/ingest_key", "")).strip_edges()
	if ingest_key.strip_edges().is_empty():
		# A keyless clone or a development build: inert, not an error. No
		# file, no request, no timer, and the window close is left alone.
		_no_key = true
		_clear_queue()
		set_process(false)
		if not optional:
			_log_once("no_key", "Ravensight: no ingest_key, so analytics is off for this run (set optional = true to silence this line)", true)
		_update_reason()
		return
	# Keep the timers running while the game is paused, so a paused game
	# still sends and still quits.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_take_over_quit()
	_distribution = _validated_distribution()

	if playtest_token.is_empty():
		# The game may have set `consent` after construction: read the
		# choice again for the final mode.
		_player_opted_out = not _saved_choice()
		if not _player_opted_out:
			_load_identity()

	_send_exit_marker_if_any()

	if _playtest_blocked:
		_clear_queue()
		_update_reason()
		return
	if not enabled:
		_clear_queue()
		print("Ravensight: disabled for this run (enabled = false)")
		_update_reason()
		tracking_disabled.emit("init")
		return
	if _player_opted_out:
		# Nothing leaves the device, not even the settings check, and
		# anything an earlier autoload tracked is dropped.
		_clear_queue()
		if _consent_mode() == CONSENT_OPT_IN:
			print("Ravensight: waiting for the player to opt in (consent = \"opt_in\")")
		else:
			print("Ravensight: tracking disabled by player opt-out")
		_update_reason()
		tracking_disabled.emit("player")
		return
	_activate(true)

func _process(_delta: float) -> void:
	_tick()

## Runs the timers: the retry wait, the batching window and the quit
## deadline. Called every frame.
func _tick() -> void:
	var t := _now()
	if _retry_at >= 0.0 and t >= _retry_at:
		_retry_at = -1.0
		_retry_from_server = false
		_flush_pending()
	if _retry_at < 0.0 and _first_queued_at >= 0.0 and t - _first_queued_at >= flush_interval:
		_flush_pending()
	if _quitting and _quit_deadline >= 0.0 and t >= _quit_deadline:
		_finish_quit()

## Starts tracking once the SDK is ready and active: queues game_started
## (once per run) and runs the kill switch check if it has not run.
## `at_boot` stamps game_started with the launch time; a game enabled later
## in the run stamps it with the time it was enabled.
func _activate(at_boot: bool = false) -> void:
	if not _is_ready or not _is_active():
		return
	_update_reason()
	_queue_game_started(at_boot)
	if not _settings_checked:
		_check_server_settings()
	else:
		_flush_pending()

## Godot quits the moment a close request arrives while auto_accept_quit is
## on, which leaves no time to send anything. Unless the game opted out (see
## handle_quit), the SDK turns that off and quits itself after the final
## flush. The Android back button quits through a separate switch,
## quit_on_go_back, so it is taken over only when the project has it on.
func _take_over_quit() -> void:
	var tree := get_tree()
	if not handle_quit or not tree.auto_accept_quit:
		return
	tree.auto_accept_quit = false
	_owns_close_quit = true
	if bool(ProjectSettings.get_setting("application/config/quit_on_go_back", true)) and tree.quit_on_go_back:
		tree.quit_on_go_back = false
		_owns_go_back_quit = true

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_CLOSE_REQUEST:
			if _owns_close_quit:
				_flush_then_quit(0)
			else:
				_flush_on_close_request()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			if _owns_go_back_quit:
				_flush_then_quit(0)
			else:
				# The back button does not quit this project: just send what
				# is queued, in case the app is about to be backgrounded.
				_flush_pending(true)
		NOTIFICATION_APPLICATION_PAUSED:
			if _is_mobile():
				_on_backgrounded()
			else:
				_flush_pending(true)
		NOTIFICATION_APPLICATION_RESUMED:
			if _is_mobile():
				_on_foregrounded()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			# Focus loss is not an exit: nothing is queued, the queue is sent.
			_flush_pending(true)

## Quits the game after sending game_exited and the queue, holding the quit
## at most QUIT_FLUSH_TIMEOUT_SECONDS. Call it from your own Quit button
## instead of get_tree().quit(); it works whatever handle_quit is.
func quit(exit_code: int = 0) -> void:
	_flush_then_quit(exit_code)

## The game manages the window close itself, e.g. with a "really quit?"
## dialog that may be cancelled: send what is queued. game_exited is left to
## the game's own Ravensight.quit(), so a cancelled close sends no exit.
func _flush_on_close_request() -> void:
	_flush_pending(true)

## Records game_exited, sends the queue and quits when that flush is answered
## or after QUIT_FLUSH_TIMEOUT_SECONDS, whichever comes first. A flush already
## in flight is not interrupted: game_exited is queued behind it and sent by
## the follow-up flush that a successful response starts.
func _flush_then_quit(exit_code: int) -> void:
	if _quitting:
		return
	_quitting = true
	_quit_exit_code = exit_code
	_queue_game_exited()
	if not _is_ready or not _is_active() or pending_events.is_empty():
		_finish_quit()
		return
	_flush_pending(true)
	if not (_flush_in_progress or _session_request_pending):
		# Nothing could go out (no session and none could be opened).
		_finish_quit()
		return
	_quit_deadline = _now() + QUIT_FLUSH_TIMEOUT_SECONDS

func _finish_quit() -> void:
	if _quit_called:
		return
	_quit_called = true
	_quit_tree(_quit_exit_code)

func _quit_tree(exit_code: int) -> void:
	# quit() may be called before this node is in the tree.
	var tree := get_tree() if is_inside_tree() else Engine.get_main_loop() as SceneTree
	if tree:
		tree.quit(exit_code)

## --- Mobile background (Android and iOS) -------------------------------------

func _is_mobile() -> bool:
	return OS.has_feature("android") or OS.has_feature("ios")

## The app went to the background. Mobile may kill it there without another
## notification, so the queue is sent now and a small marker is saved: if
## the app never comes back, the next launch reports game_exited for this
## session from the marker. No event is queued.
func _on_backgrounded() -> void:
	if not _is_ready or not _is_active():
		return
	_backgrounded_at = _unix_now()
	_flush_pending(true)
	if playtest_token.is_empty() and not session_token.is_empty():
		_write_text(BACKGROUND_MARKER_PATH, JSON.stringify({
			"sessionToken": session_token,
			"expiresAt": session_expires_at,
			"backgroundedAt": _backgrounded_at,
		}))

## Back in the foreground. Under session_timeout nothing happens. At or past
## it, the old session ends with game_exited at the moment the app went to
## the background, and a new one starts with game_started now.
func _on_foregrounded() -> void:
	# A resume delivered before _ready() is the launch itself: the marker
	# from an earlier run is _ready()'s to read.
	if not _is_ready:
		return
	_remove_file(BACKGROUND_MARKER_PATH)
	var backgrounded_at := _backgrounded_at
	_backgrounded_at = 0
	if backgrounded_at <= 0 or not _is_active():
		return
	if float(_unix_now() - backgrounded_at) < session_timeout:
		return
	_queue_game_exited(backgrounded_at)
	# Everything queued so far belongs to the old session; once it is
	# delivered the session is dropped and a new one opens.
	_session_boundary = pending_events.size()
	_started_queued = false
	_exit_queued = false
	_queue_game_started(false)
	_flush_pending(true)

## On launch: a marker left by a run that was killed in the background
## reports that run's game_exited, one attempt, then the marker is deleted
## whatever the answer.
func _send_exit_marker_if_any() -> void:
	if not playtest_token.is_empty():
		return
	var text := _read_text(BACKGROUND_MARKER_PATH)
	if text.is_empty():
		return
	_remove_file(BACKGROUND_MARKER_PATH)
	if not enabled or _player_opted_out:
		return
	var marker = JSON.parse_string(text)
	if not (marker is Dictionary):
		return
	var token := str(marker.get("sessionToken", ""))
	var expires_at := int(marker.get("expiresAt", 0))
	var backgrounded_at := int(marker.get("backgroundedAt", 0))
	if token.is_empty() or backgrounded_at <= 0 or _unix_now() >= expires_at:
		return
	var body := JSON.stringify({"events": [{"event": "game_exited", "data": {}, "timestamp": backgrounded_at}]})
	_send("POST", "/track/batch", ["Content-Type: application/json", "X-Session-Token: " + token], body, _ignore_response)

func _ignore_response(_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	pass

## --- Device ID persistence ----------------------------------------------------

func _load_or_create_device_id() -> String:
	# A saved id is kept only when it has the random shape that
	# _generate_device_id() produces. SDKs before the random id saved
	# OS.get_unique_id() + "_" + OS.get_name() + "_" + a timestamp, which is
	# derived from the hardware or OS install; such an id is replaced with a
	# fresh random one (and saved) so an upgraded install carries no hardware
	# identifier either. That install starts a new analytics identity.
	var saved_id := _read_saved_device_id()
	if not saved_id.is_empty():
		return saved_id
	var new_id := _generate_device_id()
	_write_text(DEVICE_ID_PATH, new_id)
	return new_id

## The saved device id when it has the random shape, otherwise "". Never
## writes.
func _read_saved_device_id() -> String:
	var saved_id := _read_text(DEVICE_ID_PATH).strip_edges()
	return saved_id if _is_random_device_id(saved_id) else ""

## Makes sure this install has a device id: called once there is a key and
## the player's choice allows it. Events queued before it get their
## rs_event_id here.
func _load_identity() -> void:
	if not playtest_token.is_empty():
		return
	if device_id.is_empty():
		device_id = _load_or_create_device_id()
	_stamp_event_ids()

## --- Consent ------------------------------------------------------------------

## "opt_in" or "opt_out" from the consent option; anything else is opt_out.
func _consent_mode() -> String:
	return CONSENT_OPT_IN if consent == CONSENT_OPT_IN else CONSENT_OPT_OUT

## The player's saved choice for the consent mode: true when tracking may
## run. opt_out: on unless an opt-out was saved. opt_in: off unless a yes
## was saved.
func _saved_choice() -> bool:
	if _consent_mode() == CONSENT_OPT_IN:
		return FileAccess.file_exists(_path(OPTIN_PATH))
	return not FileAccess.file_exists(_path(OPTOUT_PATH))

## Saves the player's choice in the file the consent mode reads.
func _save_choice(on: bool) -> void:
	if _consent_mode() == CONSENT_OPT_IN:
		if on:
			_write_text(OPTIN_PATH, "1")
		else:
			_remove_file(OPTIN_PATH)
	elif on:
		_remove_file(OPTOUT_PATH)
	else:
		_write_text(OPTOUT_PATH, "1")

## The distribution option when it is valid, otherwise "" (one warning).
func _validated_distribution() -> String:
	var label := distribution.strip_edges()
	if label.is_empty():
		return ""
	var control := RegEx.new()
	control.compile("[\\x00-\\x1f\\x7f]")
	# Counted in UTF-16 units, as the server counts characters.
	if label.to_utf16_buffer().size() / 2 > MAX_DISTRIBUTION_LENGTH or control.search(label) != null:
		_log_once("bad_distribution", "Ravensight: distribution must be at most %d characters with no control characters; it is not sent" % MAX_DISTRIBUTION_LENGTH, true)
		return ""
	return label

## True when `id` has the shape _generate_device_id() produces: exactly 32
## lowercase hex characters, a dash, then the lowercased OS name. A legacy
## hardware derived id never matches, since it joins its parts with
## underscores and keeps the OS name's capitals.
func _is_random_device_id(id: String) -> bool:
	var pattern := RegEx.new()
	pattern.compile("^[0-9a-f]{32}-[a-z0-9]+$")
	return pattern.search(id) != null

## A new device id: 16 random bytes from the platform's secure random source
## as lowercase hex, a dash, and the lowercased OS name (kept because the
## per-OS split in analytics reads it), e.g. "3f1c...9a-windows". It
## identifies this install of this game and nothing else. No id, old or
## new, was ever linked to an account: Ravensight has no player accounts.
func _generate_device_id() -> String:
	var random_bytes := Crypto.new().generate_random_bytes(16)
	return "%s-%s" % [random_bytes.hex_encode(), OS.get_name().to_lower()]

## --- Storage --------------------------------------------------------------------

## Where the SDK's files live. Tests point this somewhere else.
func _storage_dir() -> String:
	return "user://"

func _path(user_path: String) -> String:
	return _storage_dir() + user_path.trim_prefix("user://")

func _read_text(user_path: String) -> String:
	var p := _path(user_path)
	if not FileAccess.file_exists(p):
		return ""
	var file := FileAccess.open(p, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func _write_text(user_path: String, text: String) -> void:
	var file := FileAccess.open(_path(user_path), FileAccess.WRITE)
	if file:
		file.store_string(text)
		file.close()

func _remove_file(user_path: String) -> void:
	var p := _path(user_path)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

## --- Clocks and transport (replaced in tests) -------------------------------------

## Monotonic seconds, for timers.
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

## Unix seconds, for event timestamps and session expiry.
func _unix_now() -> int:
	return int(Time.get_unix_time_from_system())

## 0 <= x < 1, for backoff jitter.
func _random() -> float:
	return randf()

## 4 bytes from the platform's secure random source as 8 hex characters.
func _random_nonce() -> String:
	return Crypto.new().generate_random_bytes(4).hex_encode()

## Every request the SDK makes goes through here. `path` is relative to
## api_base(); `callback` is called with (status, headers, body), where
## status is 0 for a network failure or a timeout.
func _send(method: String, path: String, headers: Array, body: String, callback: Callable) -> void:
	var http := HTTPRequest.new()
	http.timeout = REQUEST_TIMEOUT_SECONDS
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, response_headers: PackedStringArray, response_body: PackedByteArray) -> void:
		http.queue_free()
		var status := code if result == HTTPRequest.RESULT_SUCCESS else 0
		callback.call(status, response_headers, response_body))
	var http_method := HTTPClient.METHOD_POST if method == "POST" else HTTPClient.METHOD_GET
	var err := http.request(api_base() + path, PackedStringArray(headers), http_method, body)
	if err != OK:
		http.queue_free()
		callback.call_deferred(0, PackedStringArray(), PackedByteArray())

## The API root every request goes to: api_url with surrounding whitespace,
## every trailing "/" and a trailing "/api/v1" removed, then "/api/v1"
## appended. Empty means https://api.ravensight.io.
func api_base() -> String:
	var base := api_url.strip_edges()
	while base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	if base.ends_with("/api/v1"):
		base = base.substr(0, base.length() - "/api/v1".length())
		while base.ends_with("/"):
			base = base.substr(0, base.length() - 1)
	if base.is_empty():
		base = "https://api.ravensight.io"
	return base + "/api/v1"

func _key_headers() -> Array:
	var headers := ["X-API-Key: " + ingest_key]
	if not playtest_token.is_empty():
		headers.append("X-Ravensight-Playtest: " + playtest_token)
	return headers

func _session_headers() -> Array:
	var headers := ["Content-Type: application/json", "X-Session-Token: " + session_token]
	if not playtest_token.is_empty():
		headers.append("X-Ravensight-Playtest: " + playtest_token)
	return headers

## --- Playtest mode setup --------------------------------------------------------

## Reads RAVENSIGHT_PLAYTEST_TOKEN/RUN_ID/JOB_ID/PERSONA from the environment
## (set by the Ravensight CLI's playtest runner before it launches the game),
## or the --ravensight-playtest-token= and --ravensight-playtest-run-id=
## user args, and applies them the same way set_playtest_context() would.
## A token without a run id never runs as a real player: the run is stopped.
## A no-op when no token is present, which is every normal player build.
func _apply_playtest_env() -> void:
	var token := OS.get_environment("RAVENSIGHT_PLAYTEST_TOKEN")
	if token.is_empty():
		token = _get_cmdline_arg_value("ravensight-playtest-token")
	if token.is_empty():
		return
	var run_id := OS.get_environment("RAVENSIGHT_PLAYTEST_RUN_ID")
	if run_id.is_empty():
		run_id = _get_cmdline_arg_value("ravensight-playtest-run-id")
	if run_id.is_empty():
		playtest_token = token
		device_id = ""
		_playtest_blocked = true
		_playtest_reason = "session_failed"
		_log_once("playtest_no_run", "Ravensight: playtest token without a run id, nothing will be sent this run", true)
		return

	set_playtest_context({
		"token": token,
		"run_id": run_id,
		"job_id": OS.get_environment("RAVENSIGHT_PLAYTEST_JOB_ID"),
		"persona": OS.get_environment("RAVENSIGHT_PLAYTEST_PERSONA"),
	})

func _get_cmdline_arg_value(arg_name: String) -> String:
	var prefix := "--%s=" % arg_name
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""

## Switches this SDK instance into playtest mode: every request carries the
## playtest header, sessions use the playtest platform, device_id becomes
## "pt-<run_id>" (never read from or written to disk), the player's saved
## opt-out is ignored, and every tracked event is tagged as synthetic.
## Called automatically when the SDK is constructed from the
## RAVENSIGHT_PLAYTEST_* environment (see _apply_playtest_env()); call it
## directly if you wire a driver up some other way.
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
	device_id = "pt-" + run_id
	# A fresh context is a fresh attempt, even if the previous one ended in
	# a fatal rejection.
	_playtest_blocked = false
	_playtest_reason = ""
	# A playtest run ignores the player's opt-out; the flag on disk is left
	# exactly as the player set it.
	_player_opted_out = false

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
		# Dropping bumps the generation, so a response for the old identity
		# still in flight is ignored when it lands.
		_drop_session()
		_start_session()
	elif _is_ready:
		_activate()

## True in a run driven by the Ravensight playtest runner.
func is_playtest() -> bool:
	return not playtest_token.is_empty()

## --- Server kill switch (GET /api/v1/settings) ---------------------------------

func _check_server_settings() -> void:
	if not _is_ready or not _is_active() or _settings_pending:
		return
	_settings_pending = true
	_send("GET", "/settings", _key_headers(), "", _on_settings_response)

func _on_settings_response(code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_settings_pending = false
	_settings_checked = true
	var error := _extract_error(body, "")
	if code == 200:
		var parsed = _parse_json(body)
		if parsed is Dictionary and parsed.has("trackingEnabled") and not bool(parsed["trackingEnabled"]):
			_on_server_tracking_disabled()
			return
	elif code == 403 and error == "tracking_disabled":
		_on_server_tracking_disabled()
		return
	elif code == 403 and _is_fatal_playtest_error(error):
		_on_playtest_refused(error)
		return
	elif code == 401 or code == 403:
		_refuse_key()
		return
	elif code == 429 or (code == 503 and _extract_retry_after(headers) >= 0.0):
		# The kill switch is assumed on; the session waits the server's time.
		_transient_reason = "rate_limited"
		_update_reason()
		_schedule_retry(_extract_retry_after(headers))
		return
	else:
		_log_once("settings_failed", "Ravensight: could not fetch settings (HTTP %d); assuming tracking enabled" % code, false)
	_flush_pending()

## --- Session management (POST /api/v1/session) ---------------------------------

func _is_session_valid() -> bool:
	return session_token.length() > 0 and _unix_now() < session_expires_at

## Opens a session unless one is open or opening, nothing may be sent, or a
## wait is running. `explicit` (flush(), quit, background) cuts a backoff
## wait short and makes one more attempt after a refused key; a server's
## Retry-After wait always holds.
func _start_session(explicit: bool = false) -> void:
	if not _is_ready or not _is_active() or not _settings_checked:
		return
	if _session_request_pending or device_id.is_empty():
		return
	if not _can_send_now(explicit):
		return
	_session_request_pending = true
	_session_request_generation += 1
	var generation := _session_request_generation

	var headers := ["Content-Type: application/json", "X-API-Key: " + ingest_key]
	var platform := OS.get_name()
	if not playtest_token.is_empty():
		headers.append("X-Ravensight-Playtest: " + playtest_token)
		platform = "ravensight-playtest"

	var session_body := {
		"deviceId": device_id,
		"gameVersion": game_version,
		"platform": platform,
	}
	if not _distribution.is_empty():
		session_body["distribution"] = _distribution
	_send("POST", "/session", headers, JSON.stringify(session_body), _on_session_response.bind(generation))

func _on_session_response(code: int, headers: PackedStringArray, body: PackedByteArray, generation: int) -> void:
	# A newer session attempt has started (or the session was dropped) since
	# this request went out. Ignore it rather than let it overwrite state.
	if generation != _session_request_generation:
		return
	_session_request_pending = false
	var error := _extract_error(body, "")

	if code == 201:
		var parsed = _parse_json(body)
		if parsed is Dictionary and parsed.has("token"):
			session_token = str(parsed["token"])
			# The server sends expiresIn (seconds) and expiresAt (an ISO
			# string, which int() would mangle). expiresIn is the contract.
			var expires_in := int(parsed.get("expiresIn", 86400))
			session_expires_at = _unix_now() + expires_in
			_backoff_seconds = DEFAULT_RETRY_SECONDS
			# A success ends any wait an explicit flush cut short.
			_stop_retry()
			_transient_reason = ""
			_update_reason()
			print("Ravensight: session ready")
			session_ready.emit()
			_flush_pending()
		else:
			push_error("Ravensight: malformed session response")
			_transient_reason = "session_failed"
			_update_reason()
			session_failed.emit("malformed_response")
			_schedule_retry()
	elif code == 403 and error == "tracking_disabled":
		session_failed.emit("tracking_disabled")
		_on_server_tracking_disabled()
		return
	elif code == 403 and _is_fatal_playtest_error(error):
		session_failed.emit(error)
		_on_playtest_refused(error)
		return
	elif code == 401 or code == 403:
		session_failed.emit("invalid_key")
		_refuse_key()
	elif code == 429 or (code == 503 and _extract_retry_after(headers) >= 0.0):
		var reason := error if not error.is_empty() else "rate_limited"
		push_warning("Ravensight: session creation rate-limited (%s)" % reason)
		_transient_reason = "rate_limited"
		_update_reason()
		session_failed.emit(reason)
		_schedule_retry(_extract_retry_after(headers))
	else:
		var reason2 := error if not error.is_empty() else ("offline" if code == 0 else "http_%d" % code)
		push_warning("Ravensight: session creation failed (%s)" % reason2)
		_transient_reason = "offline" if code == 0 else "session_failed"
		_update_reason()
		session_failed.emit(reason2)
		_schedule_retry()

	# Quitting and no session came of it: nothing more can be sent.
	if _quitting and code != 201:
		_finish_quit()

## --- Retry / backoff ------------------------------------------------------------

## Waits before the next automatic attempt: `server_wait_seconds` exactly
## when the server gave one (Retry-After), otherwise the backoff, which
## starts at 10 seconds and doubles up to 5 minutes, spread by plus or
## minus JITTER (never past 5 minutes).
func _schedule_retry(server_wait_seconds: float = -1.0) -> void:
	var wait := _backoff_seconds
	if server_wait_seconds >= 0.0:
		wait = server_wait_seconds
		_retry_from_server = true
	else:
		var factor := 1.0 - JITTER + 2.0 * JITTER * _random()
		wait = minf(_backoff_seconds * factor, MAX_BACKOFF_SECONDS)
		_backoff_seconds = minf(_backoff_seconds * 2.0, MAX_BACKOFF_SECONDS)
		_retry_from_server = false
	_retry_at = _now() + wait

func _stop_retry() -> void:
	_retry_at = -1.0
	_retry_from_server = false

func _can_send_now(explicit: bool) -> bool:
	if _retry_at < 0.0:
		return true
	if _retry_from_server:
		return false
	return explicit

## --- Public API: event tracking --------------------------------------------------

## Queue an event. It is sent with others: flush_interval seconds after the
## first waiting event, at once when 50 are waiting, on flush(), when the
## app goes to the background, and on quit. Safe to call from any autoload,
## even before this one is ready: such events wait for the opt-out and kill
## switch checks.
func track_event(event_name: String, data: Dictionary = {}) -> void:
	if not _is_active():
		return
	_enqueue_and_emit(event_name, data)
	if not _is_ready:
		return
	if pending_events.size() >= MAX_BATCH_SIZE:
		_flush_pending()

## Send what is queued now instead of waiting for the timer. Cuts a backoff
## wait short; a server's Retry-After wait still holds.
func flush() -> void:
	_flush_pending(true)

## --- Public API: status ----------------------------------------------------------

## Why the SDK is not sending, or "" when nothing is wrong (a session is open
## or opening normally). One of "no_key" (started with no ingest key),
## "disabled" (enabled is false, the player opted out, or consent =
## "opt_in" and no yes yet), "invalid_key", "tracking_disabled" (the server
## kill switch), "offline", "rate_limited", "session_failed",
## "playtest_job_closed". status_changed fires whenever it changes.
func get_status_reason() -> String:
	return _status_reason

func _update_reason() -> void:
	var reason := _transient_reason
	if _no_key:
		reason = "no_key"
	elif not enabled or _player_opted_out:
		reason = "disabled"
	elif _killed:
		reason = "tracking_disabled"
	elif _playtest_blocked:
		reason = _playtest_reason if not _playtest_reason.is_empty() else "session_failed"
	elif _key_refused:
		reason = "invalid_key"
	if reason != _status_reason:
		_status_reason = reason
		status_changed.emit(reason)

func _is_active() -> bool:
	return enabled and not _player_opted_out and not _killed and not _playtest_blocked and not _no_key and not _key_refused

## True only while the SDK is collecting: it has a key, and nobody switched
## it off (enabled, the player, consent = "opt_in" without a yes, the
## server, or a refused key). Use it to skip work that only feeds
## analytics. The same answer as is_tracking_enabled().
func is_enabled() -> bool:
	return _is_active()

## --- Public API: switching the SDK on and off ------------------------------------

## The game's own switch for this run, never saved (see `enabled`). false
## drops the queue and stops every request; true starts again, running the
## kill switch check and sending game_started if they have not run yet.
func set_enabled(value: bool) -> void:
	if value == enabled:
		return
	enabled = value
	if not _is_ready:
		return
	if not value:
		_clear_queue()
		_stop_retry()
		_update_reason()
		tracking_disabled.emit("init")
	else:
		_update_reason()
		_activate()

## --- Public API: player privacy -------------------------------------------------
##
## Ravensight ships no consent UI. If your game shows its own consent or
## privacy screen, or a settings toggle, wire it to the two calls below.

## Turns tracking off or on for this player and remembers the choice across
## launches (written at once: the flag file at OPTOUT_PATH, or with consent =
## "opt_in" the yes at OPTIN_PATH). Safe to call at any time, even from an
## earlier autoload, while enabled is false or while inert with no key (the
## choice is saved, nothing starts). While off: no session is opened,
## track_event() drops the event, anything already queued is discarded, and
## nothing is sent, not even the settings check on the next boot. Turning
## it on starts again (with "opt_in", this is the first moment a device id
## is made); events tracked right after the yes are queued while the
## settings check runs. Turning it off again keeps the device id; use
## reset_device_id() to forget it. game_started is sent at most once per
## run. After a refused key the choice is saved and nothing restarts this
## run. A no-op in a playtest run.
func set_tracking_enabled(value: bool) -> void:
	if not playtest_token.is_empty():
		print("Ravensight: set_tracking_enabled() ignored in a playtest run")
		return
	_save_choice(value)
	if value != _player_opted_out:
		# Already as asked.
		return
	_player_opted_out = not value

	if _player_opted_out:
		_drop_session()
		_clear_queue()
		_stop_retry()
		print("Ravensight: tracking disabled by player opt-out")
		_update_reason()
		# Before ready, _ready() announces it.
		if _is_ready:
			tracking_disabled.emit("player")
	else:
		if _is_ready and not _no_key and not _key_refused:
			_load_identity()
		_update_reason()
		_activate()

## True when events are being collected: the SDK is enabled, the player has
## not opted out, and the server kill switch is on. The same answer as
## reading tracking_enabled.
func is_tracking_enabled() -> bool:
	return _is_active()

## Forgets this install's analytics identity: generates a fresh random
## device id and saves it, and drops the current session and the queue, so
## the next tracked event opens a new session under the new id. Returns the
## new id. Wire this to a "reset my analytics identity" setting if you offer
## one. Events already on the server stay under the old id, which nothing
## links back to this player. A no-op in a playtest run, whose id is a
## throwaway that is never saved, and while inert with no key. With consent
## = "opt_in" and no yes, it forgets the saved id and makes none, returning
## "".
func reset_device_id() -> String:
	if not playtest_token.is_empty():
		print("Ravensight: reset_device_id() ignored in a playtest run")
		return device_id
	if _no_key:
		return device_id
	if _consent_mode() == CONSENT_OPT_IN and _player_opted_out:
		_remove_file(DEVICE_ID_PATH)
		device_id = ""
		_drop_session()
		_clear_queue()
		return ""
	device_id = _generate_device_id()
	_write_text(DEVICE_ID_PATH, device_id)
	_drop_session()
	_clear_queue()
	return device_id

## Ends the current session without touching the queue. Bumping the request
## generation makes _on_session_response() ignore any session request still
## in flight for the old identity.
func _drop_session() -> void:
	session_token = ""
	session_expires_at = 0
	_session_request_pending = false
	_session_request_generation += 1

## Discards every queued event. Bumping _queue_generation makes the response
## to any batch still in flight a no-op (see _on_batch_response()), and the
## in-flight flag is released so events queued from now on can go out without
## waiting for that stale answer.
func _clear_queue() -> void:
	pending_events.clear()
	_queue_generation += 1
	_flush_in_progress = false
	_split_batch_size = 0
	_session_boundary = 0
	_first_queued_at = -1.0

## The kill switch is off (settings said so, or a 403 tracking_disabled):
## final for the rest of the run. Nothing is queued, sent or retried.
func _on_server_tracking_disabled() -> void:
	_killed = true
	_drop_session()
	_clear_queue()
	_stop_retry()
	_log_once("killed", "Ravensight: tracking disabled by server kill switch", false)
	_update_reason()
	tracking_disabled.emit("server")
	if _quitting:
		_finish_quit()

## The ingest key was refused (revoked, rotated, wrong). Retrying cannot
## help, so the run ends here: the queue is cleared, nothing more is sent
## or retried, and a later set_tracking_enabled(true) restarts nothing.
func _refuse_key() -> void:
	if _key_refused:
		return
	_key_refused = true
	_drop_session()
	_clear_queue()
	_stop_retry()
	_log_once("invalid_key", INVALID_KEY_MESSAGE, true)
	_update_reason()
	tracking_disabled.emit("key")
	if _quitting:
		_finish_quit()

## The playtest token is bad or the job has closed: neither resolves itself.
func _on_playtest_refused(error: String) -> void:
	_playtest_blocked = true
	_playtest_reason = "playtest_job_closed" if error == "playtest_job_closed" else "session_failed"
	_drop_session()
	_clear_queue()
	_stop_retry()
	_log_once("playtest_refused", "Ravensight: playtest run refused (%s), nothing more will be sent" % error, true)
	_update_reason()
	if _quitting:
		_finish_quit()

func _is_fatal_playtest_error(error: String) -> bool:
	return error == "invalid_playtest_token" or error == "playtest_job_closed"

## --- Queue ---------------------------------------------------------------------------

## Queues the event and announces it on event_tracked with the data actually
## queued. An event too large to send is dropped and not announced.
func _enqueue_and_emit(event_name: String, data: Dictionary, timestamp: int = -1, at_front: bool = false) -> void:
	var queued_data = _enqueue(event_name, data, timestamp, at_front)
	if queued_data is Dictionary:
		event_tracked.emit(event_name, queued_data)

## Queues the event and returns the data dictionary actually stored (a copy
## carrying rs_event_id, plus the playtest tags in a playtest run), or null
## when the data is over MAX_EVENT_BYTES as JSON and the event was dropped.
func _enqueue(event_name: String, data: Dictionary, timestamp: int = -1, at_front: bool = false):
	# Never mutate the caller's dictionary.
	var event_data := data.duplicate()
	if not playtest_token.is_empty():
		event_data.merge(_playtest_tags, true)
	if not device_id.is_empty():
		event_data["rs_event_id"] = _next_event_id()
	if _event_bytes(event_data) > MAX_EVENT_BYTES:
		_log_once("event_too_large", "Ravensight: dropped event \"%s\": larger than %d bytes as JSON (further drops are not logged)" % [event_name, MAX_EVENT_BYTES], true)
		flush_failed.emit("event_too_large")
		return null

	while not pending_events.is_empty() and pending_events.size() >= max_queue_size:
		# Drop the oldest, but keep a queued game_started at the front.
		if pending_events.size() > 1 and str(pending_events[0].get("event", "")) == "game_started":
			_remove_queued(1)
		else:
			_remove_queued(0)

	var event := {
		"event": event_name,
		"data": event_data,
		"timestamp": timestamp if timestamp >= 0 else _unix_now(),
	}
	if at_front:
		pending_events.push_front(event)
		if _session_boundary > 0:
			_session_boundary += 1
	else:
		pending_events.append(event)
	if _first_queued_at < 0.0:
		_first_queued_at = _now()
	return event_data

## The serialized size of an event's data, as the server measures it.
func _event_bytes(data: Dictionary) -> int:
	return JSON.stringify(data).to_utf8_buffer().size()

## The next rs_event_id: the first 16 characters of the device id, the
## launch time in hex, a per-launch nonce of 8 hex characters and a
## counter, e.g. "3f1c0a9be2d4c711-6b49d200-9e0c11aa-1". It is kept inside
## the event's data, so a resend after a failure carries the same id and the
## server can recognise it.
func _next_event_id() -> String:
	if _event_nonce.is_empty():
		_event_nonce = _random_nonce()
	_event_counter += 1
	var prefix := device_id.substr(0, 16)
	var unsafe := RegEx.new()
	unsafe.compile("[^A-Za-z0-9_-]")
	prefix = unsafe.sub(prefix, "_", true)
	return "%s-%x-%s-%d" % [prefix, _start_unix, _event_nonce, _event_counter]

## Gives every queued event that has none an rs_event_id. Events tracked
## before this install had a device id (an earlier autoload on the very
## first launch) get theirs here, before anything is sent.
func _stamp_event_ids() -> void:
	if device_id.is_empty():
		return
	for e in pending_events:
		var d = e.get("data")
		if d is Dictionary and not d.has("rs_event_id"):
			d["rs_event_id"] = _next_event_id()

func _remove_queued(index: int) -> void:
	pending_events.remove_at(index)
	if index < _session_boundary:
		_session_boundary -= 1

## Drops the first `count` queued events (they were delivered or refused).
## When that finishes the old session's share (see _session_boundary), the
## session is dropped so the rest opens a new one.
func _drop_front(count: int) -> void:
	pending_events = pending_events.slice(count, pending_events.size())
	if _session_boundary > 0:
		_session_boundary = maxi(0, _session_boundary - count)
		if _session_boundary == 0:
			_drop_session()

## game_started, once per session: first in the queue at boot, carrying the
## time the SDK was constructed.
func _queue_game_started(at_boot: bool) -> void:
	if _started_queued or not _is_active():
		return
	_started_queued = true
	if at_boot:
		_enqueue_and_emit("game_started", {}, _start_unix, true)
	else:
		_enqueue_and_emit("game_started", {})

## game_exited, once.
func _queue_game_exited(timestamp: int = -1) -> void:
	if _exit_queued or not _is_active():
		return
	_exit_queued = true
	_enqueue_and_emit("game_exited", {}, timestamp)

## Sends the next batch, opening a session first when there is none.
func _flush_pending(explicit: bool = false) -> void:
	if not _is_ready or not _is_active():
		return
	if _flush_in_progress or pending_events.is_empty():
		return
	if not _is_session_valid():
		_start_session(explicit)
		return
	if not _can_send_now(explicit):
		return
	_flush_in_progress = true
	_first_queued_at = -1.0
	_stamp_event_ids()

	var batch_size: int = mini(MAX_BATCH_SIZE, pending_events.size())
	if _split_batch_size > 0:
		batch_size = mini(batch_size, _split_batch_size)
	if _session_boundary > 0:
		batch_size = mini(batch_size, _session_boundary)
	var batch: Array = pending_events.slice(0, batch_size)

	_send("POST", "/track/batch", _session_headers(), JSON.stringify({"events": batch}),
		_on_batch_response.bind(batch_size, _queue_generation))

func _on_batch_response(code: int, headers: PackedStringArray, body: PackedByteArray, batch_size: int, generation: int) -> void:
	# The queue this batch was taken from has been discarded since it went
	# out (see _clear_queue()). Its events are gone, so slicing batch_size
	# off the front now would drop events queued afterwards; the flag was
	# already released by the clear.
	if generation != _queue_generation:
		return
	_flush_in_progress = false
	var error := _extract_error(body, "")

	if code == 202 or code == 200:
		_drop_front(batch_size)
		_backoff_seconds = DEFAULT_RETRY_SECONDS
		_stop_retry()
		_split_batch_size = 0
		_reauth_attempts = 0
		_transient_reason = ""
		_update_reason()
		events_flushed.emit(batch_size)
		if not pending_events.is_empty():
			_flush_pending(_quitting)
	elif code == 401:
		# The session expired or was revoked. Queued events stay; a fresh
		# session is opened, at most MAX_REAUTH_ATTEMPTS times in a row,
		# then the backoff takes over.
		session_token = ""
		session_expires_at = 0
		_reauth_attempts += 1
		if _reauth_attempts <= MAX_REAUTH_ATTEMPTS:
			push_warning("Ravensight: session invalid or expired, refreshing")
			_start_session(_quitting)
		else:
			flush_failed.emit(error if not error.is_empty() else "http_401")
			_schedule_retry()
	elif code == 403 and error == "tracking_disabled":
		_on_server_tracking_disabled()
		return
	elif code == 403 and _is_fatal_playtest_error(error):
		_on_playtest_refused(error)
		return
	elif code == 403:
		flush_failed.emit("invalid_key")
		_refuse_key()
	elif code == 429 or (code == 503 and _extract_retry_after(headers) >= 0.0):
		var reason := error if not error.is_empty() else "rate_limited"
		push_warning("Ravensight: track/batch rate-limited (%s)" % reason)
		_transient_reason = "rate_limited"
		_update_reason()
		flush_failed.emit(reason)
		_schedule_retry(_extract_retry_after(headers))
	elif code == 400:
		# The server refuses the whole batch when any event in it violates a
		# ceiling. Halve until the poison event is isolated, then drop it:
		# one bloated event must never cost the rest of its batch, and
		# retrying the identical payload forever would deliver nothing.
		var reason400 := error if not error.is_empty() else "http_400"
		if batch_size <= 1:
			_drop_front(batch_size)
			_log_once("dropped_400", "Ravensight: dropped one event the server refused (%s)" % reason400, false)
			flush_failed.emit(reason400)
		else:
			_split_batch_size = maxi(1, batch_size / 2)
			push_warning("Ravensight: batch rejected (%s), splitting to %d" % [reason400, _split_batch_size])
		_flush_pending(_quitting)
	else:
		var reason2 := error if not error.is_empty() else ("offline" if code == 0 else "http_%d" % code)
		push_warning("Ravensight: batch flush failed (%s), will retry" % reason2)
		if code == 0:
			_transient_reason = "offline"
			_update_reason()
		flush_failed.emit(reason2)
		_schedule_retry()

	# Quitting: this answer is what the quit was waiting for. Keep going only
	# while the queue is still draining (more batches, a split, or a session
	# refresh); a failure is not retried. The quit deadline bounds the wait.
	if _quitting:
		var still_sending := _flush_in_progress or _session_request_pending
		if not still_sending:
			_finish_quit()

## --- Public API: feedback (POST /api/v1/feedback) --------------------------------

## Submit free-form player feedback. `category` is optional and one of
## FEEDBACK_CATEGORIES; `rating` is optional, 0 to omit it or a whole number
## from 1 to 5. Anything else fails at once on feedback_failed
## ("invalid_category" or "invalid_rating") and nothing is sent.
func submit_feedback(message: String, category: String = "", rating: int = 0) -> void:
	if not _is_active():
		feedback_failed.emit("disabled")
		return
	if message.is_empty():
		push_warning("Ravensight: feedback message is empty")
		feedback_failed.emit("empty_message")
		return
	if not category.is_empty() and not FEEDBACK_CATEGORIES.has(category):
		push_warning("Ravensight: feedback category '%s' is not one of bug, suggestion, complaint, praise, playtest, other" % category)
		feedback_failed.emit("invalid_category")
		return
	if rating != 0 and (rating < 1 or rating > 5):
		push_warning("Ravensight: feedback rating must be 1 to 5, or 0 to omit it")
		feedback_failed.emit("invalid_rating")
		return
	if not _is_session_valid():
		push_warning("Ravensight: no valid session yet, cannot submit feedback")
		feedback_failed.emit("no_session")
		_start_session()
		return

	var payload := {"message": message}
	if not category.is_empty():
		payload["category"] = category
	if rating != 0:
		payload["rating"] = rating
	_send("POST", "/feedback", _session_headers(), JSON.stringify(payload), _on_feedback_response)

func _on_feedback_response(code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var error := _extract_error(body, "")
	if code == 201:
		feedback_submitted.emit()
		return
	push_warning("Ravensight: feedback submission failed (HTTP %d)" % code)
	feedback_failed.emit(error if not error.is_empty() else ("offline" if code == 0 else "http_%d" % code))
	if code == 403 and error == "tracking_disabled":
		_on_server_tracking_disabled()
	elif code == 403 and _is_fatal_playtest_error(error):
		_on_playtest_refused(error)
	elif code == 403:
		_refuse_key()
	elif code == 401:
		# The session expired; the next send opens a new one.
		session_token = ""
		session_expires_at = 0

## --- EXPERIMENTAL: agent suggestions (GET /api/v1/agent/suggestions) -------------
##
## This hits an AI-generated suggestions endpoint that is still evolving on
## the server side (empty array until your game has accumulated enough data
## for weekly digests). Shape may change; treat this as experimental and
## don't build critical game logic around it. While tracking is off nothing
## is requested and suggestions_received fires with an empty list.

func fetch_suggestions() -> void:
	if not _is_ready or not _is_active():
		# Deferred, so a caller that awaits the signal after calling still
		# receives it.
		call_deferred("_emit_no_suggestions")
		return
	_send("GET", "/agent/suggestions", _key_headers(), "", _on_suggestions_response)

func _emit_no_suggestions() -> void:
	suggestions_received.emit([])

func _on_suggestions_response(code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if code == 200:
		var parsed = _parse_json(body)
		if parsed is Dictionary and parsed.has("suggestions") and parsed["suggestions"] is Array:
			suggestions_received.emit(parsed["suggestions"])
		else:
			suggestions_received.emit([])
		return
	push_warning("Ravensight: fetch_suggestions failed (HTTP %d)" % code)
	suggestions_received.emit([])
	var error := _extract_error(body, "")
	if code == 403 and error == "tracking_disabled":
		_on_server_tracking_disabled()
	elif code == 403 and _is_fatal_playtest_error(error):
		_on_playtest_refused(error)
	elif code == 401 or code == 403:
		_refuse_key()

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

## Logs a message the first time `key` is seen this run, at warning level
## when `warning` is true, otherwise as a plain print.
func _log_once(key: String, message: String, warning: bool) -> void:
	if _logged_once.has(key):
		return
	_logged_once[key] = true
	if warning:
		push_warning(message)
	else:
		print(message)
