# Ti.FancyLabel

A Titanium iOS view that fades text in as it's inserted or updated — the
same effect used by ChatGPT/Claude-style chat UIs when a response streams
in token by token. Each word (or character) is drawn by its own
`CATextLayer`, positioned by TextKit's real line-breaking and revealed with
an explicit `CABasicAnimation` (see [Architecture](#architecture) below) —
pure UIKit, no SwiftUI, no external animation library.

Pairs naturally with `Ti.Network.Manager`: pipe each chunk your stream
callback receives straight into `appendText()`.

## Requirements

- iOS 13.0+. Set `<min-ios-ver>13.0</min-ios-ver>` (or higher) in your
  app's `tiapp.xml`.
- Titanium SDK 13.2.0.GA+.
- No third-party dependencies.

## Accessing the module

```js
import FancyLabel from 'ti.fancylabel';
```

## Creating a label

```js
const label = FancyLabel.createLabel({
  text: '',                    // starting text, shown fully opaque
  font: { fontSize: 16, fontWeight: 'semibold' },
  color: '#111111',
  textAlignment: 'left',       // 'left' | 'center' | 'right'
  granularity: 'word',         // 'word' | 'character'
  fadeDuration: 0.35,          // seconds each token takes to fade in
  fadeDelayStep: 0.02,         // seconds of stagger between tokens
  top: 20, left: 20, right: 20,
  height: Ti.UI.SIZE
});
win.add(label);
```

## Properties

| Property        | Type       | Default  | Notes                                              |
| ---------------- | ---------- | -------- | --------------------------------------------------- |
| `text`            | String     | `''`     | Read once at creation as the initial, static text.  |
| `font`            | Dictionary | system   | `{ fontFamily, fontSize, fontWeight }`.              |
| `color`           | String     | primary  | Hex color, e.g. `'#FFFFFF'`.                         |
| `textAlignment`   | String     | `'left'` | `'left'`, `'center'`, or `'right'`.                  |
| `granularity`     | String     | `'word'` | `'word'` or `'character'` — read on every append.    |
| `fadeDuration`    | Number     | `0.35`   | Fade-in duration per token, in seconds.              |
| `fadeDelayStep`   | Number     | `0.02`   | Stagger between consecutive tokens, in seconds.      |
| `lineSpacing`     | Number     | `0`      | Extra vertical gap between wrapped lines, in points. |
| `animationStyle`  | String     | `'fade'` | `'fade'`, `'scale'`, `'slide'`, or `'bounce'`.       |
| `markdown`        | Boolean    | `false`  | Parse `appendText()`/`setText()` input as Markdown.  |
| `accessibilityLabel` | String  | live text | VoiceOver label. Unset (the default) tracks the label's own current text live, like a real `UILabel`; set it explicitly to override. |
| `accessibilityAnnouncesOnComplete` | Boolean | `false` | Post a VoiceOver announcement with the final text when `complete()` runs. |
| `linkTapOpensURL` | Boolean | `true` | Tapping a markdown link opens it via `UIApplication.shared.open(_:)`. A `link` event fires either way — see [Events](#events). |
| `adjustsFontForContentSizeCategory` | Boolean | `false` | Scale `font` (and reflow existing text) to the user's Dynamic Type text-size setting — see [Dynamic Type](#dynamic-type). |

`granularity`, `fadeDuration`, `fadeDelayStep`, `lineSpacing`, and
`animationStyle` are re-read from the proxy on every `appendText()` call,
so you can change pacing/layout/style mid-stream. `markdown` is read on
every call too, but toggling it mid-message (after already streaming some
plain text into the same label) isn't supported — call `reset()` first if
you need to switch.

`lineSpacing` is implemented as a manual, per-line offset rather than
`NSParagraphStyle.lineSpacing` (see the Swift source's comment on the
`lineSpacing` property for the technical reason). Functionally it behaves
the same from JS: set it like any other property, e.g.
`FancyLabel.createLabel({ lineSpacing: 4, ... })`.

## Animation styles

`animationStyle` picks the `CAAnimation` shape each unit's reveal uses.
Every style still includes the opacity fade — `'scale'`, `'slide'`, and
`'bounce'` just add a second, grouped animation on top:

- `'fade'` (default) — opacity only, 0 → 1.
- `'scale'` — fades in while growing from 85% to 100% size.
- `'slide'` — fades in while sliding up ~6pt into its final position.
- `'bounce'` — fades in while scaling with a keyframed overshoot (grows
  past 100%, settles back) rather than a physics-based spring, so timing
  stays exact and doesn't need mass/stiffness/damping tuning.

```js
const label = FancyLabel.createLabel({
  animationStyle: 'bounce',
  granularity: 'word',
  ...
});
```

The extra animation always runs on `transform`, a `CALayer` property
that's fully independent from both `.opacity` (already owned by the
reveal) and `.frame`/`.position` (owned by `relayoutUnits()` — see
[Architecture](#architecture)).

## Markdown support

Set `markdown: true` and `appendText()`/`setText()` treat their input as
Markdown *source* instead of literal display text — syntax characters are
parsed and stripped, and the resulting styling (bold, italic, inline
code, code blocks, headers, blockquotes, links) is applied per word/
character using the same `CATextLayer` pipeline the rest of the label
already uses.

```js
const label = FancyLabel.createLabel({
  markdown: true,
  granularity: 'word',
  ...
});

networkManager.onChunk((chunk) => label.appendText(chunk)); // raw markdown source, streamed in
```

Built on Foundation's own `AttributedString(markdown:)` (iOS 15+) — no
dependency, and it already exposes both inline styling (bold/italic/code/
links) and block structure (headers/blockquotes/code blocks) per run. The
trade-off: `markdown: true` needs iOS 15+. On iOS 13/14 it silently falls
back to the same plain-text behavior as `markdown: false` (streamed
content still shows up, as literal, unparsed markdown syntax, rather than
being dropped).

Style mapping: **bold** and *italic* use the corresponding font trait;
`inline code` and fenced code blocks use the system monospaced font;
headers (`#` through `######`) get progressively larger, bold text; `>`
blockquotes get a dimmed color; links get a distinct color. There's no
underline for links, and no visual left-border bar for blockquotes — both
would need each `CATextLayer` to render an `NSAttributedString` instead of
a plain `String`, which this label doesn't do (see
[Known limitations](#known-limitations)). Ordered/unordered lists parse,
but their markers aren't specially indented — they render as regular
wrapped text.

Because markdown source can arrive split across chunks in the middle of a
token (e.g. `"This is **b"` then `"old** text"`), the label re-parses the
*entire* accumulated raw source on every `appendText()` call, not just the
new chunk, and corrects the style of any already-displayed text whose
resolved styling changed as a result (an instant font/color swap — never
a re-reveal, never a position jump for its own sake). What it does *not*
handle: the rarer case where the resolved *plain text itself* changes
retroactively, not just its styling (see
[Known limitations](#known-limitations)).

## Tap-to-open links

Tapping a markdown link fires a `link` event (`{ url, text }` — see
[Events](#events)) and, by default, opens the URL in the system browser
via `UIApplication.shared.open(_:)`. Set `linkTapOpensURL: false` if you'd
rather handle it entirely yourself (e.g. open an in-app browser, navigate
within your own app) — the event still fires either way, only the
automatic `open(_:)` call is skipped.

```js
const label = FancyLabel.createLabel({ markdown: true, ... });

label.addEventListener('link', (e) => {
  console.log('tapped link:', e.url, e.text);
});

// To handle links entirely yourself instead of also opening the browser:
// label.linkTapOpensURL = false;
```

Implemented with a single `UITapGestureRecognizer` on the whole label,
hit-testing the tap point against each unit's own `layer.frame` — the
same frame `relayoutUnits()` already keeps current. A tap that doesn't
land on a link-carrying unit is a no-op.

## Accessibility (VoiceOver)

Every unit of visible text is a bare `CATextLayer`, not a `UILabel` or
`UITextView` — `CALayer`s aren't accessibility elements on their own, so
without any extra work VoiceOver would skip straight over the whole label
and announce nothing. `Ti.FancyLabel` handles this automatically: the
label itself is marked as one accessibility element, and its
`accessibilityLabel` tracks the label's own current text live, the same
way a real `UILabel`'s default `accessibilityLabel` is its own `.text`.
Nothing extra needs to be set for a screen-reader user to hear whatever's
currently displayed — including with `markdown: true`, where the
announced text is the parsed, syntax-stripped plain text (no literal
`**`/`#`/etc.), matching what a sighted user sees.

```js
const label = FancyLabel.createLabel({ ... });
// No accessibilityLabel needed - VoiceOver reads the label's own text,
// updated live as appendText()/setText() run.

// Override it explicitly if you want VoiceOver to say something different
// from what's visually displayed:
label.accessibilityLabel = 'Assistant is typing a response';
```

The accessible text reflects whatever's logically been appended so far,
not just the portion whose fade-in animation has visually finished — the
reveal is a cosmetic detail of *how* text arrives, and gating VoiceOver on
it would make a screen-reader user wait on an animation a sighted user
doesn't have to.

The label's `accessibilityTraits` include `.updatesFrequently`, which
tells VoiceOver this element's value can change on its own (as
`appendText()` streams in) without the user having done anything — per
Apple's own accessibility docs, VoiceOver then does *not* auto-announce
every such change, so a streaming bubble doesn't interrupt the user with a
new announcement per word. The user can still swipe to the label at any
point and hear whatever's current then.

Set `accessibilityAnnouncesOnComplete: true` if you also want an explicit
VoiceOver announcement (`UIAccessibility.post(.announcement, ...)`) fired
with the final text once a message finishes streaming — the VoiceOver
equivalent of a chat bubble "arriving". Off by default, since forcing an
interruption for every completed message (e.g. several bubbles streaming
in close succession) can be more disruptive than helpful — it's left as a
per-label opt-in for the app author to decide.

Known gap: markdown links aren't individually exposed to VoiceOver as
separate `.link`-trait elements (the whole label is one accessibility
element, so a link inside it is announced as part of the surrounding text,
and its tap gesture — see [Tap-to-open links](#tap-to-open-links) —
doesn't fire from a VoiceOver double-tap, only an ordinary sighted/touch
tap).

## Dynamic Type

Set `adjustsFontForContentSizeCategory: true` and the label's `font`
tracks the user's Settings → Accessibility → Larger Text preference,
using `UIFontMetrics` to scale whatever `fontSize`/`fontFamily`/
`fontWeight` you configured — not just the system's fixed text styles.
Off by default, matching `UILabel.adjustsFontForContentSizeCategory`'s own
default, so an existing label's rendering doesn't change unless you opt
in.

```js
const label = FancyLabel.createLabel({
  adjustsFontForContentSizeCategory: true,
  font: { fontSize: 16 },
  ...
});
```

Applied immediately at creation if the user already has a non-default
text size, and again any time `UIContentSizeCategory.didChangeNotification`
fires (the user changes the setting while the app is running). When it
fires, every already-displayed unit — including markdown-styled ones
(bold, headers, code, …) — is rescaled proportionally to the same new
base size, not just newly-appended text, then the label reflows.
Toggling `adjustsFontForContentSizeCategory` itself at runtime (rather
than the OS text-size setting changing) doesn't retroactively trigger a
rescale — it only takes effect at creation or on the next actual
OS-level text-size change.

## Methods

### `appendText(chunk)`

Appends `chunk` to the label and fades it in according to `granularity`.
This is the method you call from your streaming callback:

```js
networkManager.onChunk((chunk) => {
  label.appendText(chunk);
});
```

If a previous chunk is still mid-fade when a new one arrives, it keeps
fading on its own independent timer — nothing is cancelled or folded in
early. New chunks queue onto the same left-to-right reveal sweep instead
of restarting it, so fast streaming falls behind visually rather than
skipping ahead of not-yet-revealed text.

With `markdown: true`, `chunk` is treated as raw Markdown source rather
than literal text — see [Markdown support](#markdown-support) above.

### `setText(text)`

Replaces the entire label instantly, with no animation. Useful to prime
the label with content that's already complete (e.g. restoring a
previously-streamed message from history). With `markdown: true`, `text`
is parsed as a complete Markdown document rather than shown literally.

### `reset()`

Clears the label and cancels any in-flight fade. Call this before starting
a new streamed message on a reused label instance.

### `complete()`

Immediately finishes any in-flight fade (folds the pending chunk in at
full opacity, cancels the timer). Call this when your stream ends, so
nothing is left visually half-faded if the app backgrounds mid-animation.

## Events

### `link`

Fires when a markdown link is tapped — see
[Tap-to-open links](#tap-to-open-links). Payload:

| Property | Type   | Description                          |
| -------- | ------ | ------------------------------------- |
| `url`    | String | The link's target URL, as a string.  |
| `text`   | String | The tapped unit's own display text.  |

```js
label.addEventListener('link', (e) => {
  console.log(e.url, e.text);
});
```

## Usage — streaming from Ti.Network.Manager

```js
import FancyLabel from 'ti.fancylabel';
import NetworkManager from 'ti.network.manager';

const win = Ti.UI.createWindow({ backgroundColor: '#fff' });

const label = FancyLabel.createLabel({
  granularity: 'word',
  fadeDuration: 0.3,
  fadeDelayStep: 0.03,
  top: 40, left: 20, right: 20,
  height: Ti.UI.SIZE
});
win.add(label);
win.open();

label.reset();

NetworkManager.stream({
  url: 'https://api.example.com/chat',
  onChunk: (chunk) => label.appendText(chunk),
  onDone: () => label.complete()
});
```

## Architecture

Pure UIKit/TextKit/Core Animation — no SwiftUI, no `UIHostingController`.

- **Layout & sizing** are computed by TextKit
  (`NSTextStorage`/`NSLayoutManager`/`NSTextContainer`) — the same real,
  CoreText-backed typesetter `UILabel`/`UITextView` use, not a hand-rolled
  approximation. `usedRect(for:)` is, by construction, exactly what the
  live layout wraps to, and it gets bidi/RTL line geometry correct for
  free.
- **Rendering** is one `CATextLayer` per reveal unit (word, or character
  for `granularity:"character"`), positioned at the exact glyph bounding
  rect TextKit computed for it.
- **Revealing** a unit adds an explicit `CABasicAnimation` for its
  opacity, so every reveal runs the same way regardless of when the layer
  was first painted.
- **Resizing** only ever touches layer *position* (inside a
  `CATransaction` with actions disabled, so the move itself doesn't
  implicitly animate) — never `.opacity`. Position and opacity are fully
  independent `CALayer` properties changed by fully independent code
  paths, so a resize triggered by a sibling label elsewhere in a shared
  `ScrollView` cannot interrupt or corrupt this label's own in-flight
  reveal, or vice versa.
- **Measuring** (`contentWidthForWidth:`/`contentHeightForWidth:`) uses a
  throwaway `NSLayoutManager`/`NSTextContainer` temporarily attached to
  the same `NSTextStorage` the live layer tree reads from — a pure,
  synchronous computation that never touches the live, on-screen
  `CATextLayer` tree at all.
- The left-to-right reveal sweep is staggered by each unit's position in
  the *logical* string order (also the writing order, including for
  right-to-left scripts) rather than per-glyph screen geometry. TextKit's
  own line-*placement* geometry handles bidi/RTL correctly regardless.

## Known limitations

- `markdown: true` requires iOS 15+ (`AttributedString(markdown:)` isn't
  available earlier). On iOS 13/14 it silently falls back to plain-text
  behavior — the module's overall `13.0` deployment target is unaffected,
  only this one property has a higher floor.
- Streamed Markdown can retroactively *restyle* already-displayed text
  (handled — see [Markdown support](#markdown-support)), but not
  retroactively *change the plain text itself*. In practice this means an
  unclosed token at the very end of the current chunk (e.g. a trailing
  lone `*` or an opening `` ` `` with no matching close yet) can briefly
  render as its literal character before resolving into styled text once
  the closing token arrives.
- Markdown links are colored but not underlined, and blockquotes get a
  dimmed color but no left-border bar — both would need each `CATextLayer`
  to render an `NSAttributedString` rather than a plain `String`, which
  this label doesn't do.
- No text selection is implemented (long-press to select, drag handles,
  copy) — `CATextLayer` has no built-in text interaction the way
  `UITextView`/`UILabel` do.
- VoiceOver support (see [Accessibility](#accessibility-voiceover)) covers
  the label as a whole — it reads live, always-current text and supports
  an explicit override or a completion announcement — but markdown links
  aren't individually navigable/announced as `.link`-trait elements, and
  there's no per-character/per-word granularity for VoiceOver's
  text-navigation gestures.
- Dynamic Type (see [Dynamic Type](#dynamic-type)) rescales the base font
  and every existing unit proportionally, but toggling
  `adjustsFontForContentSizeCategory` itself at runtime doesn't
  retroactively trigger a rescale — only creation time and an actual
  OS-level text-size change do.
- `markdown: true` combined with long messages (especially ones with
  fenced code blocks or many short emphasis runs) can meaningfully
  increase the number of `CATextLayer` sublayers per label, since a run
  boundary from markdown parsing can split what would otherwise be one
  reveal unit into more of them. Worth a performance pass if you expect
  long/heavily formatted streamed messages, rather than short chat-style
  ones.
- Hyphenation (breaking a word with a `-` across a line instead of moving
  it whole to the next line) is not implemented.
  `NSLayoutManager.hyphenationFactor` is the API to reach for if this is
  ever needed.
- An extremely long unbreakable "word" (no spaces, wider than the
  container and impossible to wrap without hyphenation) may cause
  TextKit to break it mid-word on its own, in which case the reveal
  unit's glyph range spans that forced break and
  `boundingRect(forGlyphRange:in:)` returns a union box across both
  fragments — an edge case, not expected for normal chat text.
- If you use `Ti.FancyLabel` inside a `ScrollView`, remember that Titanium
  ScrollViews (like most native scroll views) need their own `contentSize`
  informed by the children's layout — the label reports its real height
  via `contentHeightForWidth:`, but if content still looks clipped, check
  that the ScrollView's `layout` is `'vertical'` and that it isn't also
  given a fixed `height` that overrides its own auto-sizing.
- `font`/`color`/`textAlignment` are read once, at creation — there's no
  dedicated setter to change them live on an existing label instance
  (streaming text via `appendText()` does update live, that's the whole
  point).
