<img src="logo.png" width="96" alt="Ravensight" />

# Ravensight Godot SDK

Official Godot 4 SDK for [Ravensight](https://ravensight.io): player
analytics for indie games. One autoload script gives your game:

- **Batched event tracking** with an offline queue and automatic retry. It
  keeps up to 500 events queued while offline.
- **Session management**: a random device id, a publishable ingest key,
  token refresh
- **Rate-limit aware**: honours 429 and Retry-After, backs off when offline
- **Server kill switch**: disable tracking remotely without shipping a patch
- **Player privacy**: a random per-install device id, no advertising
  identifier, `set_tracking_enabled(false)` (saved) and `reset_device_id()`
  for games that show their own consent or settings screen; no tracking
  permission prompt needed. What your store label can say:
  https://ravensight.io/docs/#privacy-label
- **In-game player feedback**: bug reports and ratings straight from players
- **Suggestions API** (experimental): machine-readable tuning hints derived
  from Ravensight's weekly AI analysis

Version 0.2.0. See [CHANGELOG.md](CHANGELOG.md) for what changed.

## Install

1. Copy `Ravensight.gd` into your project (e.g. `res://addons/ravensight/`).
2. Project > Project Settings > Autoload: add it, named `Ravensight`.
3. Set your game's `ingest_key` (`gt_live_...`, from the Ravensight
   dashboard) before Ravensight's `_ready()` runs: edit the default at the
   top of `Ravensight.gd`, or set it from an autoload listed above
   `Ravensight`. The same goes for every option below.

The ingest key is publishable and safe to ship in your binary: it can open
sessions, read the tracking kill switch and read this game's design
suggestions. It cannot read analytics or feedback, or manage your account.

## Use

```gdscript
Ravensight.track_event("level_start", {"level": "level_3"})
Ravensight.track_event("player_died", {"level": "level_3", "cause": "spikes"})
Ravensight.submit_feedback("The boss feels unfair", "complaint", 2)
```

`track_event()` only queues. Events go out in batches of up to 50: 5 seconds
(`flush_interval`) after the first waiting event, at once when 50 are
waiting, on `flush()`, when the app goes to the background, and on quit.
It is safe to call from any autoload, even before Ravensight's own
`_ready()`: such events wait for the opt-out and kill switch checks.

## Options

| Option | Default | Notes |
| --- | --- | --- |
| `api_url` | `https://api.ravensight.io` | With or without `/api/v1`, with or without a trailing slash. Empty means the default. `api_base()` returns the normalised root. |
| `ingest_key` | `gt_live_your_ingest_key_here` | Your game's publishable `gt_live_` key. |
| `game_version` | `1.0.0` | Sent with every session. |
| `enabled` | `true` | `false` turns the SDK off for this run: no request of any kind, nothing queued, no `game_started`, until `set_enabled(true)`. Never saved. `set_tracking_enabled()` still saves the player's choice while it is `false`. |
| `max_queue_size` | `500` | Unsent events kept. The oldest are dropped first; a queued `game_started` is kept. |
| `flush_interval` | `5.0` | Seconds an event waits so it can go out with others. 50 waiting events go at once. |
| `handle_quit` | `true` | Take over the window close (and the Android back button when it quits) to send the last events, holding the quit at most 1.5 seconds. See Quitting. |
| `session_timeout` | `1800.0` | Android and iOS only: seconds in the background after which the session counts as over. See Automatic events. |

## Functions

| Function | What it does |
| --- | --- |
| `track_event(name, data = {})` | Queue an event. |
| `flush()` | Send what is queued now instead of waiting for the timer. Cuts a backoff wait short; a server's Retry-After wait still holds. |
| `quit(exit_code = 0)` | Send `game_exited` and the queue, then quit. Call it from your own Quit button instead of `get_tree().quit()`. |
| `submit_feedback(message, category = "", rating = 0)` | Send player feedback. `category` is optional and one of `FEEDBACK_CATEGORIES`: `bug`, `suggestion`, `complaint`, `praise`, `playtest`, `other`. `rating` is 0 to leave it out, or a whole number from 1 to 5. Needs an open session. |
| `set_tracking_enabled(on)` | The player's opt-out, saved across launches. See Player privacy. |
| `is_tracking_enabled()` | `true` while events are collected: enabled, not opted out, kill switch on. |
| `reset_device_id()` | Start a fresh analytics identity for this install. Returns the new id. |
| `set_enabled(on)` | The game's own switch for this run (see `enabled`). |
| `get_status_reason()` | Why nothing is being sent, or `""`. See Startup and failures. |
| `api_base()` | The API root requests go to, e.g. `https://api.ravensight.io/api/v1`. |
| `is_playtest()` | `true` in a run driven by the Ravensight playtest runner. |
| `set_playtest_context(ctx)` | Puts a running game into playtest mode. The SDK already does this from the playtest runner's variables, so a game never needs to call it by hand. |
| `fetch_suggestions()` | Experimental. Answers on `suggestions_received`; while tracking is off nothing is requested and it answers with an empty list. |

`Ravensight.session_token` is the open session's token, or `""` until one
opens. If your game server should report into the player's session, hand it
this token and have it send it as `joinToken` when it opens its own session
(see the HTTP API in the docs). The SDK never computes a session id itself.

## Signals

| Signal | Arguments | When |
| --- | --- | --- |
| `session_ready` | | A session is open. |
| `session_failed` | `reason` | Opening a session failed: `"invalid_key"` for a refused key, otherwise the server's error code or `"offline"`. Retried for you unless the key was refused. |
| `tracking_disabled` | `source` | `"server"` for the kill switch, `"player"` after an opt-out, `"init"` when `enabled` is `false` or after `set_enabled(false)`. |
| `status_changed` | `reason` | `get_status_reason()` changed. |
| `events_flushed` | `count` | A batch was accepted. `count` is the number sent; the server may store fewer, e.g. it drops events older than 90 days. |
| `flush_failed` | `reason` | A batch failed. It is retried for you, except one event the server refuses with 400, which is dropped. |
| `feedback_submitted` | | Feedback was accepted. |
| `feedback_failed` | `reason` | Feedback failed: `"disabled"`, `"empty_message"`, `"invalid_category"`, `"invalid_rating"` or `"no_session"` before sending (no request is made), or the server's error code. |
| `event_tracked` | `name, data` | Every queued event, with the data actually queued. |
| `suggestions_received` | `suggestions` | The answer to `fetch_suggestions()`. |

## Automatic events

The SDK sends exactly two events by itself:

- **`game_started`**, once per session. It is queued at launch, first in the
  queue with the launch time, and sent once the kill switch check allows it.
  It is never queued while the SDK is disabled or the player has opted out;
  a game enabled later in the run queues it then, once.
- **`game_exited`**, once, when the game quits through `Ravensight.quit()`,
  the window close, or the Android back button when the SDK handles that
  quit. Losing focus on a desktop is not an exit: it only sends what is
  queued.

**Android and iOS.** Going to the background sends what is queued and saves
a small marker (`user://ravensight_bg.save`); no event is sent. Back in the
foreground within 30 minutes (`session_timeout`), nothing happens. After 30
minutes or more, the old session gets `game_exited` stamped with the moment
the app went to the background, and a new session starts with
`game_started`. If the player swipes the app away while it is in the
background, the next launch sends that `game_exited` from the marker (one
attempt, before anything else) and deletes the marker.

**Web export.** The browser gives a Godot web game no close notification,
so a web build never sends `game_exited`. `game_started` and everything you
track are sent as usual.

## Quitting

So the last events (including `game_exited`) are actually sent, the SDK
takes over the window close: it sets `get_tree().auto_accept_quit = false`,
flushes on a close request, and quits when the flush is answered or after
1.5 seconds, whichever comes first.

From your own Quit button, call `Ravensight.quit()` instead of
`get_tree().quit()`. It does the same, whatever `handle_quit` is:

```gdscript
func _on_quit_pressed() -> void:
	Ravensight.quit()
```

If your game has its own "really quit?" dialog on the window close, set
`Ravensight.handle_quit = false` before Ravensight's `_ready()`. The SDK
then queues `game_exited` (once) and flushes on a close request, and your
dialog calls `Ravensight.quit()` when the player confirms.

## Startup and failures

`get_status_reason()` says why nothing is being sent, and `status_changed`
fires when that changes:

| Reason | Meaning |
| --- | --- |
| `""` | Nothing is wrong: a session is open, or opening normally. |
| `disabled` | `enabled` is `false`, or the player opted out. |
| `invalid_key` | The server refused the ingest key (401, or a 403 that is not one of the codes below). Logged once as `Ravensight: ingest key refused (invalid_key), sending stopped for this run. Check your gt_live_ key.` Automatic sending stops for the run; events keep queueing and `flush()` tries once more. |
| `tracking_disabled` | The kill switch is off for your game. The queue is dropped and nothing more is sent this run. |
| `offline` | No answer (no connection, or no reply within 15 seconds). Retried after 10 seconds, doubling up to 5 minutes; events are kept. |
| `rate_limited` | The server said slow down (429, or 503 with Retry-After). The SDK waits exactly the Retry-After time. |
| `session_failed` | Opening a session failed for another reason (retried with the same backoff), or a playtest token was refused. |
| `playtest_job_closed` | The playtest job this run belongs to has closed. Nothing more is sent. |

If the server refuses one oversized event, the batch is halved until that
event is alone, then it is dropped and reported on `flush_failed`, so it
never costs the events around it. Events can be lost: the oldest go when
more than `max_queue_size` are waiting, and whatever is still unsent when the
game quits is not saved for the next launch.

## Levels and deaths

Ravensight builds the level funnel, per-level deaths and journeys from your
event names, with no configuration: names containing `died`, `destroyed` or
`killed` count as deaths, `start`, `begin` or `enter` as level starts, and
`complet`, `finish`, `win` or `clear` as completions. The `level`,
`location` or `track` field says where.

To say what an event means instead, set `rs_kind` in its data to
`level_start`, `level_complete`, `death` or `none`. It is read before the
name, and `none` opts an event out:

```gdscript
Ravensight.track_event("boss_phase_begin", {"level": "castle", "rs_kind": "none"})
Ravensight.track_event("run_over", {"level": "castle", "rs_kind": "death"})
```

Keys that start with `rs_` are reserved for Ravensight.

## Player privacy

The device id is 16 random bytes from the operating system's secure random
source, as hex, plus the OS name, generated on first run and saved in
`user://`. It is never derived from hardware or an advertising identifier,
so a game that sends gameplay events and nothing else needs no tracking
permission prompt. If your game offers a privacy setting, wire it:

```gdscript
Ravensight.set_tracking_enabled(false)  # saved; nothing is sent while off
Ravensight.reset_device_id()            # forget this install's analytics identity
```

`set_tracking_enabled()` writes the choice at once and can be called at any
time, even from an autoload that runs before Ravensight's `_ready()`, or
while `enabled` is `false`. A saved opt-out wins over `enabled = true`: on
the next launch nothing is sent, not even the kill switch check. Turning it
off drops the queue. `reset_device_id()` saves a new random id, drops the
queue and the session, and returns the new id.

## Telling players

You do not need a permission prompt, but saying what the game sends is good
manners. A paragraph your game can show, in a settings screen or on its
store page:

> This game sends anonymous gameplay events (what happens in the game, never
> who you are) to Ravensight so we can improve it. You can turn this off in
> Settings at any time.

And the toggle behind "turn this off":

```gdscript
# an "Analytics" switch in your settings screen
func _on_analytics_toggled(on: bool) -> void:
	Ravensight.set_tracking_enabled(on)  # remembered across launches

# a "Forget me" button: a fresh random identity from now on
func _on_forget_me_pressed() -> void:
	Ravensight.reset_device_id()
```

## Playtest

When the Ravensight playtest runner launches your game, it passes
`RAVENSIGHT_PLAYTEST_TOKEN` and `RAVENSIGHT_PLAYTEST_RUN_ID` (or the
`--ravensight-playtest-token=` and `--ravensight-playtest-run-id=` launch
arguments). The SDK then sends the `X-Ravensight-Playtest` header on every
request, uses the device id `pt-<run id>` without reading or writing the
saved one, ignores the player's saved opt-out, and tags every event as
synthetic, so persona sessions never mix with real players.
`set_tracking_enabled()` and `reset_device_id()` do nothing in such a run
(they print one line), so a settings screen that re-applies a saved choice
cannot stop a paid run. A token without a run id sends nothing at all.

## Running the tests

The behaviour tests run headless with a fake transport and a fake clock, so
they need a Godot 4 binary but no network and no project:

```bash
bash tests/run.sh path/to/godot                      # the behaviour tests
bash check-gdscript.sh path/to/godot Ravensight.gd   # the parse check
```

`tests/run.sh` wraps `godot --headless --script tests/run.gd`, because
Godot's command line exits 0 even when a script fails to parse. For 0.2.0
both were run on macOS with Godot v4.8.dev1 (193 checks in 34 tests, all
passing). CI runs both with Godot 4.5-stable on every push
(`.github/workflows/parse.yml`). The tests replace the network layer; for
0.2.0 the real `HTTPRequest` path was also run once, by hand, against a
local stub server (settings, session, two batches, quit, and a request that
never answers giving up after 15 seconds), not against the hosted API.

## Full documentation

https://ravensight.io/docs/#godot-sdk

## License

MIT
