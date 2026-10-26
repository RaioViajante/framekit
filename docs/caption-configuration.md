# Caption configuration

Status: **implemented, version 1.** The preset and caption input documents, their validation and the
`kinetic-minimal` preset exist in the Swift library `FrameKitCaptions`. Nothing renders from them yet:
the rendering engine and the `framekit` command are the next milestones (see the
[roadmap](../README.md#roadmap)). Why it is built this way:
[decision record 0001](decisions/0001-caption-configuration.md).

Two documents, both JSON with an integer `schema_version`:

| Document | Says | Example |
|---|---|---|
| caption preset | how captions look and move | [`captions/presets/kinetic-minimal.json`](../captions/presets/kinetic-minimal.json) |
| caption input | what the captions say and when | [`captions/examples/two-cues.input.json`](../captions/examples/two-cues.input.json) |

A preset never contains text, timestamps, scenes or anything else about a particular video. An input
never contains styling. Story, scenes, duration, pacing and sound stay with whoever makes the video.

Both documents follow the same rules: every field has one type, **unknown fields are errors** (a typo is
never ignored), and a `schema_version` newer than the library supports is refused. Adding a field is a
new `schema_version`; older versions keep being read.

## Preset contract

Every field is required except `description`. A preset has no hidden defaults: what it does is what it
says.

### Preset fields

| Field | Type | Allowed | Meaning |
|---|---|---|---|
| `schema_version` | integer | `1` | contract version |
| `preset_id` | string | lowercase words joined by hyphens | the preset's name; equals its file name |
| `preset_version` | string | `MAJOR.MINOR.PATCH` | version of this preset's look |
| `description` | string | optional | one or two sentences |
| `canvas.width` | integer | 1 to 16384 | frame width in px |
| `canvas.height` | integer | 1 to 16384 | frame height in px |
| `canvas.fps` | number | above 0, at most 240 | frames per second |
| `required_fonts` | array of strings | not empty, no repeats | PostScript names of exactly the fonts used ([fonts](#fonts)) |
| `text.font` | string | PostScript name | font of the caption text |
| `text.size` | number | above 0 | text size in px |
| `text.color` | colour | [colours](#colours) | text colour |
| `text.tracking` | number | any | extra px between glyphs |
| `text.line_height` | number | above 0 | px between baselines |
| `text.align` | string | `center`; `left` and `right` are reserved | alignment of each line |
| `text.max_lines` | integer | 1 or more | most lines a cue may have |
| `outline.width` | number | 0 or more | outline width in px |
| `outline.color` | colour | | outline colour |
| `outline.alpha` | number | 0 to 1 | outline opacity |
| `shadow.color` | colour | | shadow colour |
| `shadow.alpha` | number | 0 to 1 | shadow opacity |
| `shadow.blur` | number | 0 or more | blur radius in px |
| `shadow.dx` | number | any | px, positive moves the shadow right |
| `shadow.dy` | number | any | px, positive moves the shadow **down** |
| `placement.mode` | string | `fixed`; `avoid-regions` and `auto` are reserved | how the position is chosen |
| `placement.x` | number | 0 to `canvas.width` | horizontal centre of the lines |
| `placement.baseline_y` | number | 0 to `canvas.height` | baseline of the first line, px from the top |
| `timing.lead_in` | number | 0 or more | s a cue appears before its first word |
| `timing.hold` | number | 0 or more | s a cue stays after its last word |
| `timing.min_duration` | number | 0 or more | shortest time a cue is visible, s |
| `timing.min_gap` | number | 0 or more | s between a cut cue and the next one |
| `timing.overlap.fade_out` | number | 0 or more | fade-out of a cue that is cut short, s |
| `timing.overlap.word_margin` | number | 0 or more | s kept from word boundaries when cutting |
| `timing.overlap.min_visible` | number | 0 or more | s a cut cue stays before the cut |
| `animation.fade_in.duration` | number | 0 or more | s |
| `animation.fade_in.easing` | string | [easings](#easings) | |
| `animation.fade_in.rise` | number | any | px the cue rises into place (starts this much lower) |
| `animation.fade_out.duration` | number | 0 or more | s |
| `animation.fade_out.easing` | string | [easings](#easings) | |
| `emphasis_styles.<style>.font` | string | PostScript name | font of an emphasised word |
| `emphasis_styles.<style>.size` | number | above 0 | its size in px |
| `emphasis_styles.<style>.color` | colour | | its colour at full emphasis |
| `emphasis_styles.<style>.transition.duration` | number | 0 or more | s from text colour to emphasis colour |
| `emphasis_styles.<style>.transition.lead` | number | 0 or more | s the transition starts before the word |
| `emphasis_styles.<style>.transition.easing` | string | [easings](#easings) | |
| `emphasis_styles.<style>.transition.threshold` | number | 0 to 1 | progress after which `threshold` switches happen |
| `emphasis_styles.<style>.font_from` | string | `cue-start` or `threshold` | when the word takes the emphasis font |
| `emphasis_styles.<style>.size_from` | string | `cue-start` or `threshold` | when it takes the emphasis size |

`emphasis_styles` maps style names (lowercase words joined by hyphens) to styles. It may be empty.

"Reserved" values are known future options. They are refused with `option.unsupported` rather than
`value.invalid`, so they are not mistaken for typos.

### Colours

A colour is either `{"srgb": [r, g, b]}` with components from 0 to 1, or a string `"#rrggbb"`. The float
form keeps exact values: `kinetic-minimal` uses the floats of the reference, which are not the same
numbers as any hex colour. A hex colour is read as component / 255.

### Easings

`ease-out-cubic` is `1 - (1 - p)³`, `smoothstep` is `p² (3 - 2p)`, where `p` is the progress clamped to
0 to 1. A duration of 0 means the change is immediate.

### Timing

Times are seconds on the final video timeline. For each cue, with `s` the start of its first word and
`e` the end of its last word:

1. It is visible from `s - lead_in` to `max(e + hold, s - lead_in + min_duration)`, with the normal
   fade-out. A cue's own `start` or `end` (in the input) replaces the derived value.
2. Going through the cues in order, when a cue `A` would still be visible later than `min_gap` before
   the next cue `B` appears, `A` is cut: `cut = max(first word start of B + word_margin, start of A +
   min_visible)`; if the last word of `A` ends later than `cut - min_gap`, then
   `cut = last word end of A + word_margin`. `A` ends at `cut - min_gap` with the fade-out
   `overlap.fade_out`, and `B` starts no earlier than `cut` and no earlier than `min_gap` after `A` ends.

At an instant `t` in the visible window, `in = fade_in.easing((t - start) / fade_in.duration)` and
`out = fade_out.easing((end - t) / fade-out duration)`. The cue's opacity is `min(in, out)` and it is
drawn `rise × (1 - in)` px lower than its place: it rises while it fades in and does not move when it
fades out.

### Emphasis

An emphasised word changes from the text colour to the style's colour. Its progress is
`transition.easing((t - (word start - transition.lead)) / transition.duration)`, and its colour mixes the
two colours by that progress. Font and size switch from the text's to the style's either for the whole
time the cue is visible (`cue-start`) or once the progress is above `transition.threshold`
(`threshold`).

### Drawing

How a renderer draws a cue, as the frozen reference does: lines centred on `placement.x`, the first
baseline at `placement.baseline_y` and the next ones `line_height` lower, words separated by one space
of the text font. The outline is stroked with round joins and casts the shadow; the fill is drawn on
top without a shadow.

## The kinetic-minimal preset

[`captions/presets/kinetic-minimal.json`](../captions/presets/kinetic-minimal.json): light sans-serif
captions, at most two lines, a thin dark outline, a soft shadow, a short fade with a slight rise, and
emphasised words that turn into an italic serif and shift colour.

| Property | Value |
|---|---|
| canvas | 1080 × 1916 px, 24 fps |
| text | `AvenirNext-Medium` 54 px, colour `[0.9255, 0.9059, 0.8784]`, tracking 0, line height 66, centred, at most 2 lines |
| outline | 3.6 px, colour `[0.07, 0.035, 0.12]`, alpha 0.92 |
| shadow | black `[0, 0, 0]`, alpha 0.5, blur 10, offset 0, -3 (3 px **above** the text) |
| placement | fixed, centre x 540, first baseline 330 px from the top |
| timing | lead-in 0.06, hold 0.22, minimum 0.90, gap 0.02; when cut short: fade-out 0.08, word margin 0.03, at least 0.5 visible |
| fades | in 0.14 s `ease-out-cubic` rising 8 px; out 0.16 s `smoothstep` |
| emphasis `soft` | `Palatino-Italic` 58 px, colour `[0.7647, 0.702, 0.8784]`, transition 0.22 s `smoothstep` starting 0.02 s before the word; italic for the whole cue, 58 px once the transition passes 0.02 |

These are the **effective** values of the reference frames (see
[caption-rendering.md](caption-rendering.md)): what the frozen renderer actually drew, as exact floats.
Where the reference generator and renderer disagree, the renderer wins: the outline alpha is 0.92 because
the renderer hard-codes it. The shadow `dy` is `-3` because the preset uses image coordinates, where the
reference passed `3` to CoreGraphics, which moves a shadow up. The test suite checks each value against
the reference frames and the frozen renderer's source.

Left out on purpose: two emphasis styles and a hand-placed cue that belonged to the reference production,
and its decisions about text, timing and scenes.

Everything is configurable. To change the look, copy the file under a new `preset_id`
([adding a preset](#adding-a-preset)) and edit it, for example:

```json
"text": { "font": "Helvetica", "size": 60, "color": "#ffffff", "tracking": 0, "line_height": 72, "align": "center", "max_lines": 2 },
"required_fonts": ["Helvetica", "Palatino-Italic"],
"placement": { "mode": "fixed", "x": 540, "baseline_y": 1600 }
```

Overriding single fields per video without copying the preset is planned
([#5](https://github.com/RaioViajante/framekit/issues/5), [#6](https://github.com/RaioViajante/framekit/issues/6)).

## Input contract

### Input fields

| Field | Type | Allowed | Meaning |
|---|---|---|---|
| `schema_version` | integer | `1` | contract version |
| `language` | string | BCP 47 tag such as `en` or `pt-BR` | language of the text |
| `timing_source` | string | optional; `estimated` or `aligned` | where the timestamps come from |
| `words[].id` | string | not empty, unique | |
| `words[].text` | string | not empty, Unicode NFC, no whitespace | the word as shown, with its punctuation |
| `words[].start` | number | 0 or more | s on the final video timeline |
| `words[].end` | number | after `start` | s |
| `cues[].id` | string | not empty, unique | |
| `cues[].lines` | array of arrays of word ids | 1 to the preset's `text.max_lines` lines, none empty | the words of the cue, line by line |
| `cues[].emphasis.<word id>` | string | optional; a style the preset defines | emphasis style of one word of the cue |
| `cues[].start` | number | optional, 0 or more | replaces the derived visible start, s |
| `cues[].end` | number | optional, after `start` | replaces the derived visible end, s |

### Rules

- Words are listed in order of `start`.
- Line breaks come only from `lines`: nothing is reflowed or truncated. Within a cue, words appear in
  the order they are spoken; cues are listed in the order of their first words. Cues may overlap in time.
- A word belongs to at most one cue. A word in no cue is a warning, not an error.
- `…` is one character and stays one; text is compared in Unicode NFC.
- Emphasis applies only to words of the same cue, with a style name the preset defines.
- The line count and the style names depend on the preset, so they are checked when an input is
  validated against one (`CaptionInput.validate(against:)`).

## Fonts

Fonts are an explicit dependency. `required_fonts` lists exactly the fonts the preset uses: a used font
that is missing from the list, or a listed font that is not used, is an error. Whether the fonts are
installed is a separate check, because it depends on the machine and not on the document:
`FontAvailability.check` reports `font.unavailable` for a font that CoreText cannot resolve to exactly
that PostScript name. A missing font is never substituted, and no visual equivalence is assumed between
fonts.

`kinetic-minimal` needs `AvenirNext-Medium` and `Palatino-Italic`, which ship with macOS and are not
redistributed here.

## Validation

`CaptionPreset.validate`, `CaptionInput.validate` and `CaptionInput.validate(against:)` return every
issue at once, each with a stable code, a [JSON Pointer](https://www.rfc-editor.org/rfc/rfc6901) to the
offending place, a message and a severity. The same document always gives the same issues in the same
order. A document with any error yields no value; warnings do not block.

### Error codes

| Code | Severity | Meaning |
|---|---|---|
| `json.malformed` | error | the file is not JSON |
| `type.mismatch` | error | a value has the wrong type |
| `field.missing` | error | a required field is absent |
| `field.unknown` | error | a field the contract does not define |
| `value.out_of_range` | error | a number outside its range |
| `value.invalid` | error | a string that is not an allowed value or format |
| `option.unsupported` | error | a reserved option this version does not support |
| `schema.unsupported_version` | error | `schema_version` is newer than the library supports |
| `array.empty` | error | a list that must not be empty is |
| `id.duplicate` | error | an id or font listed twice |
| `font.undeclared` | error | a font is used but not in `required_fonts` |
| `font.unused` | error | a font in `required_fonts` is not used |
| `font.unavailable` | error | a required font is not installed |
| `preset.not_found` | error | no preset with that id in the presets directory |
| `preset.id_mismatch` | error | a preset file's name differs from its `preset_id` |
| `timing.invalid` | error | an end is not after its start |
| `timing.out_of_order` | error | words, words of a cue, or cues are out of time order |
| `text.not_normalized` | error | text is not Unicode NFC |
| `text.contains_whitespace` | error | a word contains whitespace |
| `word.unknown` | error | a cue refers to a word id that does not exist |
| `word.reused` | error | a word appears in more than one place |
| `word.unused` | warning | a word is in no cue and will not be shown |
| `cue.too_many_lines` | error | a cue has more lines than the preset allows |
| `emphasis.word_not_in_cue` | error | emphasis names a word outside its cue |
| `emphasis.unknown_style` | error | emphasis names a style the preset does not define |

Codes are never reused for another rule.

## Adding a preset

Presets are files. To add one:

1. Write `captions/presets/<preset_id>.json` following the [preset contract](#preset-contract). Starting
   from a copy of `kinetic-minimal.json` is the easy way.
2. Give it a new `preset_id`, equal to the file name, and `preset_version` `1.0.0`.
3. List its fonts in `required_fonts`.
4. Run `swift test`: every file in `captions/presets/` must validate, and the hygiene test keeps paths
   and production names out of it.

No code changes: `PresetCatalog` selects presets by id from the directory it is given. A preset needs new
code only if it needs something the contract cannot express, such as a new placement mode or emphasis
behaviour; that is a new `schema_version` and is designed in its own issue, not a plugin.

## Using the library

```swift
import FrameKitCaptions

let presets = PresetCatalog(directory: URL(fileURLWithPath: "captions/presets"))
let selected = presets.preset(id: "kinetic-minimal")
let input = CaptionInput.validate(try Data(contentsOf: URL(fileURLWithPath: "captions/examples/two-cues.input.json")))
var issues = selected.issues + input.issues
if let preset = selected.value {
    issues += FontAvailability.check(preset)
    if let captions = input.value { issues += captions.validate(against: preset) }
}
for issue in issues { print(issue) }
```

Paths are always passed in; the library does not look anywhere on its own.
