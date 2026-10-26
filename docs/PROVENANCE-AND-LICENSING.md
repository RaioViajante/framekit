# Provenance and licensing

Binding scope and terms: [../NOTICE.md](../NOTICE.md). This document records provenance and what was
and was not verified. It does not add rights.

## Classification (summary)

- **MIT** ([LICENSE](../LICENSE), unmodified standard text): source code, documentation and the test
  metadata file `manifest.json`.
- **Not MIT, limited permission**: `captions/tests/fixtures/ep001/golden/*.png` and
  `captions/tests/fixtures/ep001/frames.json`. Recipients may download, clone, fork, copy and
  reproduce them, and make temporary modified or derived copies, solely as needed to execute,
  reproduce and verify this repository's own regression tests. No broader reuse right is granted.
- The two `NOTICE.md` files are documentation under MIT that carry the conditions for the fixtures.

## Provenance of the EP001 visual references

FrameKit is an independent toolkit. Its first regression baseline was taken from an existing
production, the video EP001, "Eu Tenho Um Problema" (Raioviajando). That title is published
information and is kept as provenance metadata in `manifest.json`; it is not a brand of this project.

- The nine golden PNGs were rendered by `captions/reference/render_caps.swift` from `frames.json`, on
  the environment recorded in `captions/tests/fixtures/ep001/manifest.json`.
- `frames.json` holds nine frame objects selected from the frames file used for the EP001 RC1 caption
  render (caption text and style parameters only). SHA-256 hashes of the original source files are
  recorded in the manifest (`provenance.origin_files_sha256`) so the selection can be traced.
- No audio, video, music, SFX or personal data is included.

## Authorship and rights: what is and is not verified

- `captions/reference/render_caps.swift` originated in the workflow of that production and is copied
  byte for byte.
- This repository makes no statement that the authorship of any file, or any third-party right, has
  been independently verified.
- The MIT license applies to the files classified as MIT in [NOTICE.md](../NOTICE.md). No third-party
  source code is known to be included; no audit was performed.

## Third-party components

- **Typefaces.** The goldens contain text rendered with Avenir Next and Palatino as provided by
  macOS. No font files are distributed here. This repository claims no rights in those typefaces and
  grants no license to them; the terms governing such use were not reviewed.
- **Apple frameworks** (AppKit, CoreText, CoreGraphics) and the Swift toolchain are used at build/run
  time and are not distributed here.
- If third-party code or assets are ever added, they must be listed here with their own terms.
