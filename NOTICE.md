# NOTICE

This file states which parts of this repository are under the MIT license (see [LICENSE](LICENSE))
and the separate, limited terms that apply to the EP001 visual fixtures. Details and provenance:
[docs/PROVENANCE-AND-LICENSING.md](docs/PROVENANCE-AND-LICENSING.md).

## Classification

| Category | Files | Terms |
|---|---|---|
| **A. Source code** | `captions/reference/render_caps.swift`, `captions/tests/*.py`, `captions/tests/*.swift`, `.github/workflows/*`, `.gitattributes`, `.gitignore` | MIT |
| **B. Documentation** | `README.md`, `docs/*.md`, `captions/reference/README.md`, this `NOTICE.md` and `captions/tests/fixtures/ep001/NOTICE.md` | MIT. The two NOTICE files state the conditions for category C and must accompany any copy of those files |
| **C. Golden PNGs and artistic fixtures** | `captions/tests/fixtures/ep001/golden/*.png`, `captions/tests/fixtures/ep001/frames.json` | **Not MIT.** Only the limited permission below |
| **D. Test metadata** | `captions/tests/fixtures/ep001/manifest.json` (hashes, dimensions, environment, provenance notes; no artistic content) | MIT |

`LICENSE` is the unmodified standard MIT license text and applies to categories A, B and D.

## Limited permission for category C

Any recipient of this repository may download, clone, fork, copy and reproduce the category C files,
**unmodified**, solely as needed to execute, reproduce and verify this repository's regression tests,
provided the NOTICE files accompany them.

No other right is granted. In particular there is no right to use, adapt, modify, redistribute
separately or exploit these files as artistic material, or to use them in other works. This permission
does not extend to any EP001 video, audio or other asset, none of which is included here. All other
rights in category C are reserved, to the extent they are held by the repository owner.

## Third-party components

- No font files are included. The golden PNGs contain text rendered with typefaces provided by macOS
  (Avenir Next and Palatino). This repository claims no rights in those typefaces and grants no
  license to them; the terms that govern such use were not reviewed.
- Apple frameworks and the Swift toolchain are used at build/run time and are not distributed here.
- No third-party source code or assets are known to be included; no audit was performed.
