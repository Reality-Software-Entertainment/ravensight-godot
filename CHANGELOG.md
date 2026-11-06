# Changelog

## Unreleased

Held until the Ravensight server release that accepts origins, signatures,
gzip bodies and the ad and attribution keys is deployed. The version is set
at release.

### Breaking

- Experiment tags follow the exposure contract: an event carries `rs_exp_<key>` only after the game first reads a config value in that session, not after a fetch. A well-formed `rs_exp_<key>` the game sets is left alone.
- A 403 on a batch, and the kill switch, keep the queued events on disk for the next launch instead of discarding them.
- A batch 401 opens a new session once (was twice), then waits for the backoff.
- Backoff waits are multiplied by a random factor from 0.5 up to 1 (was plus or minus 20 percent).
- Only `400 batch_too_large` and 413 halve a batch. Any other 400 without an `index` (such as `event_too_large` or `invalid_json`) drops that request's events instead of halving.

### Added

- Saved queue: unsent events in `user://ravensight/queue-<hash>.json`, format version 2, written atomically, at most 500 events, events older than 89 days dropped on load, removed only after a 2xx or a refusing 400. `get_delivery_stats()` counts what was let go.
- Each session's `origin` is saved with its events and sent on every event a later session delivers, so the server files it under the session, build and platform it happened in.
- gzip for request bodies of 1,024 bytes or more; a 415, or a 413 for one compressed event, is resent uncompressed once (a 413 for one uncompressed event is dropped, as before).
- Request signing (`X-Ravensight-Timestamp`, `X-Ravensight-Signature`) when the session answer has `signing`, with the clock corrected by `serverTime`. The secret is never written to disk.
- A 400 with `index` drops only that event; `batch_too_large` halves the batch like a 413.
- The shared error queue rules: gameplay events (a game's own `track_error` included) go before captured errors, also after the queue is read from disk; a capture evicts only the oldest capture, never a gameplay event; `rs_trail` is never written to the queue file; opting out or resetting the id deletes persisted captures. Neither eviction nor ordering moves an event in the batch in flight.
- `track_ad()`, `track_ad_revenue()`, `micros_from_decimal_string()`, `micros_from_revenue()`, `set_attribution()` (once per install) and `get_device_id()`.
- `rs_exposure`, sent once at a session's first exposure.
- Device fields on the session: `model`, `osVersion` and `gpu`, as the engine reports them.
- Event timestamps are unix milliseconds, so events in one second keep their order in funnels and sessions. Events queued by an older version are sent as they were recorded.
- The background marker of a run killed on mobile is replayed through the saved queue under that run's origin.

### Fixed

- Control characters in event data are escaped in request bodies. GDScript's `JSON.stringify` wrote them raw, which made the server refuse the whole batch.
- The local 8 KB check counts an error event's `rs_message`, `rs_stack` and `rs_trail` (within 200, 2,000 and 1,500 characters) one byte a character, as the server does, so an allowed stack is never dropped on the device.

## [0.4.0] - 2026-11-06

### Added

- Automatic error capture on Godot 4.5 and later, on by default: script
  errors (`rs_source` `uncaught`), `push_error()` and `push_warning()`
  (`log`) become ordinary `error` events, through a logger added with
  `OS.add_logger()` and drained on the main thread. Installed only with a
  key, consent, an active SDK and the game's `errorCapture.enabled`.
  `error_capture`, `set_error_capture()` and `is_error_capture_active()`.
- Boot errors: the hook installs at startup, and until the settings
  answer arrives at most 5 captures are held in memory, then sent if the
  game's switch is on or discarded unsent if it is off.
- Device caps per session (30 captures, 3 per error, 10 trails, 6 a
  minute) and on-device scrubbing before anything is queued.
- An opt-in trail of the last 20 printed lines and tracked event names,
  sent with an error only when the game's trail switch is on.
- A home folder scrubs as the whole name, spaces included, and
  `C:\Documents and Settings\<name>` is a home folder, with either slash
  (scrub contract 5, vectors 6).

### Fixed

- A 413 answer to a batch is split and the refused event dropped, like a
  400, instead of being retried as is.
- Captured errors are dropped before gameplay events when the queue is
  full.

## 0.3.1 (held)

### Added

- Screenshot Player Reports with session-bound retry identity and credential-free presigned multipart uploads.

- Session-start remote config, ETag and scoped offline cache, typed fallback getters and config_ready.
- Active experiment exposure labels on tracked events.

### Fixed

- Discard late config responses after identity or consent changes.


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

### Typed events and performance sampling (included in this release)

`Ravensight.VERSION` is `"0.3.0"`.

### Added

- Typed event helpers: `track_purchase()`, `track_resource()`,
  `track_progression()` and `track_error()`. Each builds the reserved `rs_*`
  properties and calls `track_event()`, so queueing, batching, retries and
  opt-out are unchanged. Extra properties go in `options["data"]` (the
  reserved keys win), and `options["event_name"]` overrides the default
  event name.
- Opt-in performance sampling: set `performance = true` to sample the frame
  time once per second and send one `health` event per session (median and
  10th percentile frames per second, memory where the platform exposes it,
  boot time) when the app goes to the background (mobile), the page is
  hidden (web) or the game quits (desktop). Nothing is sent when no sample
  was taken, and nothing is sent from the frame hook.
- The session request now carries `"sdk": "godot/0.3.0"`.

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
