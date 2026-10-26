# NOTICE

FrameKit. This file states which parts of this repository are under the MIT license (see [LICENSE](LICENSE))
and the separate terms that apply to the EP001 visual fixtures and to the artwork. Details and provenance:
[docs/licensing-and-provenance.md](docs/licensing-and-provenance.md).

## Classification

| Category | Files | Terms |
|---|---|---|
| **A. Source code** | `captions/reference/render_caps.swift`, `captions/tests/*.py`, `captions/tests/*.swift`, `.github/workflows/*`, `.gitattributes`, `.gitignore` | MIT |
| **B. Documentation** | `README.md`, `docs/*.md`, `captions/reference/README.md`, this `NOTICE.md`, `captions/tests/fixtures/ep001/NOTICE.md` and `assets/brand/NOTICE.md` | MIT. The NOTICE files state the conditions for categories C and E and must accompany any copy of those files |
| **C. Golden PNGs and artistic fixtures** | `captions/tests/fixtures/ep001/golden/*.png`, `captions/tests/fixtures/ep001/frames.json` | **Not MIT.** Only the limited permission below |
| **D. Test metadata** | `captions/tests/fixtures/ep001/manifest.json` (hashes, dimensions, environment, provenance notes; no artistic content) | MIT |
| **E. Artwork** | `assets/brand/framekit-sticker.png` | **Not MIT.** All rights reserved to the extent held by the repository owner; see below and `assets/brand/NOTICE.md` |

`LICENSE` is the unmodified standard MIT license text and applies to categories A, B and D only.

## Limited permission for category C

Any recipient of this repository may download, clone, fork, copy and reproduce the category C files,
and may make **temporary modified or derived copies** of them, solely as needed to execute, reproduce
and verify this repository's own regression tests (including the tests that deliberately alter copies
to check failure handling). The NOTICE files must accompany the unmodified originals. Temporary
copies must not be retained, published or used for any other purpose.

No other right is granted. In particular there is no right to use, adapt, redistribute separately or
exploit these files as artistic material, or to use them in other works. This permission does not
extend to any video, audio or other asset of the source project, none of which is included here. All
other rights in category C are reserved, to the extent they are held by the repository owner.

## Category E: the sticker

All rights in `assets/brand/framekit-sticker.png` are reserved, to the extent they are held by the
repository owner. It may be viewed as part of this repository, including the README as rendered by
GitHub, and is copied unmodified only as an unavoidable part of cloning or forking. No other right is
granted. The file embeds Content Credentials stating that it was created with ChatGPT's image
generation; who holds rights in such imagery was not determined here and is not asserted. Details:
[assets/brand/NOTICE.md](assets/brand/NOTICE.md).

## Third-party components

- No font files are included. The golden PNGs contain text rendered with typefaces provided by macOS
  (Avenir Next and Palatino). This repository claims no rights in those typefaces and grants no
  license to them; the terms that govern such use were not reviewed.
- Apple frameworks and the Swift toolchain are used at build/run time and are not distributed here.
- No third-party source code or assets are known to be included; no audit was performed.
