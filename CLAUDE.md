# Ravensight Godot SDK

This repo is the **source of truth** for the Ravensight Godot SDK
(`Ravensight.gd`). The copies in the Ravensight platform repo
(`godot/Ravensight.gd` and `marketing/sdk/godot/Ravensight.gd`) are synced
from here after each tagged release; do not edit them first and port back.

- **Language**: GDScript, targeting Godot 4.x.
- **License**: MIT.
- **No em dashes or en dashes** in docs, code comments or log messages. Use
  commas, colons, periods, or restructure the sentence. Never name another
  company's product.

## Tests

```bash
bash tests/run.sh path/to/godot                      # behaviour tests
bash check-gdscript.sh path/to/godot Ravensight.gd   # parse check
```

`tests/fake_ravensight.gd` extends the SDK and replaces `_send()`, the
clocks (`_now()`, `_unix_now()`), the storage folder (`_storage_dir()`),
`_is_mobile()` and `_quit_tree()`; every request the SDK makes goes through
`_send()`, so keep it that way. Godot's CLI exits 0 on a parse error, which
is why `tests/run.sh` checks for the `PASS:` line. CI
(`.github/workflows/parse.yml`) runs both with Godot 4.5-stable.

## Releasing

Bump `VERSION` in `Ravensight.gd`, add a CHANGELOG entry (Breaking, Added,
Fixed), update README.md, tag. Then the platform repo copies are synced
from the tagged file.
