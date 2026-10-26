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

## The rendering engine

Status: **implemented, library only.** `CaptionRenderer` in the `FrameKitCaptions` Swift package renders
a validated caption input with a preset into transparent PNG frames. It needs nothing from any
particular video: the words, cues and times come from the input, the look from the preset, and which
frames to render from the caller. There is no command yet (see
[what is left](#what-is-left-before-a-command)).

```swift
import FrameKitCaptions

let preset = try CaptionPreset.load(contentsOf: URL(fileURLWithPath: "captions/presets/kinetic-minimal.json"))
let input = try CaptionInput.load(contentsOf: URL(fileURLWithPath: "my-video.input.json"))
let renderer = try CaptionRenderer(input: input, preset: preset)   // validates, checks the fonts
try renderer.writeFrames(to: URL(fileURLWithPath: "frames"))       // frames/0000.png, 0001.png, …
```

### How a frame is made

1. **Windows.** `CaptionRenderer(input:preset:)` resolves each cue's visible window with
   `CaptionInput.cueWindows(with:)` ([timing](caption-configuration.md#timing)); it throws the same errors
   for an input or preset with errors, and `CaptionRenderError.fontsUnavailable` when a font of the preset
   is not installed. Nothing is drawn until all of that holds.
2. **Sampling.** Frame `i` shows the instant `(i + 0.5) / canvas.fps`, the middle of the frame, as the
   reference did. A cue is in the frame when `start ≤ t ≤ end`; at both ends it is fully transparent.
3. **Description.** `renderer.frame(i)` is a `CaptionFrame`: per visible cue, its opacity and fade-in
   offset, and per word its text, font, size and colour, with every value resolved from the preset (fades,
   rise and emphasis as in [caption-configuration.md](caption-configuration.md#timing)). It can be
   inspected without drawing anything.
4. **Drawing.** The frame is drawn on a transparent canvas of `canvas.width` × `canvas.height` px, 8-bit
   RGBA, premultiplied, sRGB, with the same CoreText and CoreGraphics calls in the same order as the
   frozen renderer.
5. **PNG.** ImageIO with its default settings, which writes the same bytes as the reference's AppKit
   encoder: 8-bit RGBA, not interlaced, chunks `IHDR`, `sRGB`, `eXIf`, `IDAT`, `IEND`.

`frameCount` is one past the last frame that shows a cue; `writeFrames` writes frames `0..<frameCount`
by default, or any range given, every frame of the range, empty or not, as `NNNN.png` (the index, at
least four digits). Existing files with those names are replaced. When the video ends and how frames are
laid over it is up to the caller.

### Kept from the reference

Kept on purpose, because the reference look depends on them:

- the shadow is cast by the outline only; the fill is drawn on top without a shadow;
- outline with round joins and caps, then fill, word by word;
- words separated by one space of the text font, lines centred on `placement.x`, glyph outlines
  taken from the word's font;
- a cue whose opacity is 0.002 or less is not drawn;
- the shadow offset is handed to CoreGraphics, where y points up, so the preset's image-coordinate
  `shadow.dy` is negated (`-3` in `kinetic-minimal` draws as the reference's `3`).

What the reference hard-codes is configurable: the outline alpha (0.92 in `kinetic-minimal`), the shadow
colour (black), the centre (`placement.x`) and the canvas size.

### Differences and limits

- **Tracking** is added between consecutive glyphs of a word, counted over the whole word. The reference
  restarts the count at each CoreText glyph run and adds width per character, which differs only when
  tracking is not 0 and a word has several glyph runs or ligatures. No reference frame uses tracking.
- **Characters the font lacks.** CoreText lays them out with a fallback font, but, as in the reference,
  the outlines are taken from the preset's font, so such characters come out wrong. Fonts are never
  substituted; a check that refuses such text is tracked in
  [#22](https://github.com/RaioViajante/framekit/issues/22).
- **Not supported:** the reference's item and word `scale`, `glow`, and per-word offsets. Its frames use
  them only for the reference production's own `calm` and `shake` emphasis (frames 474 and 512), which
  are not part of `kinetic-minimal`. Measured on the goldens' environment, drawing those two frames
  without them changes 12,443 of the 24,463 pixels with ink in either image for frame 474 (the "calm"
  lift; 50.9 %) and 9,058 of 32,609 for frame 512 (the "shake" offsets; 27.8 %).
- **Concurrency.** CoreText asks the system font server for fonts over XPC, and lookups made at the same
  time from Swift concurrency's threads can wait forever (measured: 64 tasks creating fonts at the start
  of a process hung in 3 of 15 runs, and in 15 of 15 for a font that does not exist). Every font lookup
  of the library is therefore serialized; drawing itself is not.
- **Determinism.** The same frame on the same machine gives the same bytes (tested). Nothing is promised
  across macOS, Swift or font versions; see [regression-testing.md](regression-testing.md).

### Verification against the reference

Checked by `swift test` (`ReferenceFrameTests.swift`), reading the fixtures in place:

| Check | Frames | Where it applies |
|---|---|---|
| The fixture's frame items drawn by the engine are byte-identical to the frozen renderer's PNGs, both built and run on the same machine | 34, 51, 75, 118, 123, 430, 9999 | every environment |
| The same PNGs are byte-identical to the goldens | the same seven | only where the environment is the goldens' one (as decided by the regression runner); elsewhere the difference is printed as NOT VERIFIED |
| An input made from the frame's words with made-up times and `kinetic-minimal` give the fixture's item field by field, and the frozen renderer's bytes | 75, 123 (a cue at rest) | every environment |
| Frames 474 and 512 are named as unsupported, with the features they use | 474, 512 | every environment |

Frame 430 moves its cue 290 px left; the engine draws it with `placement.x` 250.

Measured once on the goldens' environment, outside the repository (the reference production's words
and frames are not part of it): with the production's words and cue groupings as a caption input, its
scene-end cuts as cue `end` overrides, and `kinetic-minimal`, the engine reproduced every one of the 532
frame items of its 15 cues without `calm` or `shake` field by field, all 533 frames of its 608-frame
history that do not contain those two cues byte for byte against the frozen renderer, and the goldens
34, 51, 75, 118, 123, 430 (with `placement.x` 250) and the empty frame byte for byte, end to end.

The frozen renderer reads frames with Foundation's `JSONSerialization`, which misreads some 17-digit
numbers by one or two units in the last place (`0.0012299562682223097` becomes `…093`). The engine
computes its values instead of reading them, and the tests read the fixture with the same parser as the
renderer, so both draw the same numbers. No golden is affected.

### What is left before a command

To render a new recording's captions with one command, still missing:
[#19](https://github.com/RaioViajante/framekit/issues/19) and
[#20](https://github.com/RaioViajante/framekit/issues/20) (a `framekit captions render` command with
explicit paths), [#22](https://github.com/RaioViajante/framekit/issues/22) (clear dependency and font
errors) and [#23](https://github.com/RaioViajante/framekit/issues/23) (a machine-readable report). The
words and their timestamps have to come from elsewhere: FrameKit does not transcribe or align audio.

## Proposed presets

Status: **partly implemented.** The preset and caption input documents now exist, with validation, the
`kinetic-minimal` preset and the rendering engine above: [caption-configuration.md](caption-configuration.md)
is their specification and wins where it is more precise than this page. The episode document,
overrides, `avoid-regions` placement and diagnostics are still the design below.

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
