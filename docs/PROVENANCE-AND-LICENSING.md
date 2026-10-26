# Provenance and licensing

Binding scope and terms: [../NOTICE.md](../NOTICE.md). This document records provenance and what was
and was not verified. It does not add rights.

## Classification (summary)

- **MIT** ([LICENSE](../LICENSE), unmodified standard text): source code, documentation and the test
  metadata file `manifest.json`.
- **Not MIT, limited permission**: `captions/tests/fixtures/ep001/golden/*.png` and
  `captions/tests/fixtures/ep001/frames.json`. Recipients may download, clone, fork, copy and
  reproduce them unmodified, solely as needed to execute, reproduce and verify this repository's
  regression tests. No broader reuse right is granted.
- The two `NOTICE.md` files are documentation under MIT that carry the conditions for the fixtures.

## Provenance of the EP001 visual references

- The fixtures relate to the video EP001, "Eu Tenho Um Problema". That title is published
  information and is kept as metadata in `manifest.json`.
- The nine golden PNGs were rendered by `captions/reference/render_caps.swift` from `frames.json`, on
  the environment recorded in `captions/tests/fixtures/ep001/manifest.json`.
- `frames.json` holds nine frame objects selected from the frames file used for the EP001 RC1 caption
  render (caption text and style parameters only). SHA-256 hashes of the original EP001 source files
  are recorded in the manifest (`provenance.origin_files_sha256`) so the selection can be traced.
- No audio, video, music, SFX or personal data is included.

## Authorship and rights: what is and is not verified

- `captions/reference/render_caps.swift` originated in the EP001 workflow and is copied byte for byte.
- This repository has **not independently verified** the authorship of any file or the rights of any
  contributor, and makes no claim beyond what is stated here.
- The MIT grant is made by the repository owner (the account named in `LICENSE`), who is responsible
  for having the right to make it. No third-party source code is known to be included; no audit was
  performed.

## Third-party components

- **Typefaces.** The goldens contain text rendered with Avenir Next and Palatino as provided by
  macOS. No font files are distributed here. This repository claims no rights in those typefaces and
  grants no license to them; the terms governing such use were not reviewed.
- **Apple frameworks** (AppKit, CoreText, CoreGraphics) and the Swift toolchain are used at build/run
  time and are not distributed here.
- If third-party code or assets are ever added, they must be listed here with their own terms.
