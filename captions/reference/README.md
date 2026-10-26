# Legacy / reference caption renderer

`render_caps.swift` is the CoreText/CoreGraphics renderer used to produce the EP001 captions
(v2 "kinetic" version). It is **frozen**: the file is a byte-for-byte copy of
`EP001-Eu-Tenho-Um-Problema/Video/Final/source/render_caps.swift`
(SHA-256 `02b9f9ef646aa2e7d83a43d2b13682effcc3840c7026b8a23b23970574cc4f59`).

Do not edit it. It exists as the reference against which the rendering engine
(`Sources/FrameKitCaptions/`, see `docs/caption-rendering.md`) is compared.
Any change would invalidate the golden frames and requires a dedicated PR (see `docs/regression-testing.md`).

Usage: `render_caps frames.json out_dir` writes one 1080x1916 RGBA PNG per frame (`%04d.png`).

Known quirks, kept on purpose because the approved EP001 look depends on them:

- Shadow offset is passed straight to `CGContext.setShadow`, so a **positive `shadow_dy` moves the
  shadow up** in the image (measured). EP001 used `shadow_dy = 3`, i.e. 3 px above the text.
  A future preset will express this in image coordinates (positive = down), equivalent value `-3`.
- The shadow is applied to the outline stroke only, not to the fill.
- The outline is drawn with a fixed alpha of 0.92; an `outline_alpha` of 0.85 in the EP001 generator
  is never read.
- The defaults for missing shadow fields (5 / 16 / 0.62) come from the older v1 renderer; EP001
  frames always provide the shadow fields explicitly (3 / 10 / 0.50).
