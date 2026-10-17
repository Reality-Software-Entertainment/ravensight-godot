# Changelog

## [0.3.0] - 2026-10-16

For games whose builds or source anyone can download. A game that sets a
key and none of the new options behaves as on 0.2.0, except for the
changes listed under Breaking. `Ravensight.VERSION` is `"0.3.0"`.

### Breaking

- `ingest_key` defaults to `""` (was the placeholder
  `gt_live_your_ingest_key_here`). With no key the SDK is inert instead of
  sending requests with a placeholder key.
- A refused ingest key (401, or a 403 that is not the kill switch or a
  refused playtest token) on the settings check, the session, a batch,
  feedback or suggestions now ends the run: the queue is cleared, nothing
  is retried, `flush()` sends nothing, and `tracking_disabled("key")` is
  emitted. Before, events kept queueing and `flush()` tried once more. A
  401 on a batch still means an expired session: the SDK opens a new one
  first.
- Backoff waits carry plus or minus 20 percent jitter. `Retry-After` is
  still obeyed exactly.
- Every event's data gains an `rs_event_id` key, and the SDK always queues
  a copy of the caller's dictionary (it queued the caller's own dictionary
  outside a playtest run).
- An event whose data is over 8,192 bytes as JSON is dropped before it is
  queued, with one warning for the run and `flush_failed("event_too_large")`
  for each, instead of being sent and split out by the server's 400.
- No device id file is written before `_ready()`: it is made there, once
  the SDK knows it has a key (and, with `consent = "opt_in"`, a yes).

### Added

- **Inert without a key.** An empty `ingest_key`, and no
  `ravensight/ingest_key` project setting, writes no files, makes no
  request, runs no timer and leaves the window close alone; every call is
  a quiet no-op. One warning, silenced by `optional = true`.
  `get_status_reason()` is `"no_key"`.
- `ravensight/ingest_key` project setting, read when `ingest_key` is empty,
  so a release step can add the key on the build machine only.
- `consent = "opt_in"`: no device id, settings check or session before
  `set_tracking_enabled(true)`; the yes is saved as
  `user://ravensight_optin.save`. `"opt_out"` stays the default. Events
  tracked before the yes are dropped; events right after it are queued
  while the settings check runs. Saying no again keeps the device id;
  `reset_device_id()` forgets it.
- `distribution` option, sent on `POST /session` when set (at most 40
  characters counted in UTF-16 units, no control characters, otherwise not
  sent and one warning).
- `rs_event_id` on every event: the first 16 characters of the device id,
  the launch time in hex, an 8 hex character per-launch nonce from
  `Crypto` and a counter. A resend after a failure carries the same id.
- `is_enabled()`, true only while the SDK is collecting.

## [0.2.0] - 2026-10-10

The first versioned release. `Ravensight.VERSION` is `"0.2.0"`.

### Breaking

- `api_url` defaults to `https://api.ravensight.io` (it was a placeholder).
  Old values still work: the URL is accepted with or without `/api/v1` and
  trailing slashes (see `api_base()`).
- `max_queue_size` defaults to 500 (was 100).
- `set_tracking_enabled()` is a no-op in a playtest run, like
  `reset_device_id()`. It no longer writes the opt-out flag or stops a
  paid run.
- `track_event()` no longer sends at once: events wait up to
  `flush_interval` (5 seconds) so they go out together, or go at once when
  50 are waiting.
- `submit_feedback()` while tracking is off fails with `"disabled"` (was
  `"tracking_disabled"`), and an unknown category or a rating outside 1 to 5
  fails locally with `"invalid_category"` / `"invalid_rating"` instead of
  being sent.
- A refused ingest key is reported on `session_failed` as `"invalid_key"`
  (was the server's code, e.g. `"invalid_api_key"`) and is no longer
  retried every few minutes.
- `tracking_enabled` is read-only; use `set_tracking_enabled()` or
  `set_enabled()`.
- The kill switch holds for the rest of the run: turning the player's
  opt-out off and on again no longer re-reads it.
- `game_started` is sent at most once per run (once per session on Android
  and iOS): opting out and back in no longer sends a second one.
- `reset_device_id()` returns the new id.

### Added

- `enabled` option and `set_enabled()`: turn the SDK off for a run, with no
  request of any kind.
- `quit(exit_code)`: send `game_exited` and the queue from your own Quit
  button, whatever `handle_quit` is.
- `get_status_reason()` and the `status_changed` signal, with the reasons
  `disabled`, `invalid_key`, `tracking_disabled`, `offline`, `rate_limited`,
  `session_failed`, `playtest_job_closed`.
- `api_base()`, `is_playtest()`, `FEEDBACK_CATEGORIES`, `VERSION`,
  `flush_interval`, `session_timeout`.
- Android and iOS: after 30 minutes (`session_timeout`) in the background,
  the session ends with `game_exited` at the moment the app left and a new
  one starts with `game_started`. An app killed in the background reports
  its `game_exited` on the next launch.
- Playtest: the run id can come from `--ravensight-playtest-run-id=`; the
  playtest header is sent on every request.
- Headless behaviour tests (`tests/run.sh`) with a fake transport and
  clock, run in CI.

### Fixed

- `fetch_suggestions()` made a request while tracking was off. It now
  answers with an empty list and sends nothing.
- An event tracked before the SDK's `_ready()` (from an earlier autoload)
  could be sent after the player had opted out, and could hit a null timer.
  The saved opt-out is now read when the SDK is constructed.
- A wrong or placeholder ingest key retried forever. It is now logged once
  and automatic sending stops; `flush()` tries once more.
- A request that never answered blocked sending for the rest of the run.
  Every request now gives up after 15 seconds.
- A cancelled close request (with `handle_quit = false`) queued
  `game_exited` mid-session. It now only flushes; `quit()` sends the exit.
- A playtest token without a run id ran as a real player. It now sends
  nothing.
- Retry-After is honoured on 503 as well as 429; a batch 401 reopens the
  session at most twice in a row, then backs off.

## [0.1.0]

Untagged `main` up to 8fa49b7.
