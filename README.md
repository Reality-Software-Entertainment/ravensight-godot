<img src="logo.png" width="96" alt="Ravensight" />

# Ravensight Godot SDK

Official Godot 4 SDK for [Ravensight](https://ravensight.io): player
analytics for indie games. One autoload script gives your game:

- **Batched event tracking** with an offline queue and automatic retry
- **Session management**: device IDs, publishable ingest keys, token refresh
- **Rate-limit aware**: honors 429 + Retry-After with backoff, never loses events
- **Server kill switch**: disable tracking remotely without shipping a patch
- **Player privacy**: a random per-install device id, no advertising
  identifier, `set_tracking_enabled(false)` (persisted) and
  `reset_device_id()` for games that show their own consent or settings
  screen; no tracking permission prompt needed. What your store label can
  say: https://ravensight.io/docs/#privacy-label
- **In-game player feedback**: bug reports and ratings straight from players
- **Suggestions API** (experimental): machine-readable tuning hints derived
  from Ravensight's weekly AI analysis

## Install

1. Copy `Ravensight.gd` into your project (e.g. `res://addons/ravensight/`).
2. Project → Project Settings → Autoload → add it, named `Ravensight`.
3. In the Inspector set `api_url` (`https://api.ravensight.io`) and your
   game's `ingest_key` (`gt_live_...`, from the Ravensight dashboard,
   publishable, safe to ship in your binary).

## Use

```gdscript
Ravensight.track_event("level_start", {"level": "level_3"})
Ravensight.track_event("player_died", {"level": "level_3", "cause": "spikes"})
Ravensight.submit_feedback("The boss feels unfair", "complaint", 2)
```

The device id is 16 random bytes plus the OS name, generated on first run
and saved locally. It is never derived from hardware or an advertising
identifier, so a game that sends gameplay events and nothing else needs no
tracking permission prompt. If your game offers a privacy setting, wire it:

```gdscript
Ravensight.set_tracking_enabled(false)  # persisted; nothing is sent while off
Ravensight.reset_device_id()            # forget this install's analytics identity
```

Full guide: https://github.com/Reality-Software-Entertainment/ravensight,
see `GODOT_GUIDE.md`.

## Quitting

So the last events (including `game_exited`) are actually sent, the SDK
takes over the window close: it sets `get_tree().auto_accept_quit = false`,
flushes on a close request, and calls `get_tree().quit()` itself when the
flush is answered or after 1.5 seconds. It also flushes when the game is
backgrounded. If your game has its own "really quit?" flow, set
`Ravensight.handle_quit = false` before the SDK's `_ready()` and call
`Ravensight.flush()` before you quit. Full details:
https://ravensight.io/docs/#godot-sdk

## License

MIT
