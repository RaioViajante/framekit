# raioviajando-tools

Tooling for the Raioviajando video workflow.

Nothing in this repository prescribes creative decisions (story, scenes, duration, music, SFX,
animation style or pacing) for any episode. It holds technical tooling only.

## Current contents

| Path | What it is |
|---|---|
| `captions/reference/` | **Legacy/reference** Swift caption renderer, frozen exactly as used for EP001 |
| `captions/tests/` | Regression test that re-renders nine EP001 frames and compares them with golden PNGs |
| `docs/DEVELOPMENT.md` | How to run the tests, the exit-code policy and the rules for golden files |

There is **no new renderer, preset or schema yet**. The baseline exists so that a future renderer
can be compared against what EP001 actually shipped.

## Quick start

Requires macOS, Xcode Command Line Tools (`swiftc`) and Python 3. No other dependencies.

```sh
python3 -I -m unittest discover -s captions/tests      # portable unit tests
python3 -I captions/tests/run_reference_regression.py   # visual regression (macOS only)
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for details.
