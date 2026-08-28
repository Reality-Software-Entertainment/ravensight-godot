# Ravensight Godot SDK

This repo is a **public mirror** of `godot/Ravensight.gd` from the
Ravensight platform repo. The platform repo is the source of truth for the
SDK's implementation: changes flow **platform to here**, never the reverse.
Do not develop new SDK features directly in this repo; port them over from
the platform repo once they've landed and been tested there.

- **Language**: GDScript, targeting Godot 4.x.
- **License**: MIT.
- **No em dashes or en dashes in docs.** Use commas, colons, periods, or
  restructure the sentence instead - this applies to README.md and any
  other prose in this repo.

## Syncing from the platform repo

When `godot/Ravensight.gd` changes in the platform repo:

1. Copy the updated file here as `Ravensight.gd`.
2. Update this repo's `README.md` if the public-facing install/usage
   instructions changed (mirrors the platform repo's `GODOT_GUIDE.md` at a
   summary level, not verbatim).
3. Commit and push to `main`.

This repo has no independent CI or test suite of its own; correctness is
validated in the platform repo before the file is copied here.
