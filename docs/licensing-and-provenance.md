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
- **Not MIT, all rights reserved**: `assets/brand/framekit-sticker.png`, the project's sticker.
- The three `NOTICE.md` files are documentation under MIT that carry the conditions for the fixtures and the
  artwork.

## Provenance of the EP001 visual references

FrameKit is an independent toolkit. Its first regression baseline was taken from an existing
production, the video EP001, "Eu Tenho Um Problema" (Raioviajando). That title is published
information and is kept as provenance metadata in `manifest.json`; it is not a brand of this project.

- The nine golden PNGs were rendered by `captions/reference/render_caps.swift` from `frames.json`, on
  the environment recorded in `captions/tests/fixtures/ep001/manifest.json`.
- `frames.json` holds nine frame objects selected from the frames file used for the EP001 RC1 caption
  render (caption text and style parameters only). SHA-256 hashes of the original source files are
  recorded in the manifest (`provenance.origin_files_sha256`) so the selection can be traced.
- No audio, video, music, SFX or personal data is included in the fixtures.

## Provenance of the sticker

`assets/brand/framekit-sticker.png` (1254 × 1254 px, 8-bit RGBA, transparent background, about 1.7 MB)
was supplied by the repository owner and is stored byte for byte as supplied. It contains an embedded
C2PA manifest (Content Credentials) recording that:

- it was created with ChatGPT's image generation (`gpt-image`, via the OpenAI Media Service);
- the creation time was 2026-10-26T02:29:08Z (UTC);
- its digital source type is `trainedAlgorithmicMedia`, that is, AI-generated media.

The manifest is bound to the file's bytes, so the image is not recompressed, resized or otherwise
optimized. This repository does not determine who holds rights in AI-generated imagery and does not
assert it; the terms that apply are in [../NOTICE.md](../NOTICE.md) and
[../assets/brand/NOTICE.md](../assets/brand/NOTICE.md).

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
