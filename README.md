# raioviajando-tools

Tooling for the Raioviajando video workflow.

Nothing in this repository prescribes creative decisions (story, scenes, duration, music, SFX,
animation style or pacing) for any episode. It holds technical tooling only.

## Current contents

| Path | What it is |
|---|---|
| `captions/reference/` | **Legacy/reference** Swift caption renderer, frozen exactly as used for EP001 |
| `captions/tests/` | Regression test that re-renders nine EP001 frames and compares them with golden PNGs |
| `docs/DEVELOPMENT.md` | How to run the tests, the result and exit-code policy, CI limitations and the rules for golden files |
| `NOTICE.md`, `docs/PROVENANCE-AND-LICENSING.md` | License classification and provenance |

There is **no new renderer, preset or schema yet**. The baseline exists so that a future renderer
can be compared against what EP001 actually shipped.

## License

Source code, documentation and test metadata: [MIT](LICENSE) (the standard, unmodified text). The
golden PNGs and `frames.json` are **not** MIT: they may only be downloaded, cloned, forked, copied and
reproduced unmodified as needed to run and verify this repository's regression tests. See
[NOTICE.md](NOTICE.md) and [docs/PROVENANCE-AND-LICENSING.md](docs/PROVENANCE-AND-LICENSING.md).

## Quick start

Requires macOS, Xcode Command Line Tools (`swiftc`) and Python 3. No other dependencies.

```sh
python3 -I -m unittest discover -s captions/tests      # portable unit tests
python3 -I captions/tests/run_reference_regression.py   # visual regression (macOS only)
```

## CI limitations

- The committed goldens come from macOS 27.0.1, Swift 6.4 and specific font versions
  (`captions/tests/fixtures/ep001/manifest.json`).
- GitHub-hosted CI currently uses a different environment (macOS 26.6.2, Swift 6.3.3).
- Hosted CI validates integrity, compilation, determinism, PNG structure, the unit and scenario tests
  and a gross-defect visual screen.
- When outputs differ across environments, exact equivalence to the goldens is **NOT VERIFIED** (exit
  code 3): the job passes with a warning, which is not a pixel-equivalence pass.
- Verifying the original goldens exactly requires a compatible environment. On one, any difference fails.

Results are reported as three separate lines (`EXACT_GOLDEN_EQUIVALENCE`, `RENDER_INTEGRITY`,
`CROSS_ENV_VISUAL_SANITY`); see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
