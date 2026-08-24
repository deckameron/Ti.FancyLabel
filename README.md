# Ti.FancyLabel

> Fade in streamed text — word by word or character by character — the same way ChatGPT- and Claude-style chat UIs reveal a response as it arrives.

A Titanium iOS module that gives you a single view, `Ti.FancyLabel.createLabel({...})`, purpose-built for animated, incrementally-revealed text. Pair it with `Ti.Network.Manager` (or any streaming/SSE client) to pipe tokens straight into `label.appendText(chunk)` as they arrive, or use `setText()` for an instant, non-animated update.

![Titanium SDK](https://img.shields.io/badge/Titanium%20SDK-13.2.0.GA%2B-blue)
![Platform](https://img.shields.io/badge/platform-iOS-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)
![Maintained](https://img.shields.io/badge/maintained-yes-brightgreen)

---

## Roadmap

- [x] Word- and character-granularity streaming, with per-token stagger
- [x] Four animation styles: fade, scale, slide, bounce
- [x] Real text layout via TextKit (proper word-wrapping, line spacing, `Ti.UI.SIZE`)
- [x] Markdown parsing (bold, italic, code, headers, blockquotes, links)
- [x] Tap-to-open links, with a `link` event
- [x] VoiceOver / accessibility support
- [x] Dynamic Type support (`adjustsFontForContentSizeCategory`)
- [ ] Android support
- [ ] Selectable text
- [ ] Per-link VoiceOver navigation (currently the whole label is one accessibility element)
- [ ] Retroactive Dynamic Type re-scale when toggling the property at runtime

Contributions toward any of the unchecked items are very welcome — see [Contributing](#contributing).


<p align="center">
  <img src="https://github.com/deckameron/Ti.FancyLabel/blob/main/assets/image.gif?raw=true"
       width="300"
       alt="video" />
</p>

## Features

1. **Streaming reveal** — `appendText(chunk)` fades each new word or character in as it's appended, instead of just slapping it onto the screen.
2. **Instant text** — `setText(text)` replaces the whole label immediately, no animation, for restoring saved/cached content.
3. **Word or character granularity** — control how finely the reveal is staggered.
4. **Four animation styles** — fade, scale, slide, and bounce.
5. **Real text layout** — built on TextKit (`NSLayoutManager`/`NSTextContainer`), so wrapping, line spacing, and `Ti.UI.SIZE` sizing behave like a real label, not an approximation.
6. **Markdown support** — bold, italic, inline code, headers, blockquotes, and links, parsed with Foundation's own `AttributedString(markdown:)`.
7. **Tap-to-open links** — markdown links are tappable out of the box, and fire a `link` event so you can handle them yourself instead.
8. **Accessibility** — VoiceOver reads the label's current text live as it streams, with an optional "announce on complete" mode.
9. **Dynamic Type** — optionally scales with the user's preferred text size.

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Features](#features-in-detail)
  - [Streaming text](#streaming-text)
  - [Instant text](#instant-text)
  - [Granularity](#granularity)
  - [Animation styles](#animation-styles)
  - [Markdown](#markdown)
  - [Tap-to-open links](#tap-to-open-links)
  - [Accessibility (VoiceOver)](#accessibility-voiceover)
  - [Dynamic Type](#dynamic-type)
- [API Reference](#api-reference)
  - [Properties](#properties)
  - [Methods](#methods)
  - [Events](#events)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [License](#license)

## Installation

1. Download the latest `ti.fancylabel-iphone-*.zip` from the [Releases](../../releases) page (or build it yourself from source with `appc run` / `ti build` inside the `ios/` folder).
2. Unzip it into your Titanium install's `modules/iphone/` directory, or drop it into your project's own `modules/iphone/` folder.
3. Add the module to your app's `tiapp.xml`:

   ```xml
   <modules>
     <module platform="iphone">ti.fancylabel</module>
   </modules>
   ```

4. Make sure your deployment target is high enough:

   ```xml
   <ios>
     <min-ios-ver>13.0</min-ios-ver>
   </ios>
   ```

   `markdown: true` additionally needs iOS 15+ at runtime (it silently falls back to showing the raw, unparsed text on 13/14). Everything else works from iOS 13.0 up.

This module is **iOS-only** — there is no Android counterpart, and `Ti.FancyLabel.createLabel()` is unavailable on that platform.

## Quick Start

```js
import FancyLabel from 'ti.fancylabel';

const label = FancyLabel.createLabel({
  top: 40,
  left: 20,
  right: 20,
  height: Ti.UI.SIZE,
  font: { fontFamily: 'Helvetica Neue', fontSize: 17 },
  color: '#111111',
  granularity: 'word',
  animationStyle: 'fade'
});

win.add(label);

// Stream chunks in as they arrive, e.g. from a network/SSE callback:
label.appendText('Hello ');
label.appendText('there, ');
label.appendText('this is streaming in.');

// ...or set it all at once, instantly, with no animation:
label.setText('Restored from cache, no fade.');
```

## Features in detail

### Streaming text

```js
label.appendText(chunk);
```

Appends `chunk` to the label's current text and fades the new content in, token by token, according to `granularity`, `fadeDuration`, `fadeDelayStep`, and `animationStyle`. This is the method to call from a streaming response handler (e.g. each `Ti.Network.Manager` delta).

### Instant text

```js
label.setText(text);
```

Replaces the label's entire contents immediately, with no fade animation — useful for restoring a previously-streamed message (e.g. from local storage) without replaying the whole animation.

### Granularity

```js
label.granularity = 'word'; // or 'character'
```

Controls how finely `appendText()` stages its reveal: one `CATextLayer` per word, or one per character. Word granularity reads more naturally for most chat UIs; character granularity gives a more "typewriter"-like effect. Either way, the glyphs within a single token always sweep left-to-right (RTL-aware).

### Animation styles

```js
label.animationStyle = 'fade'; // 'fade' | 'scale' | 'slide' | 'bounce'
```

Each newly-revealed token animates in using one of four `CABasicAnimation`/`CAKeyframeAnimation`-based styles. `fadeDuration` (seconds per token) and `fadeDelayStep` (stagger between consecutive tokens) apply to all of them.

### Markdown

```js
label.markdown = true;
label.appendText('**Bold**, _italic_, `code`, and a [link](https://example.com).');
```

Parses `appendText()`/`setText()` input as Markdown (bold, italic, inline code, headers, blockquotes, links) via Foundation's `AttributedString(markdown:)`. Requires iOS 15+; on older versions the raw text is shown literally, including the markdown syntax characters.

### Tap-to-open links

```js
label.linkTapOpensURL = true; // default
label.addEventListener('link', (e) => {
  Ti.API.info(`Tapped link: ${e.url} ("${e.text}")`);
});
```

Tapping a markdown link fires a `link` event with the link's URL and display text. When `linkTapOpensURL` is `true` (the default), the URL is also opened via the system (`UIApplication.shared.open(_:)`) after the event fires; set it to `false` to handle links entirely yourself.

### Accessibility (VoiceOver)

```js
label.accessibilityLabel = 'Custom label for VoiceOver'; // optional override
label.accessibilityAnnouncesOnComplete = true;
```

The label is a single accessibility element, and by default VoiceOver reads whatever text is currently on screen — live, as it streams in — with no extra setup needed. Set `accessibilityLabel` explicitly if you want VoiceOver to say something other than the visible text. Set `accessibilityAnnouncesOnComplete` to `true` to also post a VoiceOver announcement of the final text once the label finishes revealing (useful for calling attention to a completed streamed message).

### Dynamic Type

```js
label.adjustsFontForContentSizeCategory = true;
```

When enabled, the label's font scales with the user's Settings → Accessibility → Larger Text preference (via `UIFontMetrics`), and rescales already-revealed text proportionally if the setting changes while the app is running. Default is `false`, matching `Ti.UI.Label`'s own default.

## API Reference

### Properties

| Property | Type | Default | Description |
|---|---|---|---|
| `text` | String | `""` | Initial text, shown fully opaque with no fade-in. |
| `font` | Object | system font, 17pt | `{ fontFamily, fontSize, fontWeight }`. |
| `color` | String | — | Hex color, e.g. `"#FFFFFF"`. |
| `textAlignment` | String | `"left"` | `"left"` \| `"center"` \| `"right"`. |
| `granularity` | String | `"word"` | `"word"` \| `"character"`. See [Granularity](#granularity). |
| `fadeDuration` | Number | `0.35` | Seconds each token takes to fade in. |
| `fadeDelayStep` | Number | `0.02` | Seconds of stagger between consecutive tokens. |
| `lineSpacing` | Number | `0` | Extra vertical gap between wrapped lines. |
| `animationStyle` | String | `"fade"` | `"fade"` \| `"scale"` \| `"slide"` \| `"bounce"`. |
| `markdown` | Boolean | `false` | Parse `appendText()`/`setText()` input as Markdown. Requires iOS 15+. |
| `accessibilityLabel` | String | — | Explicit VoiceOver label. Unset falls back live to the label's current text. |
| `accessibilityAnnouncesOnComplete` | Boolean | `false` | Post a VoiceOver announcement with the final text when `complete()` runs. |
| `linkTapOpensURL` | Boolean | `true` | Whether tapping a markdown link also opens it via the system, in addition to firing `link`. |
| `adjustsFontForContentSizeCategory` | Boolean | `false` | Scale `font` (and reflow existing text) to match the user's Dynamic Type setting. |

### Methods

#### `appendText(chunk)`

| Parameter | Type | Description |
|---|---|---|
| `chunk` | String | Text to append. Fades in according to `granularity`, `fadeDuration`, `fadeDelayStep`, and `animationStyle`. Ignored if empty. |

#### `setText(text)`

| Parameter | Type | Description |
|---|---|---|
| `text` | String | Replaces the label's entire contents immediately. No animation. |

#### `reset()`

Clears the label and cancels any in-flight animation. Takes no parameters.

#### `complete()`

Immediately finishes any in-flight fade (all pending tokens jump to fully revealed). Also posts the VoiceOver announcement if `accessibilityAnnouncesOnComplete` is `true`. Takes no parameters.

### Events

#### `link`

Fired when the user taps a markdown-parsed link, regardless of the `linkTapOpensURL` setting.

| Property | Type | Description |
|---|---|---|
| `url` | String | The link's target URL. |
| `text` | String | The link's visible display text. |

## Requirements

**iOS**

- iOS 13.0+ deployment target
- Titanium SDK 13.2.0.GA+
- `markdown: true` requires iOS 15+ at runtime (graceful fallback on 13/14)
- No third-party dependencies — pure UIKit, TextKit, and Core Animation

**Android**

- Not supported. This module has no Android implementation.

## Contributing

1. Fork this repository.
2. Create a feature branch: `git checkout -b my-feature`.
3. Commit your changes: `git commit -am 'Add my feature'`.
4. Push to your branch: `git push origin my-feature`.
5. Open a Pull Request describing the change and, where relevant, how you tested it (a real device/simulator run is strongly preferred, since this module leans heavily on TextKit/Core Animation behavior that's hard to verify statically).
