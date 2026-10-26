# Provenance and licensing

## What the MIT license covers

[`LICENSE`](../LICENSE) (MIT) covers **source code and documentation** in this repository:

- `captions/tests/*.py`, `captions/tests/*.swift` and the GitHub Actions workflow;
- `captions/reference/render_caps.swift` (see below);
- `README.md` and the files under `docs/`.

## What the MIT license does NOT cover

Everything listed here is excluded from the MIT grant:

- `captions/tests/fixtures/ep001/golden/*.png` (the golden images);
- `captions/tests/fixtures/ep001/frames.json` and any other visual fixture derived from EP001;
- any original artistic asset (artwork, typography treatment, caption design, audio, video, music,
  sound effects) now or later added to the repository.

No rights in these items are granted by `LICENSE`. They are published only so that this repository's
regression tests can be run. Do not reuse, redistribute or build derivative works from them outside
running or reviewing those tests without the owner's written permission. The owner may replace this
paragraph with a more permissive grant; until then it is the rule.

## Provenance of the EP001 visual references

- The nine golden PNGs were rendered by `captions/reference/render_caps.swift` from `frames.json`, on
  the environment recorded in `captions/tests/fixtures/ep001/manifest.json`.
- `frames.json` holds nine frame objects selected from the frames file used for the EP001 RC1 caption
  render (caption text and style parameters only). Hashes of the original EP001 source files are
  recorded in the manifest (`provenance.origin_files_sha256`).
- The caption design (layout, colors, typography choices, animation) belongs to the Raioviajando
  EP001 project. No audio, video, music, SFX or personal data is included.

## Third-party components

- **Fonts.** The goldens contain glyphs rasterized from Apple's macOS system fonts (Avenir Next and
  Palatino). The fonts are **not** distributed here and their license terms were **not** reviewed.
  Nothing in this repository asserts ownership of, or any license to, those typefaces.
- **Apple frameworks** (AppKit, CoreText, CoreGraphics) and the Swift toolchain are used at build/run
  time and are not distributed here.
- No third-party source code or assets are vendored. If any are added later, they must be listed here
  with their own license.

## Open point for the owner

`captions/reference/render_caps.swift` was written for the EP001 project and is included under MIT on
the understanding that the repository owner is its sole author/rights holder. No evidence of
conflicting third-party rights was found while preparing this repository, but this was not
independently verified. The owner should confirm that statement.
