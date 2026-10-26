# Caption rendering

## The reference renderer

`captions/reference/render_caps.swift` is a frozen copy of the renderer used by the source production
(see [licensing-and-provenance.md](licensing-and-provenance.md)). It is a legacy/reference implementation:
it is kept exactly as it was so that anything that replaces it can be compared against what actually
shipped. Its known quirks are listed in [../captions/reference/README.md](../captions/reference/README.md).

```sh
mkdir -p build
swiftc -O captions/reference/render_caps.swift -o build/render_caps
build/render_caps captions/tests/fixtures/ep001/frames.json build/frames
```

This is what the regression runner does in a temporary directory; running it by hand is only needed for
experiments. `build/` is ignored by Git.

### Input: `frames.json`

```
{ "frames": [ { "index": <int>, "items": [ <item>, … ] }, … ] }
```

One PNG `out_dir/%04d.png` is written per frame, 1080×1916 px, 8-bit RGBA, transparent background. An item
is one caption cue at one instant. Items are drawn in order; an item with `alpha ≤ 0.002` is skipped.

| Item field | Meaning |
|---|---|
| `font`, `size` | base PostScript font name and size in px |
| `stroke`, `outline` | outline width in px and its `[r, g, b]` colour (floats 0 to 1) |
| `alpha` | opacity of the whole item (fades) |
| `dy`, `scale` | vertical offset in px and uniform scale of the item |
| `y_base`, `line_height`, `cx` | baseline of the first line, line spacing, horizontal centre (default half the canvas) |
| `tracking` | extra spacing in px (optional) |
| `shadow_dy`, `shadow_blur`, `shadow_alpha` | shadow parameters (optional; see the quirks) |
| `lines` | list of lines, each a list of runs |

A run is `{ "text", "color": [r, g, b] }` plus optional `font`, `size`, `scale`, `glow`, `dx` and `dy`
overrides, which is how emphasis words use another font, colour, size or offset.

A frame file that omits the shadow fields falls back to values that belong to an older version of the
renderer; the frames in the fixtures always provide them.

## Proposed presets

Status: **a design, not implemented.** Nothing in the repository reads or writes a preset yet. The
decisions below were approved before any code exists.

**Goal.** Make the caption look of the reference production reusable and configurable, and nothing
else. Story, scenes, duration, pacing, sound and animation style are never part of a preset.

**Reference defaults** (measured from the frames the goldens come from): Avenir Next Medium 54 px for
the body, Palatino Italic 58 px for selected emphasis words, off-white `#ece7e0` and lilac `#c3b3e0`, up
to two lines, a thin dark outline with a soft shadow, fade-in 0.14 s with a slight rise and fade-out
0.16 s, cues starting 0.06 s before the first word and ending 0.22 s after the last, at least 0.9 s long.

**Three document types, versioned with `schema_version`:**

| Document | Purpose |
|---|---|
| `caption-preset.json` | typography, colours, outline, shadow, layout, timing, animation, diagnostics |
| `caption-episode.json` | which preset, input and output paths, overrides, optional scenes |
| `caption-input.json` | words with timestamps, cues (explicit line breaks) and emphasis |

**Precedence:** preset, then episode, then scene, then cue. Objects merge field by field, scalars
replace, lists replace whole, a missing field inherits and `null` does not mean "remove".

**Placement:** `fixed` first; `avoid-regions` as an option, with regions supplied by hand per scene;
`auto` reserved and refused by the first renderer. No automatic object detection.

**Shadow:** `shadow.dy` will use image coordinates (positive means down). The reference renderer
passes the offset straight to CoreGraphics, where a positive value moves the shadow *up*; the
reference look therefore corresponds to `-3`, and the renderer will translate the sign without
changing the appearance.

**Diagnostics** for collisions, contrast and safe zones are warnings and never block rendering. A
font that cannot be resolved aborts rendering instead of being substituted, and no visual equivalence
is assumed between different fonts.

**Left out on purpose:** the `calm` and `shake` emphasis styles of the reference production stay with
that production; custom emphasis styles are a possible future extension.

**Output:** one PNG RGBA per frame plus a validation report.

**Verification:** a renderer built from presets must first reproduce the frozen reference frames
pixel for pixel on a compatible environment; any difference is investigated and recorded, never
accepted silently. See [regression-testing.md](regression-testing.md).
