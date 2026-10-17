# Behaviour tests for Ravensight.gd, run headless:
#
#   godot --headless --script tests/run.gd
#
# from the repository root. No network, no project needed: every test uses
# tests/fake_ravensight.gd, which swaps the transport, the clocks, the
# storage folder and the quit for fakes. Exits 0 when every check passes,
# 1 otherwise.
extends SceneTree

const Fake := preload("res://tests/fake_ravensight.gd")

var _failures: Array = []
var _checks: int = 0
var _current: String = ""
var _signals: Array = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	# The tree is live once the first frame starts.
	await process_frame
	var tests := [
		"test_api_base_forms",
		"test_disabled_start_makes_no_requests",
		"test_set_enabled_true_starts_once",
		"test_saved_optout_makes_no_requests_across_new_client",
		"test_optout_before_ready",
		"test_pre_ready_track_with_saved_optout",
		"test_pre_ready_track_waits_for_ready",
		"test_suggestions_and_feedback_while_disabled",
		"test_settings_401_one_request_then_none",
		"test_session_401_invalid_key_keeps_queue",
		"test_session_403_tracking_disabled_stops",
		"test_settings_kill_switch_clears_queue",
		"test_429_retry_after",
		"test_503_retry_after",
		"test_settings_429_waits_retry_after",
		"test_offline_backoff",
		"test_batch_400_split",
		"test_batching_window_and_batch_of_50",
		"test_queue_cap_500_keeps_game_started",
		"test_batch_401_reopens_twice_then_backs_off",
		"test_feedback_validation",
		"test_playtest_header_id_and_no_writes",
		"test_playtest_job_closed_stops",
		"test_playtest_token_without_run_id",
		"test_reset_device_id",
		"test_game_started_once",
		"test_quit_sends_one_game_exited",
		"test_quit_holds_at_most_1_5_seconds",
		"test_quit_after_offline_sends_before_quitting",
		"test_later_enable_stamps_game_started_now",
		"test_close_request_without_handle_quit_once",
		"test_mobile_background_under_timeout",
		"test_mobile_background_past_timeout",
		"test_cold_launch_marker",
		"test_cold_launch_marker_expired_or_opted_out",
		"test_desktop_focus_out_sends_nothing_new",
		"test_no_key_is_inert",
		"test_no_key_optional_is_silent",
		"test_no_key_reads_project_setting_fallback",
		"test_opt_in_before_yes_does_nothing",
		"test_opt_in_after_yes_starts_and_queues",
		"test_opt_in_revoke_keeps_device_id",
		"test_opt_in_saved_yes_starts_next_launch",
		"test_distribution_on_session_body",
		"test_batch_403_ends_run",
		"test_jitter_bounds",
		"test_retry_after_not_jittered",
		"test_rs_event_id_shape_and_resend",
		"test_rs_event_id_stable_prefix_across_launches",
		"test_event_over_8kb_dropped",
		"test_default_key_only_unchanged",
	]
	for name in tests:
		_current = name
		_clean_storage()
		_signals.clear()
		await call(name)
		for child in root.get_children():
			if child is Fake:
				root.remove_child(child)
				child.free()
		_unset_playtest_env()
	_clean_storage()
	if _failures.is_empty():
		print("PASS: %d checks in %d tests" % [_checks, tests.size()])
		quit(0)
	else:
		for f in _failures:
			printerr("FAIL: " + f)
		printerr("%d of %d checks failed" % [_failures.size(), _checks])
		quit(1)

# --- helpers ------------------------------------------------------------------

func check(condition: bool, what: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("%s: %s" % [_current, what])

func eq(actual: Variant, expected: Variant, what: String) -> void:
	_checks += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		_failures.append("%s: %s (expected %s, got %s)" % [_current, what, str(expected), str(actual)])

func _clean_storage() -> void:
	DirAccess.make_dir_recursive_absolute(Fake.TEST_STORAGE_DIR)
	var dir := DirAccess.open(Fake.TEST_STORAGE_DIR)
	for f in dir.get_files():
		dir.remove(f)

func _file(name: String) -> String:
	return Fake.TEST_STORAGE_DIR + name

func _write(name: String, text: String) -> void:
	var f := FileAccess.open(_file(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _read(name: String) -> String:
	if not FileAccess.file_exists(_file(name)):
		return ""
	return FileAccess.get_file_as_string(_file(name))

func _unset_playtest_env() -> void:
	for k in ["RAVENSIGHT_PLAYTEST_TOKEN", "RAVENSIGHT_PLAYTEST_RUN_ID", "RAVENSIGHT_PLAYTEST_JOB_ID", "RAVENSIGHT_PLAYTEST_PERSONA"]:
		OS.unset_environment(k)

## A fake SDK, not yet in the tree. Signals are recorded in _signals.
func make(props: Dictionary = {}) -> Fake:
	var sdk: Fake = Fake.new()
	for k in props:
		sdk.set(k, props[k])
	for sig in ["session_ready", "session_failed", "tracking_disabled", "status_changed", "events_flushed", "flush_failed", "feedback_submitted", "feedback_failed", "suggestions_received"]:
		var s: String = sig
		sdk.connect(s, func(a = null): _signals.append([s, a]))
	return sdk

## A fake SDK added to the tree (its _ready() has run).
func start(props: Dictionary = {}) -> Fake:
	var sdk := make(props)
	root.add_child(sdk)
	return sdk

## Started, settings answered, session open, game_started delivered.
func started_with_session(props: Dictionary = {}) -> Fake:
	var sdk := start(props)
	sdk.answer_all_ok()
	return sdk

func signal_args(name: String) -> Array:
	return _signals.filter(func(s): return s[0] == name).map(func(s): return s[1])

## How many times `name` was sent in a batch.
func sent_count(sdk: Fake, name: String) -> int:
	var n := 0
	for r in sdk.requests:
		if r["path"] == "/track/batch":
			n += sdk.event_names(r).count(name)
	return n

func queued_names(sdk: Fake) -> Array:
	return sdk.pending_events.map(func(e): return e["event"])

# --- tests ------------------------------------------------------------------------

func test_api_base_forms() -> void:
	var sdk := make()
	var forms := {
		"https://api.ravensight.io": "https://api.ravensight.io/api/v1",
		"https://api.ravensight.io/": "https://api.ravensight.io/api/v1",
		"https://api.ravensight.io///": "https://api.ravensight.io/api/v1",
		"https://api.ravensight.io/api/v1": "https://api.ravensight.io/api/v1",
		"https://api.ravensight.io/api/v1/": "https://api.ravensight.io/api/v1",
		"  https://self.example.com/api/v1  ": "https://self.example.com/api/v1",
		"http://localhost:3000": "http://localhost:3000/api/v1",
		"": "https://api.ravensight.io/api/v1",
		"   ": "https://api.ravensight.io/api/v1",
	}
	for f in forms:
		sdk.api_url = f
		eq(sdk.api_base(), forms[f], "api_base for '%s'" % f)
	var fresh := make()
	eq(fresh.api_url, "https://api.ravensight.io", "default api_url is the bare host")
	eq(Fake.REQUEST_TIMEOUT_SECONDS, 15.0, "request timeout")
	eq(fresh.max_queue_size, 500, "default queue cap")
	eq(Fake.VERSION, "0.3.0", "version constant")
	var plain: Node = load("res://Ravensight.gd").new()
	eq(plain.ingest_key, "", "default ingest_key is empty")
	eq(plain.consent, "opt_out", "default consent")
	eq(plain.distribution, "", "default distribution")
	plain.free()
	sdk.free()
	fresh.free()

func test_disabled_start_makes_no_requests() -> void:
	var sdk := start({"enabled": false})
	sdk.track_event("level_start", {"level": "1"})
	sdk.flush()
	sdk.fetch_suggestions()
	sdk.submit_feedback("hi", "bug", 3)
	sdk.advance(3600.0)
	sdk.quit()
	eq(sdk.requests.size(), 0, "no request of any kind")
	eq(sdk.pending_events.size(), 0, "nothing queued")
	check(signal_args("tracking_disabled").has("init"), "tracking_disabled(init) emitted")
	eq(sdk.get_status_reason(), "disabled", "reason")
	eq(sdk.quit_codes, [0], "quit still quits")

func test_set_enabled_true_starts_once() -> void:
	var sdk := start({"enabled": false})
	sdk.set_enabled(true)
	eq(sdk.paths(), ["/settings"], "settings check runs on enable")
	eq(queued_names(sdk), ["game_started"], "game_started queued on enable")
	sdk.answer_all_ok()
	sdk.set_enabled(false)
	eq(sdk.get_status_reason(), "disabled", "reason after set_enabled(false)")
	sdk.set_enabled(true)
	sdk.answer_all_ok()
	var started := sent_count(sdk, "game_started")
	eq(started, 1, "one game_started across enable, disable, enable")
	eq(sdk.paths().count("/settings"), 1, "settings checked once")

func test_saved_optout_makes_no_requests_across_new_client() -> void:
	var a := started_with_session()
	a.set_tracking_enabled(false)
	var before := a.requests.size()
	a.track_event("x")
	a.flush()
	a.advance(600.0)
	eq(a.requests.size(), before, "nothing sent after opting out")
	check(FileAccess.file_exists(_file("ravensight_optout.save")), "opt-out saved")
	root.remove_child(a)
	a.free()

	var b := start()
	b.track_event("level_start")
	b.flush()
	b.fetch_suggestions()
	b.submit_feedback("hello")
	b.advance(600.0)
	eq(b.requests.size(), 0, "a new client with the saved opt-out sends nothing")
	eq(b.pending_events.size(), 0, "and queues nothing")
	eq(b.get_status_reason(), "disabled", "reason")
	check(not b.is_tracking_enabled(), "is_tracking_enabled false")

func test_optout_before_ready() -> void:
	var sdk := make()
	sdk.set_tracking_enabled(false)
	check(FileAccess.file_exists(_file("ravensight_optout.save")), "written before ready")
	sdk.track_event("early")
	root.add_child(sdk)
	sdk.advance(60.0)
	eq(sdk.requests.size(), 0, "no requests")
	eq(sdk.pending_events.size(), 0, "nothing queued")
	eq(signal_args("tracking_disabled"), ["player"], "tracking_disabled(player) once, from _ready")

	# Written even when the client was constructed disabled.
	_clean_storage()
	var off := start({"enabled": false})
	off.set_tracking_enabled(false)
	check(FileAccess.file_exists(_file("ravensight_optout.save")), "written while enabled is false")
	off.set_tracking_enabled(true)
	check(not FileAccess.file_exists(_file("ravensight_optout.save")), "removed on opt-in")
	eq(off.requests.size(), 0, "opt-in does not override enabled = false")

func test_pre_ready_track_with_saved_optout() -> void:
	_write("ravensight_optout.save", "1")
	var sdk := make()
	sdk.track_event("from_an_earlier_autoload")
	eq(sdk.pending_events.size(), 0, "dropped before ready")
	root.add_child(sdk)
	sdk.set_tracking_enabled(true)
	sdk.answer_all_ok()
	for r in sdk.requests:
		if r["path"] == "/track/batch":
			check(not sdk.event_names(r).has("from_an_earlier_autoload"), "the opted-out event is never sent")

func test_pre_ready_track_waits_for_ready() -> void:
	var sdk := make()
	sdk.track_event("early", {"a": 1})
	eq(sdk.requests.size(), 0, "no request before ready")
	eq(queued_names(sdk), ["early"], "held in the queue")
	root.add_child(sdk)
	eq(queued_names(sdk), ["game_started", "early"], "game_started first")
	check(int(sdk.pending_events[0]["timestamp"]) <= int(sdk.pending_events[1]["timestamp"]), "game_started carries the start time")
	eq(sdk.paths(), ["/settings"], "only the settings check before its answer")
	sdk.answer_all_ok()
	eq(sdk.paths(), ["/settings", "/session", "/track/batch"], "then session and one batch")
	eq(sdk.event_names(sdk.requests[2]), ["game_started", "early"], "batch contents")

func test_suggestions_and_feedback_while_disabled() -> void:
	var sdk := start({"enabled": false})
	sdk.fetch_suggestions()
	sdk.submit_feedback("too hard", "complaint", 2)
	eq(signal_args("feedback_failed"), ["disabled"], "feedback refused locally with disabled")
	await process_frame
	eq(signal_args("suggestions_received"), [[]], "suggestions_received([]) still fires")
	eq(sdk.requests.size(), 0, "no request")

	# The kill switch counts as off too.
	_signals.clear()
	var killed := start()
	killed.answer(200, {"trackingEnabled": false})
	killed.fetch_suggestions()
	killed.submit_feedback("x")
	await process_frame
	eq(killed.requests.size(), 1, "only the settings check")
	eq(signal_args("feedback_failed"), ["disabled"], "feedback refused while killed")
	eq(signal_args("suggestions_received"), [[]], "empty suggestions while killed")

func test_settings_401_one_request_then_none() -> void:
	var sdk := start()
	sdk.track_event("before_answer")
	sdk.answer(401, {"error": "invalid_api_key"})
	eq(sdk.pending_events.size(), 0, "the queue is cleared")
	for i in 60:
		sdk.track_event("e%d" % i)
	sdk.advance(30.0)
	sdk.advance(600.0)
	eq(sdk.requests.size(), 1, "one request, then none")
	eq(sdk.get_status_reason(), "invalid_key", "reason")
	eq(sdk.pending_events.size(), 0, "events after the refusal are dropped")
	check(signal_args("tracking_disabled").has("key"), "tracking_disabled(key)")
	eq(sdk.is_enabled(), false, "is_enabled() false")
	sdk.flush()
	sdk.submit_feedback("hi")
	sdk.set_tracking_enabled(true)
	sdk.advance(600.0)
	eq(sdk.requests.size(), 1, "flush, feedback and a yes make no request: the run has ended")
	sdk.quit()
	eq(sdk.quit_codes, [0], "quit still quits")

func test_session_401_invalid_key_keeps_queue() -> void:
	# Kept name: a refused key on POST /session now ends the run.
	var sdk := start()
	sdk.answer(200, {"trackingEnabled": true})
	sdk.answer(403, {"error": "forbidden"})
	eq(sdk.get_status_reason(), "invalid_key", "a 403 that is not a known code is invalid_key")
	check(signal_args("session_failed").has("invalid_key"), "session_failed(invalid_key)")
	check(signal_args("tracking_disabled").has("key"), "tracking_disabled(key)")
	eq(sdk.pending_events.size(), 0, "queue cleared")
	sdk.advance(600.0)
	sdk.track_event("later")
	sdk.flush()
	sdk.advance(600.0)
	eq(sdk.requests.size(), 2, "no retry, no further request")
	var again := start()
	again.answer(200, {"trackingEnabled": true})
	again.answer(401, {"error": "invalid_api_key"})
	eq(again.get_status_reason(), "invalid_key", "a session 401 ends the run too")
	eq(again.pending_events.size(), 0, "and clears the queue")

func test_session_403_tracking_disabled_stops() -> void:
	var sdk := start()
	sdk.answer(200, {"trackingEnabled": true})
	sdk.answer(403, {"error": "tracking_disabled"})
	sdk.track_event("after")
	sdk.flush()
	sdk.advance(600.0)
	eq(sdk.requests.size(), 2, "nothing after the 403")
	eq(sdk.pending_events.size(), 0, "queue cleared")
	eq(sdk.get_status_reason(), "tracking_disabled", "reason")
	check(signal_args("tracking_disabled").has("server"), "tracking_disabled(server)")
	sdk.set_tracking_enabled(false)
	sdk.set_tracking_enabled(true)
	sdk.advance(600.0)
	eq(sdk.requests.size(), 2, "the kill switch holds for the run")

func test_settings_kill_switch_clears_queue() -> void:
	var sdk := make()
	sdk.track_event("early")
	root.add_child(sdk)
	sdk.answer(200, {"trackingEnabled": false})
	eq(sdk.pending_events.size(), 0, "game_started and early events dropped")
	sdk.advance(600.0)
	eq(sdk.requests.size(), 1, "no session")

func test_429_retry_after() -> void:
	var sdk := start()
	sdk.answer(200, {"trackingEnabled": true})
	sdk.answer(429, {"error": "rate_limited"}, ["Retry-After: 7"])
	eq(sdk.get_status_reason(), "rate_limited", "reason")
	sdk.advance(6.0)
	sdk.flush()
	eq(sdk.requests.size(), 2, "nothing before Retry-After, not even on flush()")
	sdk.advance(1.0)
	eq(sdk.paths(), ["/settings", "/session", "/session"], "retried at exactly Retry-After")
	sdk.answer_all_ok()
	eq(sdk.get_status_reason(), "", "reason clears")

func test_503_retry_after() -> void:
	var sdk := started_with_session()
	sdk.track_event("x")
	sdk.flush()
	sdk.answer(503, {"error": "storage_unavailable"}, ["Retry-After: 60"])
	sdk.advance(59.0)
	eq(sdk.unanswered().size(), 0, "waits the 503's Retry-After")
	sdk.advance(1.0)
	eq(sdk.unanswered().size(), 1, "then retries")

func test_offline_backoff() -> void:
	var sdk := start()
	sdk.answer(200, {"trackingEnabled": true})
	sdk.answer(0, "")
	eq(sdk.get_status_reason(), "offline", "status 0 is offline")
	sdk.advance(9.0)
	eq(sdk.unanswered().size(), 0, "first wait 10 s")
	sdk.advance(1.0)
	eq(sdk.unanswered().size(), 1, "retried at 10 s")
	sdk.answer(500, {"error": "internal_error"})
	eq(sdk.get_status_reason(), "session_failed", "a 5xx is session_failed")
	sdk.advance(19.0)
	eq(sdk.unanswered().size(), 0, "second wait 20 s")
	sdk.advance(1.0)
	eq(sdk.unanswered().size(), 1, "retried at 20 s")
	for i in 10:
		sdk.answer(0, "")
		sdk.advance(300.0)
	eq(sdk.unanswered().size(), 1, "capped at 300 s and still retrying")
	sdk.answer_all_ok()
	eq(sdk.pending_events.size(), 0, "events kept and delivered")

func test_batch_400_split() -> void:
	var sdk := started_with_session()
	for i in 4:
		sdk.track_event("e%d" % i)
	sdk.flush()
	var sizes := []
	# e2 is the poison event: every batch containing it gets a 400.
	for i in 20:
		var open := sdk.unanswered()
		if open.is_empty():
			break
		var names: Array = sdk.event_names(open[0])
		sizes.append(names.size())
		if names.has("e2"):
			sdk.answer(400, {"error": "event_too_large"})
		else:
			sdk.answer(202, {})
	eq(sizes, [4, 2, 2, 1, 1], "halved until the bad event is alone, then the rest")
	eq(sdk.pending_events.size(), 0, "queue drained")
	check(signal_args("flush_failed").has("event_too_large"), "the drop is reported on flush_failed")
	eq(signal_args("events_flushed"), [1, 2, 1], "game_started, then the other three are delivered")

func test_batching_window_and_batch_of_50() -> void:
	var sdk := started_with_session()
	var base := sdk.requests.size()
	sdk.track_event("one")
	sdk.advance(4.0)
	eq(sdk.requests.size(), base, "track_event does not send at once")
	sdk.advance(1.0)
	eq(sdk.requests.size(), base + 1, "sent flush_interval after the first waiting event")
	sdk.answer(202, {})
	for i in 49:
		sdk.track_event("e%d" % i)
	eq(sdk.requests.size(), base + 1, "49 waiting: no request")
	sdk.track_event("e49")
	eq(sdk.requests.size(), base + 2, "50 waiting: sent at once")
	eq(sdk.events_in(sdk.requests[base + 1]).size(), 50, "a batch of 50")
	sdk.answer(202, {})
	for i in 120:
		sdk.track_event("f%d" % i)
	sdk.answer_all_ok()
	for r in sdk.requests:
		if r["path"] == "/track/batch":
			check(sdk.events_in(r).size() <= 50, "no batch over 50")
	eq(sdk.pending_events.size(), 0, "everything delivered")

func test_queue_cap_500_keeps_game_started() -> void:
	var sdk := start()
	# The settings check is never answered, so nothing is sent.
	for i in 600:
		sdk.track_event("e%d" % i)
	eq(sdk.pending_events.size(), 500, "capped at 500")
	eq(sdk.pending_events[0]["event"], "game_started", "game_started kept")
	eq(sdk.pending_events[1]["event"], "e101", "oldest after it dropped")
	eq(sdk.pending_events[499]["event"], "e599", "newest kept")

func test_batch_401_reopens_twice_then_backs_off() -> void:
	var sdk := started_with_session()
	sdk.track_event("x")
	sdk.flush()
	sdk.answer(401, {"error": "invalid_session"})
	sdk.answer(201, {"token": "t2", "expiresIn": 86400})
	sdk.answer(401, {"error": "invalid_session"})
	sdk.answer(201, {"token": "t3", "expiresIn": 86400})
	sdk.answer(401, {"error": "invalid_session"})
	var tail: Array = sdk.paths().slice(3)
	eq(tail, ["/track/batch", "/session", "/track/batch", "/session", "/track/batch"], "two reopens, then stop")
	eq(sdk.unanswered().size(), 0, "no third reopen at once")
	sdk.advance(10.0)
	eq(sdk.unanswered().size(), 1, "the backoff takes over")
	eq(queued_names(sdk), ["x"], "the event is kept")

func test_feedback_validation() -> void:
	var sdk := started_with_session()
	var base := sdk.requests.size()
	sdk.submit_feedback("msg", "rant", 3)
	sdk.submit_feedback("msg", "bug", 6)
	sdk.submit_feedback("msg", "bug", -1)
	sdk.submit_feedback("", "bug", 3)
	eq(signal_args("feedback_failed"), ["invalid_category", "invalid_rating", "invalid_rating", "empty_message"], "local failures")
	eq(sdk.requests.size(), base, "no request for a local failure")
	eq(Fake.FEEDBACK_CATEGORIES.size(), 6, "six categories")
	sdk.submit_feedback("the boss is unfair", "complaint", 0)
	sdk.submit_feedback("love it", "praise", 5)
	sdk.submit_feedback("plain")
	eq(sdk.requests.size(), base + 3, "valid feedback is sent")
	eq(JSON.parse_string(sdk.requests[base]["body"]), {"message": "the boss is unfair", "category": "complaint"}, "rating 0 omitted")
	eq(JSON.parse_string(sdk.requests[base + 1]["body"]), {"message": "love it", "category": "praise", "rating": 5.0}, "rating sent")
	eq(JSON.parse_string(sdk.requests[base + 2]["body"]), {"message": "plain"}, "category omitted when empty")

func test_playtest_header_id_and_no_writes() -> void:
	OS.set_environment("RAVENSIGHT_PLAYTEST_TOKEN", "pt_tok")
	OS.set_environment("RAVENSIGHT_PLAYTEST_RUN_ID", "run42")
	_write("ravensight_optout.save", "1")
	var sdk := started_with_session()
	check(sdk.is_playtest(), "is_playtest")
	eq(sdk.device_id, "pt-run42", "pt- device id")
	check(not FileAccess.file_exists(_file("device_id.save")), "no device id written")
	check(sdk.is_tracking_enabled(), "the saved opt-out is ignored")
	check(sdk.requests.size() >= 3, "settings, session and batch sent")
	for r in sdk.requests:
		eq(sdk.header(r, "X-Ravensight-Playtest"), "pt_tok", "header on " + r["path"])
	var session_body = JSON.parse_string(sdk.requests[1]["body"])
	eq(session_body["deviceId"], "pt-run42", "session device id")
	eq(session_body["platform"], "ravensight-playtest", "session platform")
	var started = sdk.events_in(sdk.requests[2])[0]
	eq(started["data"].get("synthetic"), true, "events tagged synthetic")
	sdk.set_tracking_enabled(false)
	check(sdk.is_tracking_enabled(), "set_tracking_enabled is a no-op in a playtest run")
	eq(_read("ravensight_optout.save"), "1", "the player's flag is left as it was")
	_clean_storage()
	sdk.set_tracking_enabled(false)
	check(not FileAccess.file_exists(_file("ravensight_optout.save")), "nothing written by set_tracking_enabled")
	eq(sdk.reset_device_id(), "pt-run42", "reset_device_id is a no-op")
	check(not FileAccess.file_exists(_file("device_id.save")), "still nothing written")

func test_playtest_job_closed_stops() -> void:
	OS.set_environment("RAVENSIGHT_PLAYTEST_TOKEN", "pt_tok")
	OS.set_environment("RAVENSIGHT_PLAYTEST_RUN_ID", "run42")
	var sdk := started_with_session()
	sdk.track_event("a")
	sdk.flush()
	sdk.answer(403, {"error": "playtest_job_closed"})
	eq(sdk.get_status_reason(), "playtest_job_closed", "reason")
	eq(sdk.pending_events.size(), 0, "queue cleared")
	var n := sdk.requests.size()
	sdk.track_event("b")
	sdk.flush()
	sdk.fetch_suggestions()
	sdk.advance(600.0)
	eq(sdk.requests.size(), n, "nothing more is sent")

	_signals.clear()
	var other := start()
	other.answer(200, {"trackingEnabled": true})
	other.answer(403, {"error": "invalid_playtest_token"})
	eq(other.get_status_reason(), "session_failed", "an invalid playtest token is session_failed")
	other.advance(600.0)
	eq(other.requests.size(), 2, "and stops")

func test_playtest_token_without_run_id() -> void:
	OS.set_environment("RAVENSIGHT_PLAYTEST_TOKEN", "pt_tok")
	var sdk := start()
	sdk.track_event("x")
	sdk.flush()
	sdk.advance(600.0)
	eq(sdk.requests.size(), 0, "never runs as a real player")
	eq(sdk.get_status_reason(), "session_failed", "reason")
	check(not FileAccess.file_exists(_file("device_id.save")), "no device id written")

func test_reset_device_id() -> void:
	var sdk := started_with_session()
	var old := sdk.device_id
	check(old.length() > 33 and old.substr(32, 1) == "-", "32 hex, dash, OS name")
	eq(_read("device_id.save"), old, "saved")
	sdk.track_event("x")
	var fresh := sdk.reset_device_id()
	check(fresh != old, "a new id")
	eq(sdk.device_id, fresh, "in use")
	eq(_read("device_id.save"), fresh, "and saved")
	eq(sdk.pending_events.size(), 0, "queue cleared")
	eq(sdk.session_token, "", "session invalidated")
	sdk.track_event("y")
	sdk.flush()
	sdk.answer_all_ok()
	var session_body = JSON.parse_string(sdk.requests[sdk.requests.size() - 2]["body"])
	eq(session_body["deviceId"], fresh, "the next session uses the new id")

	# An existing saved id is kept as it is.
	root.remove_child(sdk)
	sdk.free()
	var again := start()
	eq(again.device_id, fresh, "the saved id is read back unchanged")

func test_game_started_once() -> void:
	var sdk := started_with_session()
	sdk.set_tracking_enabled(false)
	sdk.set_tracking_enabled(true)
	sdk.set_enabled(false)
	sdk.set_enabled(true)
	sdk.track_event("x")
	sdk.flush()
	sdk.answer_all_ok()
	var started := sent_count(sdk, "game_started")
	eq(started, 1, "one game_started per run")
	eq(sdk.paths().count("/settings"), 1, "one settings check")

func test_quit_sends_one_game_exited() -> void:
	var sdk := started_with_session()
	sdk.track_event("last")
	sdk.quit(3)
	sdk.quit(3)
	sdk.answer_all_ok()
	var exits := sent_count(sdk, "game_exited")
	eq(exits, 1, "one game_exited")
	eq(sdk.event_names(sdk.requests[sdk.requests.size() - 1]), ["last", "game_exited"], "sent with the last events")
	eq(sdk.quit_codes, [3], "quit once, with the exit code, when the flush is answered")

func test_quit_holds_at_most_1_5_seconds() -> void:
	var sdk := started_with_session()
	sdk.quit()
	eq(sdk.unanswered().size(), 1, "the final batch is in flight")
	sdk.advance(1.4)
	eq(sdk.quit_codes, [], "still waiting at 1.4 s")
	sdk.advance(0.1)
	eq(sdk.quit_codes, [0], "quit at 1.5 s without an answer")

	# Nothing could be sent: quit at once.
	var off := start({"enabled": false})
	off.quit()
	eq(off.quit_codes, [0], "disabled: quit at once")

func test_close_request_without_handle_quit_once() -> void:
	var sdk := started_with_session({"handle_quit": false})
	sdk.track_event("before_close")
	sdk.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	eq(sdk.event_names(sdk.unanswered()[0]), ["before_close"], "a close request only flushes")
	sdk.answer_all_ok()
	sdk.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	eq(sent_count(sdk, "game_exited"), 0, "a cancelled close sends no game_exited")
	eq(sdk.quit_codes, [], "and does not quit")
	sdk.quit()
	sdk.answer_all_ok()
	eq(sent_count(sdk, "game_exited"), 1, "quit() sends the one game_exited")
	eq(sdk.quit_codes, [0], "quit() quits")

func test_mobile_background_under_timeout() -> void:
	var sdk := started_with_session({"mobile": true})
	sdk.track_event("before")
	sdk.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	eq(sdk.unanswered().size(), 1, "flushed on background")
	eq(sdk.event_names(sdk.unanswered()[0]), ["before"], "no event queued on background")
	var marker = JSON.parse_string(_read("ravensight_bg.save"))
	check(marker is Dictionary, "marker saved")
	if marker is Dictionary:
		eq(marker["sessionToken"], sdk.session_token, "marker token")
		eq(int(marker["backgroundedAt"]), sdk.fake_unix, "marker time")
		eq(int(marker["expiresAt"]), sdk.session_expires_at, "marker expiry")
	sdk.answer_all_ok()
	sdk.fake_unix += 1799
	sdk.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	check(not FileAccess.file_exists(_file("ravensight_bg.save")), "marker deleted on return")
	eq(sdk.pending_events.size(), 0, "under 30 minutes nothing is queued")
	eq(sdk.unanswered().size(), 0, "and nothing sent")

func test_mobile_background_past_timeout() -> void:
	var sdk := started_with_session({"mobile": true})
	var old_token := sdk.session_token
	sdk.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var backgrounded_at := sdk.fake_unix
	sdk.fake_unix += 1800
	sdk.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	var exit_req: Dictionary = sdk.unanswered()[0]
	eq(sdk.event_names(exit_req), ["game_exited"], "game_exited sent first, alone")
	eq(int(sdk.events_in(exit_req)[0]["timestamp"]), backgrounded_at, "at the moment it went to the background")
	eq(sdk.header(exit_req, "X-Session-Token"), old_token, "under the old session")
	sdk.answer(202, {})
	eq(sdk.unanswered()[0]["path"], "/session", "then a new session opens")
	sdk.answer(201, {"token": "fresh", "expiresIn": 86400})
	var start_req: Dictionary = sdk.unanswered()[0]
	eq(sdk.event_names(start_req), ["game_started"], "game_started in the new session")
	eq(sdk.header(start_req, "X-Session-Token"), "fresh", "under the new token")
	eq(int(sdk.events_in(start_req)[0]["timestamp"]), sdk.fake_unix, "at the return time")
	sdk.answer(202, {})
	sdk.quit()
	sdk.answer_all_ok()
	var exits := sent_count(sdk, "game_exited")
	eq(exits, 2, "the new session gets its own game_exited on quit")

func test_cold_launch_marker() -> void:
	_write("ravensight_bg.save", JSON.stringify({"sessionToken": "old_tok", "expiresAt": 1800000000 + 3600, "backgroundedAt": 1800000000 - 50}))
	var sdk := start()
	var first: Dictionary = sdk.requests[0]
	eq(first["path"], "/track/batch", "the first request is the old session's exit")
	eq(sdk.header(first, "X-Session-Token"), "old_tok", "with the marker's token")
	eq(sdk.events_in(first), [{"event": "game_exited", "data": {}, "timestamp": 1800000000.0 - 50}], "one game_exited at backgroundedAt")
	eq(sdk.requests[1]["path"], "/settings", "then the ordinary start")
	check(not FileAccess.file_exists(_file("ravensight_bg.save")), "marker deleted")
	sdk.answer(500, {"error": "internal_error"})
	sdk.advance(600.0)
	var marker_sends := 0
	for r in sdk.requests:
		if sdk.header(r, "X-Session-Token") == "old_tok":
			marker_sends += 1
	eq(marker_sends, 1, "one attempt, no retry")

func test_cold_launch_marker_expired_or_opted_out() -> void:
	_write("ravensight_bg.save", JSON.stringify({"sessionToken": "old_tok", "expiresAt": 1800000000 - 1, "backgroundedAt": 1800000000 - 50}))
	var expired := start()
	eq(expired.paths(), ["/settings"], "an expired marker sends nothing")
	check(not FileAccess.file_exists(_file("ravensight_bg.save")), "and is deleted")
	root.remove_child(expired)
	expired.free()

	_write("ravensight_bg.save", JSON.stringify({"sessionToken": "old_tok", "expiresAt": 1800000000 + 3600, "backgroundedAt": 1800000000 - 50}))
	_write("ravensight_optout.save", "1")
	var opted := start()
	eq(opted.requests.size(), 0, "an opted-out player sends nothing")
	check(not FileAccess.file_exists(_file("ravensight_bg.save")), "and the marker is deleted")

func test_desktop_focus_out_sends_nothing_new() -> void:
	var sdk := started_with_session()
	var base := sdk.requests.size()
	sdk.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	sdk.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	sdk.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	eq(sdk.requests.size(), base, "focus loss queues and sends nothing when nothing waits")
	eq(sdk.pending_events.size(), 0, "no event queued")
	check(not FileAccess.file_exists(_file("ravensight_bg.save")), "no marker on desktop")
	sdk.track_event("x")
	sdk.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	eq(sdk.requests.size(), base + 1, "what waits is flushed")
	eq(sdk.event_names(sdk.requests[base]), ["x"], "and only that")

func test_settings_429_waits_retry_after() -> void:
	var sdk := start()
	sdk.answer(429, {"error": "rate_limited"}, ["Retry-After: 30"])
	eq(sdk.get_status_reason(), "rate_limited", "reason")
	sdk.advance(29.0)
	eq(sdk.requests.size(), 1, "nothing before Retry-After")
	sdk.advance(1.0)
	eq(sdk.paths(), ["/settings", "/session"], "then the session, with the kill switch assumed on")

func test_quit_after_offline_sends_before_quitting() -> void:
	var sdk := start()
	sdk.answer(200, {"trackingEnabled": true})
	sdk.answer(0, "")
	sdk.track_event("last")
	sdk.advance(3.0)
	sdk.quit()
	eq(sdk.unanswered().size(), 1, "quit cuts the backoff short and opens a session")
	sdk.answer(201, {"token": "t", "expiresIn": 86400})
	eq(sdk.unanswered().size(), 1, "the batch goes out once the session opens")
	if sdk.unanswered().size() == 1:
		eq(sdk.event_names(sdk.unanswered()[0]), ["game_started", "last", "game_exited"], "everything queued")
	eq(sdk.quit_codes, [], "not quit yet")
	sdk.answer(202, {})
	eq(sdk.quit_codes, [0], "quit once the batch is answered")
	eq(sdk.pending_events.size(), 0, "nothing left behind")

func test_later_enable_stamps_game_started_now() -> void:
	var sdk := start({"enabled": false})
	sdk.fake_unix += 120
	sdk.set_enabled(true)
	eq(int(sdk.pending_events[0]["timestamp"]), sdk.fake_unix, "game_started carries the time it was enabled")

	_write("ravensight_optout.save", "1")
	var opted := start()
	opted.fake_unix += 300
	opted.set_tracking_enabled(true)
	eq(int(opted.pending_events[0]["timestamp"]), opted.fake_unix, "and the time the player opted in")

	var quitter := make()
	quitter.quit()
	eq(quitter.quit_codes, [0], "quit() before the node is in the tree does not crash")
	quitter.free()

# --- public builds (0.3.0) -----------------------------------------------------------

func _storage_files() -> Array:
	var dir := DirAccess.open(Fake.TEST_STORAGE_DIR)
	return Array(dir.get_files()) if dir else []

## The events of every batch sent so far, in order.
func _sent_events(sdk: Fake) -> Array:
	var out: Array = []
	for r in sdk.requests:
		if r["path"] == "/track/batch":
			out.append_array(sdk.events_in(r))
	return out

func test_no_key_is_inert() -> void:
	var sdk := make({"ingest_key": ""})
	sdk.track_event("from_an_earlier_autoload")
	root.add_child(sdk)
	sdk.track_event("level_start", {"level": "1"})
	sdk.flush()
	sdk.submit_feedback("hi", "bug", 3)
	sdk.fetch_suggestions()
	sdk.set_enabled(false)
	sdk.set_enabled(true)
	sdk.reset_device_id()
	sdk.advance(3600.0)
	eq(sdk.requests.size(), 0, "no request of any kind")
	eq(sdk.pending_events.size(), 0, "nothing queued")
	eq(_storage_files(), [], "no file written")
	eq(sdk.device_id, "", "no device id made")
	eq(sdk.is_enabled(), false, "is_enabled() false")
	eq(sdk.is_tracking_enabled(), false, "is_tracking_enabled() false")
	eq(sdk.get_status_reason(), "no_key", "reason no_key")
	check(sdk._logged_once.has("no_key"), "one warning")
	eq(sdk.is_processing(), false, "no per-frame timer")
	eq(sdk._owns_close_quit, false, "the window close is left to the engine")
	sdk.quit()
	eq(sdk.quit_codes, [0], "quit still quits")
	# A whitespace-only key counts as none.
	var spaces := start({"ingest_key": "   "})
	eq(spaces.get_status_reason(), "no_key", "whitespace key is no key")
	eq(spaces.requests.size(), 0, "and sends nothing")

func test_no_key_optional_is_silent() -> void:
	var sdk := start({"ingest_key": "", "optional": true})
	check(not sdk._logged_once.has("no_key"), "optional = true prints no warning")
	eq(sdk.get_status_reason(), "no_key", "still inert")
	eq(sdk.requests.size(), 0, "no request")
	# The player's choice is still saved while inert, and nothing starts.
	sdk.set_tracking_enabled(false)
	eq(_read("ravensight_optout.save"), "1", "the choice is saved")
	sdk.set_tracking_enabled(true)
	eq(sdk.requests.size(), 0, "and a yes starts nothing")
	eq(_storage_files(), [], "the opt-out file is removed again, no other file")

func test_no_key_reads_project_setting_fallback() -> void:
	ProjectSettings.set_setting("ravensight/ingest_key", "gt_pub_from_settings")
	var sdk := start({"ingest_key": ""})
	ProjectSettings.set_setting("ravensight/ingest_key", null)
	eq(sdk.ingest_key, "gt_pub_from_settings", "the project setting fills an empty key")
	eq(sdk.paths(), ["/settings"], "and the SDK starts")
	eq(sdk.header(sdk.requests[0], "X-API-Key"), "gt_pub_from_settings", "with that key")

func test_opt_in_before_yes_does_nothing() -> void:
	var sdk := make({"consent": "opt_in"})
	sdk.track_event("from_an_earlier_autoload")
	root.add_child(sdk)
	sdk.track_event("before_yes")
	sdk.flush()
	sdk.submit_feedback("hi")
	sdk.advance(3600.0)
	eq(sdk.requests.size(), 0, "no settings check, no session, no request")
	eq(sdk.pending_events.size(), 0, "events before the yes are dropped")
	eq(_storage_files(), [], "no device id, no file")
	eq(sdk.device_id, "", "device_id empty before the yes")
	eq(sdk.is_enabled(), false, "is_enabled() false")
	eq(sdk.get_status_reason(), "disabled", "reason disabled")
	check(signal_args("tracking_disabled").has("player"), "tracking_disabled(player)")
	eq(sdk.reset_device_id(), "", "reset before the yes makes no id")
	eq(_storage_files(), [], "and writes nothing")

func test_opt_in_after_yes_starts_and_queues() -> void:
	var sdk := start({"consent": "opt_in"})
	sdk.track_event("before_yes")
	sdk.set_tracking_enabled(true)
	eq(_read("ravensight_optin.save"), "1", "the yes is saved")
	check(_read("device_id.save").length() > 33, "the device id is made now")
	eq(sdk.device_id, _read("device_id.save"), "and in use")
	eq(sdk.paths(), ["/settings"], "the settings check runs on the yes")
	sdk.track_event("right_after_yes")
	eq(queued_names(sdk), ["game_started", "right_after_yes"], "events right after the yes are queued while the check runs")
	sdk.answer_all_ok()
	eq(sdk.paths(), ["/settings", "/session", "/track/batch"], "then session and batch")
	var names := _sent_events(sdk).map(func(e): return e["event"])
	eq(names, ["game_started", "right_after_yes"], "the event before the yes was never sent")
	eq(sdk.is_enabled(), true, "is_enabled() true")
	check(not FileAccess.file_exists(_file("ravensight_optout.save")), "opt_in never writes the opt-out file")

func test_opt_in_revoke_keeps_device_id() -> void:
	var sdk := start({"consent": "opt_in"})
	sdk.set_tracking_enabled(true)
	sdk.answer_all_ok()
	var id := sdk.device_id
	var before := sdk.requests.size()
	sdk.set_tracking_enabled(false)
	check(not FileAccess.file_exists(_file("ravensight_optin.save")), "the yes is removed")
	eq(_read("device_id.save"), id, "the device id is kept")
	sdk.track_event("after_no")
	sdk.flush()
	sdk.advance(600.0)
	eq(sdk.requests.size(), before, "nothing sent after the no")
	eq(sdk.reset_device_id(), "", "reset after the no forgets the id")
	check(not FileAccess.file_exists(_file("device_id.save")), "and deletes it")

func test_opt_in_saved_yes_starts_next_launch() -> void:
	_write("ravensight_optin.save", "1")
	var sdk := start({"consent": "opt_in"})
	eq(sdk.paths(), ["/settings"], "a saved yes starts at once")
	check(not sdk.device_id.is_empty(), "with a device id")
	# The default mode ignores the opt-in file and still honours an opt-out.
	_clean_storage()
	_write("ravensight_optout.save", "1")
	var plain := start({"consent": "opt_out"})
	eq(plain.requests.size(), 0, "opt_out with a saved opt-out sends nothing")
	var odd := start({"consent": "something_else"})
	eq(odd.requests.size(), 0, "an unknown consent value counts as opt_out")

func test_distribution_on_session_body() -> void:
	var sdk := start({"distribution": "web-itch"})
	sdk.answer_all_ok()
	var body = JSON.parse_string(sdk.requests[1]["body"])
	eq(sdk.requests[1]["path"], "/session", "second request is the session")
	eq(body.get("distribution"), "web-itch", "distribution on the session body")
	for bad in ["x".repeat(41), "line\nbreak", "tab\there", "\U01F3AE".repeat(21)]:
		_clean_storage()
		var other := start({"distribution": bad})
		other.answer_all_ok()
		var b = JSON.parse_string(other.requests[1]["body"])
		check(not b.has("distribution"), "invalid distribution not sent: %s" % bad.c_escape())
		check(other._logged_once.has("bad_distribution"), "and warned once")
	var forty := start({"distribution": "y".repeat(40)})
	forty.answer_all_ok()
	eq(JSON.parse_string(forty.requests[1]["body"]).get("distribution"), "y".repeat(40), "40 characters is accepted")
	var none := start()
	none.answer_all_ok()
	check(not JSON.parse_string(none.requests[1]["body"]).has("distribution"), "unset sends no distribution key")

func test_batch_403_ends_run() -> void:
	var sdk := started_with_session()
	sdk.track_event("x")
	sdk.flush()
	sdk.answer(403, {"error": "forbidden"})
	eq(sdk.get_status_reason(), "invalid_key", "a batch 403 is a refused key")
	eq(sdk.pending_events.size(), 0, "queue cleared")
	var n := sdk.requests.size()
	sdk.track_event("y")
	sdk.flush()
	sdk.advance(600.0)
	eq(sdk.requests.size(), n, "nothing more is sent")

func test_jitter_bounds() -> void:
	# The lowest draw: 10 s less 20 percent.
	var low := start()
	low.fake_random = 0.0
	low.answer(200, {"trackingEnabled": true})
	low.answer(0, "")
	low.advance(7.9)
	eq(low.unanswered().size(), 0, "not before 8 s")
	low.advance(0.2)
	eq(low.unanswered().size(), 1, "retried by 8.1 s")
	# The highest draw: 10 s plus 20 percent.
	var high := start()
	high.fake_random = 0.999999
	high.answer(200, {"trackingEnabled": true})
	high.answer(0, "")
	high.advance(11.9)
	eq(high.unanswered().size(), 0, "not before 11.9 s")
	high.advance(0.2)
	eq(high.unanswered().size(), 1, "retried by 12.1 s")
	# Spread never passes the 5 minute cap.
	var capped := start()
	capped.fake_random = 0.999999
	capped.answer(200, {"trackingEnabled": true})
	for i in 8:
		capped.answer(0, "")
		capped.advance(400.0)
	capped.answer(0, "")
	capped.advance(300.0)
	eq(capped.unanswered().size(), 1, "a capped wait is at most 300 s")

func test_retry_after_not_jittered() -> void:
	var sdk := start()
	sdk.fake_random = 0.0
	sdk.answer(200, {"trackingEnabled": true})
	sdk.answer(429, {"error": "rate_limited"}, ["Retry-After: 30"])
	sdk.advance(29.0)
	eq(sdk.unanswered().size(), 0, "Retry-After 30 is not shortened")
	sdk.advance(1.0)
	eq(sdk.unanswered().size(), 1, "and is obeyed exactly")

func test_rs_event_id_shape_and_resend() -> void:
	var sdk := started_with_session()
	var shape := RegEx.new()
	shape.compile("^[A-Za-z0-9_-]{1,64}$")
	var caller := {"level": "1"}
	sdk.track_event("a", caller)
	sdk.track_event("b")
	check(not caller.has("rs_event_id"), "the caller's dictionary is not changed")
	sdk.flush()
	var first: Array = sdk.events_in(sdk.requests[sdk.requests.size() - 1])
	sdk.answer(500, {"error": "internal_error"})
	sdk.advance(10.0)
	sdk.answer_all_ok()
	var resent: Array = sdk.events_in(sdk.requests[sdk.requests.size() - 1])
	eq(resent.map(func(e): return e["data"]["rs_event_id"]), first.map(func(e): return e["data"]["rs_event_id"]), "a resend carries the same ids")
	var ids: Array = []
	for e in _sent_events(sdk):
		var id := str(e["data"].get("rs_event_id", ""))
		check(shape.search(id) != null, "shape: %s" % id)
		check(id.begins_with(sdk.device_id.substr(0, 16) + "-"), "prefix is the first 16 characters of the device id")
		var parts := id.split("-")
		eq(parts.size(), 4, "prefix, launch time, nonce, counter")
		eq(parts[2].length(), 8, "an 8 hex character nonce")
		if not ids.has(id):
			ids.append(id)
	eq(ids.size(), 3, "game_started, a and b have distinct ids")
	# Playtest ids are made the same way from pt-<run id>.
	var pt := started_with_session()
	pt.set_playtest_context({"token": "tok", "run_id": "run.with spaces"})
	pt.track_event("p")
	var pid := str(pt.pending_events[pt.pending_events.size() - 1]["data"]["rs_event_id"])
	check(shape.search(pid) != null, "a playtest id has the shape too: %s" % pid)

func test_rs_event_id_stable_prefix_across_launches() -> void:
	var one := started_with_session()
	var id1 := str(_sent_events(one)[0]["data"]["rs_event_id"])
	var two := started_with_session()
	var id2 := str(_sent_events(two)[0]["data"]["rs_event_id"])
	eq(id1.split("-")[0], id2.split("-")[0], "the per-install prefix survives a relaunch")
	check(id1.split("-")[2] != id2.split("-")[2], "the nonce is new per launch")
	# The first launch, with an event tracked before any device id existed.
	_clean_storage()
	var early := make()
	early.track_event("before_ready")
	eq(early.device_id, "", "no id before ready on a first launch")
	root.add_child(early)
	early.answer_all_ok()
	for e in _sent_events(early):
		check(str(e["data"].get("rs_event_id", "")).begins_with(early.device_id.substr(0, 16)), "stamped before sending: %s" % e["event"])

func test_event_over_8kb_dropped() -> void:
	var sdk := started_with_session()
	var tracked: Array = []
	sdk.event_tracked.connect(func(n, _d): tracked.append(n))
	sdk.track_event("huge", {"blob": "x".repeat(8200)})
	sdk.track_event("huge_again", {"blob": "x".repeat(9000)})
	eq(queued_names(sdk), [], "too large events are never queued")
	eq(signal_args("flush_failed").count("event_too_large"), 2, "flush_failed(event_too_large) for each")
	check(sdk._logged_once.has("event_too_large"), "one warning")
	eq(tracked, [], "and not announced on event_tracked")
	# Just under the cap still goes.
	sdk.track_event("fits", {"blob": "x".repeat(8000)})
	eq(queued_names(sdk), ["fits"], "an event under 8,192 bytes is queued")
	sdk.flush()
	sdk.answer_all_ok()
	eq(sent_count(sdk, "huge"), 0, "never sent")
	eq(sent_count(sdk, "fits"), 1, "the one that fits is sent")

func test_default_key_only_unchanged() -> void:
	# A game that passes only a key: no new file, the 0.2.0 requests.
	var sdk := started_with_session()
	var files := _storage_files()
	files.sort()
	eq(files, ["device_id.save"], "only the device id file, as in 0.2.0")
	eq(sdk.paths(), ["/settings", "/session", "/track/batch"], "settings, session, batch")
	var body = JSON.parse_string(sdk.requests[1]["body"])
	eq(body.keys().size(), 3, "the session body has deviceId, gameVersion, platform only")
