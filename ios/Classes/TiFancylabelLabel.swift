//
//  TiFancylabelLabel.swift
//  Ti.FancyLabel
//
//  Copyright (c) 2026 Your Company. All rights reserved.
//
//  Native view backing Ti.FancyLabel.createLabel({...}).
//
//  Pure UIKit/TextKit/Core Animation implementation - no SwiftUI.
//
//  - Word-wrapping and sizing are computed by TextKit (NSTextStorage +
//    NSLayoutManager + NSTextContainer), the same typesetter UILabel/
//    UITextView use. This gets bidi/RTL shaping correct for free, and its
//    layout is exactly what the on-screen text wraps to.
//  - Each reveal unit (a whole word, or a single character when
//    granularity:"character") is drawn by its own `CATextLayer`, positioned
//    at the glyph bounding rect TextKit computed for it. Revealing a unit
//    adds an explicit `CABasicAnimation` for its opacity.
//  - Resizing (frameSizeChanged) only ever touches layer *position*
//    (`.frame`, inside a `CATransaction` with actions disabled so the move
//    itself doesn't implicitly animate) - it never touches `.opacity`.
//    Position and opacity are independent CALayer properties changed by
//    independent code paths, so a resize can never interrupt or corrupt an
//    in-flight reveal animation, or vice versa.
//  - Measurement (contentWidthForWidth:/contentHeightForWidth:) uses a
//    throwaway NSLayoutManager+NSTextContainer temporarily attached to the
//    same NSTextStorage - a pure, synchronous computation that never
//    touches the live, on-screen CATextLayer tree.
//
//  Deployment target is iOS 13.0 - TextKit, CATextLayer and
//  CABasicAnimation are all long-available APIs.
//
//  KNOWN LIMITATION: hyphenation (splitting a word with a "-" across a line
//  break instead of moving it whole to the next line) is not implemented.
//  NSLayoutManager supports a `hyphenationFactor` if this is ever needed.
//

import UIKit
import QuartzCore
import TitaniumKit

// MARK: - Reveal units

/// The smallest thing that fades in on its own: either a whole word or a
/// single character, depending on `granularity`. `characterRange` is this
/// unit's location within the shared `textStorage`, in UTF-16 code units
/// (matching NSString/NSRange semantics) - it's what lets TextKit be asked
/// "where did this specific unit end up being laid out".
private final class FancyLabelUnit {
  let id: Int
  let text: String
  let characterRange: NSRange
  var revealed = false
  var layer: CATextLayer?
  // Per-unit, not per-label: with markdown enabled, one unit can be bold,
  // the next plain, the next a link - see "Markdown support" below.
  // Without markdown these just mirror the label's own font/color.
  var font: UIFont
  var color: UIColor
  // Set only when this unit came from a markdown link; consumed by the
  // tap gesture handler below.
  var linkURL: URL?

  init(id: Int, text: String, characterRange: NSRange, font: UIFont, color: UIColor, linkURL: URL? = nil) {
    self.id = id
    self.text = text
    self.characterRange = characterRange
    self.font = font
    self.color = color
    self.linkURL = linkURL
  }
}

// MARK: - Markdown support (optional)
//
// Off by default (the `markdown` property, see below). When on,
// `appendText(_:)`/`setText(_:)` treat the text they're given as Markdown
// *source* rather than literal display text: it's parsed, the syntax
// characters are stripped, and the resulting plain text/styling drives the
// same per-unit CATextLayer pipeline the rest of this file uses - markdown
// only changes what text and what font/color each unit gets, never how
// positioning, resizing, or the fade reveal itself work.
//
// Built on Foundation's own `AttributedString(markdown:)` (iOS 15+), which
// exposes both inline styling (`InlinePresentationIntent`: bold/italic/
// code/link) and block structure (`PresentationIntent`: headers/
// blockquotes/code blocks/lists) per run. This requires iOS 15+, so
// `markdown: true` is a no-op fallback (chunks pass through as literal
// plain text, syntax characters and all) on iOS 13/14 - see the
// `#available` guards below. The rest of the module still supports iOS
// 13.0+; only this specific property has a higher floor.

/// Inline/block style flags resolved for one run of markdown-parsed text.
/// Baked into a unit's own `font`/`color` at creation time (via
/// `resolvedFont(base:style:)`/`resolvedColor(base:style:)` below) - after
/// that, if a later chunk resolves the *same already-displayed* text
/// differently (its markdown token turned out to span further than first
/// thought), `applyStyleCorrections(...)` updates the affected units'
/// stored style and live layer/textStorage attributes directly. It never
/// re-triggers their reveal animation - a style correction is an instant
/// swap, not a re-reveal.
private struct FancyLabelInlineStyle: Equatable {
  var bold = false
  var italic = false
  var code = false
  var headerLevel: Int?
  var blockquote = false
  var linkURL: URL?
}

private struct FancyLabelStyledRun {
  // UTF-16 range within the *parsed plain text* this style applies to -
  // not within the raw markdown source, and not within textStorage
  // directly (though in markdown mode the two stay 1:1 aligned up to
  // however much has been displayed so far).
  var range: NSRange
  var style: FancyLabelInlineStyle
}

// MARK: - TiUIView

@objc(TiFancylabelLabel)
public class TiFancylabelLabel: TiUIView {

  // MARK: TextKit (layout/measurement)

  // Holds the full plain text accumulated so far, attributed once with the
  // label's font/paragraph style. Two independent NSLayoutManagers can be
  // attached to the same NSTextStorage at once (a standard TextKit
  // pattern) - `liveLayoutManager`/`liveTextContainer` below are
  // permanently attached and drive the actual on-screen CATextLayer
  // positions; `measure(maxWidth:)` attaches and detaches its own
  // temporary one per call, so a Ti.UI.SIZE measurement query never
  // touches the live, on-screen layout at all.
  private let textStorage = NSTextStorage()
  private let liveLayoutManager = NSLayoutManager()
  // Fully qualified (CGFloat.greatestFiniteMagnitude, not the shorthand
  // ".greatestFiniteMagnitude") throughout this file: Swift can otherwise
  // fail to disambiguate which type's static member a leading-dot
  // reference means here, since CGFloat/Double are interchangeable in
  // many contexts.
  private let liveTextContainer = NSTextContainer(
    size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
  )

  private var units: [FancyLabelUnit] = []
  private var nextUnitID = 0
  private var pendingWork: [DispatchWorkItem] = []

  // MARK: Markdown state (only touched when `markdown` is true)

  // The full markdown *source* accumulated so far (raw, syntax characters
  // included) - separate from `textStorage`, which holds the *parsed,
  // display* text. Re-parsed in full on every appendMarkdownChunk() call,
  // since a chunk can complete a markdown token that started in an
  // earlier chunk (e.g. a closing "**" arriving later).
  private var rawMarkdownSource = ""
  // How much of the parsed plain text (UTF-16 length) has already been
  // turned into units/textStorage content. Everything at or past this
  // offset in a fresh parse is "new" and gets appended as new units;
  // everything before it is checked for style corrections only.
  private var displayedPlainLength = 0

  // The running "sweep" timeline: the CACurrentMediaTime() at which the
  // *next* unit to be scheduled is allowed to start revealing. Carried
  // across appendText() calls (not reset per call) so a new chunk's units
  // continue the same left-to-right sweep exactly where the previous
  // chunk's left off, instead of restarting their stagger delay from 0
  // relative to "now" (which would let a fast-arriving chunk visibly jump
  // ahead of text that hadn't finished appearing yet).
  private var scheduleCursor: CFTimeInterval?

  // Read once at creation - see the "Known limitations" note in
  // documentation/index.md about live style changes not being wired up.
  private var font: UIFont = .systemFont(ofSize: 17)
  private var color: UIColor = .label
  private var textAlignment: NSTextAlignment = .left

  private var granularity: String {
    (proxy.value(forKey: "granularity") as? String) ?? "word"
  }

  private var fadeDuration: Double {
    (proxy.value(forKey: "fadeDuration") as? NSNumber)?.doubleValue ?? 0.35
  }

  private var staggerStep: Double {
    (proxy.value(forKey: "fadeDelayStep") as? NSNumber)?.doubleValue ?? 0.02
  }

  // Extra vertical gap between lines, in points. Default 0 - no gap beyond
  // the font's own natural line height/leading.
  //
  // Deliberately NOT implemented via NSParagraphStyle.lineSpacing: that
  // property is the gap *between* one line and the next, so
  // NSLayoutManager can't finalize a sealed line's lineFragmentUsedRect
  // height until it knows whether a following line exists - it
  // retroactively grows an already-placed line's rect the moment the next
  // line appears, which visibly shifts every already-revealed unit on
  // that line. Instead, this is applied manually and additively in
  // relayoutUnits() below: each line fragment gets a fixed, cumulative Y
  // offset (`lineIndex * lineSpacing`) on top of TextKit's own natural
  // stacking - an already-sealed line's offset only depends on how many
  // *earlier* lines exist, which is append-only and never revised once
  // set.
  private var lineSpacing: CGFloat {
    CGFloat((proxy.value(forKey: "lineSpacing") as? NSNumber)?.doubleValue ?? 0)
  }

  // Which CAAnimation shape a reveal uses, on top of the opacity fade
  // every style still has. See buildRevealAnimation(fadeDuration:) below.
  // 'fade' (default) is opacity only. 'scale'/'slide'/'bounce' each add a
  // `transform` animation grouped alongside the opacity one - `transform`
  // is a fully independent CALayer property from both `.opacity` (owned
  // by the reveal) and `.frame`/`.position` (owned by relayoutUnits()).
  private var animationStyle: String {
    (proxy.value(forKey: "animationStyle") as? String) ?? "fade"
  }

  // Whether appendText(_:)/setText(_:) treat their input as Markdown
  // source rather than literal text. Off by default.
  private var markdownEnabled: Bool {
    (proxy.value(forKey: "markdown") as? Bool) ?? false
  }

  // MARK: Accessibility (VoiceOver)
  //
  // Every unit of visible text here is a bare CATextLayer, not a UIView/
  // UILabel - CALayers are not UIAccessibility elements on their own, so
  // without the overrides below VoiceOver would see this entire view as
  // one silent, unlabeled element.
  //
  // A real UILabel's default accessibilityLabel *is* its own .text,
  // updated live as .text changes - this view behaves the same way,
  // rather than requiring the app author to manually mirror every
  // appendText()/setText() call into a separate accessibilityLabel
  // assignment. `accessibilityLabel` is overridden as a computed
  // property: if the app author explicitly sets one, that explicit value
  // wins and is returned as-is; otherwise it falls back live to
  // `accessibleText`, which always reflects whatever's currently in
  // `textStorage` - the same parsed, syntax-stripped plain text that's
  // actually on screen.
  private var explicitAccessibilityLabel: String?

  public override var accessibilityLabel: String? {
    get {
      if let explicit = explicitAccessibilityLabel, !explicit.isEmpty {
        return explicit
      }
      return accessibleText
    }
    set {
      explicitAccessibilityLabel = newValue
    }
  }

  /// The current logical text content, trimmed, or nil when empty - matches
  /// how an empty UILabel reports no accessibilityLabel rather than an
  /// empty string. Reads `textStorage.string` (what's actually been
  /// appended/parsed so far) rather than only the portion whose fade-in
  /// has visually finished - the reveal animation is a cosmetic detail of
  /// *how* text arrives, not part of its logical content.
  private var accessibleText: String? {
    let trimmed = textStorage.string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  // Opt-in: when true, complete() posts a UIAccessibility .announcement
  // with the final text once a message finishes streaming - the
  // VoiceOver equivalent of a chat bubble "arriving". Off by default,
  // since forcing an interruption on every completed message can be more
  // annoying than helpful; left as a per-label choice for the app author.
  private var accessibilityAnnouncesOnComplete: Bool {
    (proxy.value(forKey: "accessibilityAnnouncesOnComplete") as? Bool) ?? false
  }

  // MARK: Tap-to-open links (markdown)
  //
  // A single UITapGestureRecognizer on the whole view (added in
  // initializeState() below) hit-tests the tap point against every unit's
  // own layer.frame - the same frame relayoutUnits() keeps current - and,
  // if it lands on a link-carrying unit, fires a "link" event (so the app
  // can react - open in-app, log analytics, whatever) and, unless
  // linkTapOpensURL is set to false, also opens the URL in the default
  // browser via UIApplication.shared.open(_:).
  //
  // Known gap: because the whole label is one accessibility element, a
  // VoiceOver user's double-tap activates the *label*, not a specific
  // link inside it - this gesture recognizer only fires for an ordinary
  // sighted/touch tap. Making individual links their own accessibility
  // elements is a larger change, not implemented here.
  private var linkTapOpensURL: Bool {
    (proxy.value(forKey: "linkTapOpensURL") as? Bool) ?? true
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    let point = gesture.location(in: self)
    guard let unit = units.first(where: { $0.linkURL != nil && ($0.layer?.frame.contains(point) ?? false) }),
          let url = unit.linkURL else { return }

      proxy.fireEvent("link", with: ["url": url.absoluteString, "text": unit.text])

    if linkTapOpensURL {
      UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
  }

  // MARK: Dynamic Type
  //
  // Off by default (adjustsFontForContentSizeCategory, read below),
  // matching UILabel's own default - an existing label's rendering
  // doesn't change unless the app author opts in. `font` (the live,
  // possibly-scaled font every unit is created/measured with) starts out
  // equal to `unscaledFont` (exactly what readUIFont() computes from the
  // `font` proxy property); if adjustsFontForContentSizeCategory is true,
  // initializeState() below immediately runs it through UIFontMetrics
  // once, and a UIContentSizeCategory.didChangeNotification observer
  // re-runs it any time the user changes their preferred text size in
  // Settings while this label is alive.
  //
  // UIFontMetrics.default.scaledFont(for:) (rather than
  // UIFont.preferredFont(forTextStyle:)) is used because `font` isn't
  // necessarily one of the system's fixed text styles (.body, .headline,
  // etc.) - it can be any fontSize/fontFamily/fontWeight combination the
  // app author configured, and UIFontMetrics scales an arbitrary custom
  // font by the same ratio a system text style would scale by.
  private var unscaledFont: UIFont = .systemFont(ofSize: 17)

  private var adjustsFontForContentSizeCategory: Bool {
    (proxy.value(forKey: "adjustsFontForContentSizeCategory") as? Bool) ?? false
  }

  @objc private func contentSizeCategoryDidChange(_ notification: Notification) {
    guard adjustsFontForContentSizeCategory else { return }
    applyDynamicTypeFont()
  }

  /// Recomputes `font` from `unscaledFont` via UIFontMetrics, then rescales
  /// every *existing* unit's own font by the same ratio the base font just
  /// changed by - not by re-deriving each one from scratch, since a
  /// markdown-styled unit's own resolvedFont(base:style:) call already
  /// happened at creation time and its original FancyLabelInlineStyle
  /// isn't kept around afterward. Scaling the already-resolved font
  /// proportionally (same UIFontDescriptor, new pointSize) preserves a
  /// header/bold unit's relative size to the base font without needing
  /// that style back. New units created after this point don't need any
  /// of this - they're built from the now-updated `font` directly.
  private func applyDynamicTypeFont() {
    let newBase = UIFontMetrics.default.scaledFont(for: unscaledFont)
    guard font.pointSize > 0, newBase.pointSize != font.pointSize else { return }
    let ratio = newBase.pointSize / font.pointSize
    font = newBase
    guard !units.isEmpty else { return }
    for unit in units {
      let newFont = UIFont(descriptor: unit.font.fontDescriptor, size: unit.font.pointSize * ratio)
      unit.font = newFont
      unit.layer?.font = newFont
      unit.layer?.fontSize = newFont.pointSize
      textStorage.addAttribute(.font, value: newFont, range: unit.characterRange)
    }
    notifyContentsChanged()
    relayoutUnits()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  public override func initializeState() {
    super.initializeState()

    // Never let content bleed past our own bounds, even transiently while
    // a layout pass is still catching up - this is what keeps the view
    // honest inside a vertical ScrollView.
    self.clipsToBounds = true

    // See the "Accessibility (VoiceOver)" section above: without this,
    // VoiceOver skips straight over the whole view (its CATextLayer
    // children are invisible to the accessibility tree), since a bare
    // UIView is not an accessibility element by default.
    self.isAccessibilityElement = true
    // .staticText matches how VoiceOver announces a plain UILabel;
    // .updatesFrequently tells VoiceOver this element's value can change
    // on its own (mid-stream, as appendText() runs) without the user
    // having done anything - VoiceOver then does NOT auto-announce every
    // such change, so a streaming bubble doesn't spam the user with a new
    // announcement per word. The user can still swipe to the element at
    // any time and hear whatever text is current then.
    self.accessibilityTraits = [.staticText, .updatesFrequently]

    liveTextContainer.lineFragmentPadding = 0
    liveTextContainer.maximumNumberOfLines = 0
    // Fully qualified (NSLineBreakMode.byWordWrapping, not the shorthand
    // ".byWordWrapping") for the same type-inference reason noted above.
    liveTextContainer.lineBreakMode = NSLineBreakMode.byWordWrapping
    liveLayoutManager.addTextContainer(liveTextContainer)
    textStorage.addLayoutManager(liveLayoutManager)

    font = readUIFont()
    unscaledFont = font
    if adjustsFontForContentSizeCategory {
      font = UIFontMetrics.default.scaledFont(for: unscaledFont)
    }
    color = readColor()
    textAlignment = readTextAlignment()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(contentSizeCategoryDidChange(_:)),
      name: UIContentSizeCategory.didChangeNotification,
      object: nil
    )

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    self.addGestureRecognizer(tapGesture)

    setText((proxy.value(forKey: "text") as? String) ?? "")
  }

  public override func frameSizeChanged(_ frame: CGRect, bounds: CGRect) {
    let newWidth = bounds.width
    guard newWidth > 0, liveTextContainer.size.width != newWidth else { return }
    // Only ever touches layer *position*, inside a transaction that
    // suppresses the implicit animation a `.frame` change would otherwise
    // get - it never touches `.opacity`. This separation is what keeps a
    // resize from being able to interrupt an in-flight reveal fade (or
    // vice versa).
    liveTextContainer.size = CGSize(width: newWidth, height: CGFloat.greatestFiniteMagnitude)
    relayoutUnits()
  }

  // MARK: Ti.UI.SIZE support
  //
  // Mirrors TiUILabel.m's contentWidthForWidth:/contentHeightForWidth:.
  // Titanium's layout engine calls these on the *proxy*, which forwards
  // here (see TiFancylabelLabelProxy.swift). Explicit @objc selector
  // names so Titanium's Objective-C runtime finds them regardless of
  // Swift's default import-naming.
  //
  // Measures with a throwaway NSLayoutManager+NSTextContainer attached to
  // the same NSTextStorage the live layer tree reads from - real TextKit
  // line-breaking, so it can never disagree with how the live
  // CATextLayers actually wrap, and it never touches the live, on-screen
  // layout manager or any CATextLayer, so it can't race an in-flight
  // animation either.

  @objc(contentWidthForWidth:)
  func contentWidthForWidth(_ suggestedWidth: CGFloat) -> CGFloat {
    let proposedWidth = suggestedWidth > 0 ? suggestedWidth : CGFloat.greatestFiniteMagnitude
    return ceil(measure(maxWidth: proposedWidth).width)
  }

  @objc(contentHeightForWidth:)
  func contentHeightForWidth(_ width: CGFloat) -> CGFloat {
    guard width > 0 else { return 0 }
    return ceil(measure(maxWidth: width).height)
  }

  private func measure(maxWidth: CGFloat) -> CGSize {
    guard textStorage.length > 0 else { return .zero }
    let container = NSTextContainer(size: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.maximumNumberOfLines = 0
    container.lineBreakMode = NSLineBreakMode.byWordWrapping
    let manager = NSLayoutManager()
    manager.addTextContainer(container)
    textStorage.addLayoutManager(manager)
    manager.ensureLayout(for: container)
    let size = manager.usedRect(for: container).size
    // TextKit's own usedRect never includes our manual, per-line
    // lineSpacing (see the property comment above) - it's applied purely
    // at render time in relayoutUnits(), not as a paragraph attribute, so
    // TextKit has no idea it exists. Add it back in here so Titanium's
    // Ti.UI.SIZE resize actually reserves enough height for it.
    let lineCount = lineFragmentCount(layoutManager: manager, container: container)
    let extra = lineSpacing * CGFloat(max(lineCount - 1, 0))
    textStorage.removeLayoutManager(manager)
    return CGSize(width: size.width, height: size.height + extra)
  }

  /// Counts line fragments (i.e. wrapped lines) TextKit produced for
  /// `container`. Shared by `measure(maxWidth:)` (to reserve height for
  /// the manual lineSpacing above) and `relayoutUnits()` (to know each
  /// line's index for that same offset).
  private func lineFragmentGlyphRanges(layoutManager: NSLayoutManager, container: NSTextContainer) -> [NSRange] {
    let totalGlyphs = layoutManager.numberOfGlyphs
    guard totalGlyphs > 0 else { return [] }
    var ranges: [NSRange] = []
    layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: totalGlyphs)) { _, _, _, glyphRange, _ in
      ranges.append(glyphRange)
    }
    return ranges
  }

  private func lineFragmentCount(layoutManager: NSLayoutManager, container: NSTextContainer) -> Int {
    lineFragmentGlyphRanges(layoutManager: layoutManager, container: container).count
  }

  // MARK: Public API (called from TiFancylabelLabelProxy)

  func appendText(_ chunk: String) {
    guard !chunk.isEmpty else { return }
    if markdownEnabled {
      if #available(iOS 15.0, *) {
        appendMarkdownChunk(chunk)
        return
      }
      // markdown: true requires AttributedString(markdown:) (iOS 15+) -
      // on an older OS, fall through to the plain path below so the
      // chunk still shows up (as literal text, syntax characters and
      // all) instead of silently being dropped.
    }
    appendPlainChunk(chunk)
  }

  private func appendPlainChunk(_ chunk: String) {
    let tokens = tokenize(chunk)
    guard !tokens.isEmpty else { return }

    let fd = max(fadeDuration, 0.001)
    let step = max(staggerStep, 0)

    var newUnits: [FancyLabelUnit] = []
    var cursor = textStorage.length // UTF-16 location of the next appended unit
    func addUnit(_ text: String) {
      let length = text.utf16.count
      newUnits.append(FancyLabelUnit(id: makeUnitID(), text: text, characterRange: NSRange(location: cursor, length: length), font: font, color: color))
      cursor += length
    }
    for token in tokens {
      if granularity == "character" {
        for character in token { addUnit(String(character)) }
      } else {
        addUnit(token)
      }
    }

    // One storage mutation for the whole chunk, attributed consistently
    // with everything already there, so TextKit lays the new text out
    // continuing from exactly where the existing text left off.
    let combinedText = newUnits.map { $0.text }.joined()
    textStorage.append(NSAttributedString(string: combinedText, attributes: currentAttributes()))

    units.append(contentsOf: newUnits)
    for unit in newUnits { createLayer(for: unit) }

    finishAppend(newUnits: newUnits, fadeDuration: fd, staggerStep: step)
  }

  /// Shared tail of every append path (plain or markdown): resize the view
  /// (notifyContentsChanged()) before repositioning layers
  /// (relayoutUnits()), then schedule reveals for whatever's actually new.
  /// Pulled out so the markdown path can't accidentally drift from this
  /// ordering by duplicating it slightly differently.
  private func finishAppend(newUnits: [FancyLabelUnit], fadeDuration: Double, staggerStep: Double) {
    notifyContentsChanged()
    relayoutUnits()
    if !newUnits.isEmpty {
      scheduleReveals(for: newUnits, fadeDuration: fadeDuration, staggerStep: staggerStep)
    }
  }

  @available(iOS 15.0, *)
  private func appendMarkdownChunk(_ chunk: String) {
    rawMarkdownSource += chunk
    let (plainText, runs) = parseMarkdown(rawMarkdownSource)
    let newPlainLength = plainText.utf16.count
    let fd = max(fadeDuration, 0.001)
    let step = max(staggerStep, 0)

    // Streamed markdown can retroactively restyle text that's already on
    // screen (a lone "*" that looked like punctuation becomes emphasis
    // once its closing "*" arrives later). This corrects styling in
    // place - an instant font/color swap on the affected units, never a
    // re-reveal or a position jump. It does NOT handle the rarer case
    // where the *plain text itself* (not just its style) changes
    // retroactively - see documentation/index.md's "Known limitations"
    // entry for markdown.
    applyStyleCorrections(newRuns: runs, upTo: min(displayedPlainLength, newPlainLength))

    guard newPlainLength > displayedPlainLength else {
      // Nothing new to reveal (e.g. the chunk was only a "*" still
      // waiting for its pair) - a style correction above, if any, still
      // needs to reach the screen.
      if displayedPlainLength > 0 { finishAppend(newUnits: [], fadeDuration: fd, staggerStep: step) }
      return
    }

    let plainUTF16 = Array(plainText.utf16)
    // String.init(decoding:as:) takes any UInt16 sequence directly (an
    // ArraySlice here) and degrades gracefully (replacement characters)
    // instead of crashing on any edge-case input.
    let newSuffix = String(decoding: plainUTF16[displayedPlainLength...], as: UTF16.self)
    let tokens = tokenize(newSuffix)
    guard !tokens.isEmpty else {
      displayedPlainLength = newPlainLength
      return
    }

    var newUnits: [FancyLabelUnit] = []
    var storageCursor = textStorage.length
    var plainCursor = displayedPlainLength
    func addUnit(_ text: String) {
      let length = text.utf16.count
      let style = styleAt(plainCursor, in: runs) ?? FancyLabelInlineStyle()
      newUnits.append(FancyLabelUnit(
        id: makeUnitID(),
        text: text,
        characterRange: NSRange(location: storageCursor, length: length),
        font: resolvedFont(base: font, style: style),
        color: resolvedColor(base: color, style: style),
        linkURL: style.linkURL
      ))
      storageCursor += length
      plainCursor += length
    }
    for token in tokens {
      if granularity == "character" {
        for character in token { addUnit(String(character)) }
      } else {
        addUnit(token)
      }
    }

    // Unlike the plain path, each new unit can carry its own font (bold/
    // italic/code/header all change it), so textStorage needs per-unit
    // attributes rather than one attributes(...) call for the whole chunk.
    let combinedText = newUnits.map { $0.text }.joined()
    let attributedChunk = NSMutableAttributedString(string: combinedText)
    var location = 0
    for unit in newUnits {
      let length = unit.text.utf16.count
      attributedChunk.addAttributes(attributes(font: unit.font, color: unit.color), range: NSRange(location: location, length: length))
      location += length
    }
    textStorage.append(attributedChunk)

    units.append(contentsOf: newUnits)
    for unit in newUnits { createLayer(for: unit) }

    displayedPlainLength = newPlainLength
    finishAppend(newUnits: newUnits, fadeDuration: fd, staggerStep: step)
  }

  func setText(_ text: String) {
    resetInternal()
    guard !text.isEmpty else {
      notifyContentsChanged()
      return
    }

    var newUnits: [FancyLabelUnit] = []
    // setText() replaces the whole label instantly, fully revealed - no
    // need to split into characters even if granularity is "character",
    // since nothing here animates.
    if markdownEnabled, #available(iOS 15.0, *) {
      rawMarkdownSource = text
      let (plainText, runs) = parseMarkdown(text)
      displayedPlainLength = plainText.utf16.count
      var cursor = 0
      for token in tokenize(plainText) {
        let length = token.utf16.count
        let style = styleAt(cursor, in: runs) ?? FancyLabelInlineStyle()
        newUnits.append(FancyLabelUnit(
          id: makeUnitID(),
          text: token,
          characterRange: NSRange(location: cursor, length: length),
          font: resolvedFont(base: font, style: style),
          color: resolvedColor(base: color, style: style),
          linkURL: style.linkURL
        ))
        cursor += length
      }
      let combinedText = newUnits.map { $0.text }.joined()
      let attributedText = NSMutableAttributedString(string: combinedText)
      var location = 0
      for unit in newUnits {
        let length = unit.text.utf16.count
        attributedText.addAttributes(attributes(font: unit.font, color: unit.color), range: NSRange(location: location, length: length))
        location += length
      }
      textStorage.append(attributedText)
    } else {
      var cursor = 0
      for token in tokenize(text) {
        let length = token.utf16.count
        newUnits.append(FancyLabelUnit(id: makeUnitID(), text: token, characterRange: NSRange(location: cursor, length: length), font: font, color: color))
        cursor += length
      }
      let combinedText = newUnits.map { $0.text }.joined()
      textStorage.append(NSAttributedString(string: combinedText, attributes: currentAttributes()))
    }

    units = newUnits
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for unit in newUnits {
      createLayer(for: unit)
      unit.revealed = true
      unit.layer?.opacity = 1
      unit.layer?.transform = CATransform3DIdentity
    }
    CATransaction.commit()

    // Same ordering as appendText() above: resize first, position second,
    // so nothing is placed outside the still-old, clipped bounds.
    notifyContentsChanged()
    relayoutUnits()
  }

  func reset() {
    resetInternal()
    notifyContentsChanged()
  }

  /// Immediately finishes any in-flight fade: every unit still waiting to
  /// reveal jumps straight to fully opaque, with no animation - matches
  /// "the app is backgrounding / the stream ended, stop mid-fade cleanly".
  func complete() {
    cancelPendingWork()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for unit in units where !unit.revealed {
      unit.revealed = true
      unit.layer?.removeAllAnimations()
      unit.layer?.opacity = 1
      unit.layer?.transform = CATransform3DIdentity
    }
    CATransaction.commit()
    scheduleCursor = nil
    notifyContentsChanged()

    if accessibilityAnnouncesOnComplete, let text = accessibleText {
      UIAccessibility.post(notification: .announcement, argument: text)
    }
  }

  // MARK: Reveal scheduling

  private func scheduleReveals(for newUnits: [FancyLabelUnit], fadeDuration: Double, staggerStep: Double) {
    let style = animationStyle
    let now = CACurrentMediaTime()
    var cursor = max(scheduleCursor ?? now, now)
    for unit in newUnits {
      let delay = max(cursor - now, 0)
      let work = DispatchWorkItem { [weak unit] in
        guard let unit = unit, let layer = unit.layer, !unit.revealed else { return }
        unit.revealed = true
        // Model values first, so they stick after the animation is
        // removed/finishes.
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        layer.add(Self.buildRevealAnimation(style: style, fadeDuration: fadeDuration), forKey: "reveal")
      }
      pendingWork.append(work)
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
      cursor += staggerStep
    }
    scheduleCursor = cursor
  }

  /// Builds the CAAnimation for one reveal. Every style includes the
  /// opacity fade (0 -> 1, explicit CABasicAnimation);
  /// 'scale'/'slide'/'bounce' add a second, grouped animation on
  /// `transform`, a CALayer property completely independent of both
  /// `.opacity` (this reveal) and `.frame`/`.position` (owned by
  /// relayoutUnits()). Grouped under one CAAnimationGroup added under a
  /// single "reveal" key, so complete()'s removeAllAnimations() cancels
  /// everything for a style in one call.
  private static func buildRevealAnimation(style: String, fadeDuration: Double) -> CAAnimation {
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0
    opacity.toValue = 1

    switch style {
    case "scale":
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 0.85
      scale.toValue = 1.0
      let group = CAAnimationGroup()
      group.animations = [opacity, scale]
      group.duration = fadeDuration
      group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      return group

    case "slide":
      // Slides up into place (starts a few points below its final
      // position) while it fades in.
      let slide = CABasicAnimation(keyPath: "transform.translation.y")
      slide.fromValue = 6
      slide.toValue = 0
      let group = CAAnimationGroup()
      group.animations = [opacity, slide]
      group.duration = fadeDuration
      group.timingFunction = CAMediaTimingFunction(name: .easeOut)
      return group

    case "bounce":
      // Keyframed overshoot (grows past 1.0, settles back) rather than
      // CASpringAnimation, so the timing is exact/deterministic and
      // doesn't depend on mass/stiffness/damping tuning.
      let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
      bounce.values = [0.7, 1.08, 0.97, 1.0]
      bounce.keyTimes = [0, 0.55, 0.8, 1.0]
      bounce.duration = fadeDuration
      opacity.timingFunction = CAMediaTimingFunction(name: .easeOut)
      let group = CAAnimationGroup()
      group.animations = [opacity, bounce]
      group.duration = fadeDuration
      return group

    default: // "fade"
      opacity.duration = fadeDuration
      opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      return opacity
    }
  }

  private func cancelPendingWork() {
    pendingWork.forEach { $0.cancel() }
    pendingWork = []
  }

  // MARK: Layer management

  private func createLayer(for unit: FancyLabelUnit) {
    let layer = CATextLayer()
    layer.string = unit.text
    layer.font = unit.font
    layer.fontSize = unit.font.pointSize
    layer.foregroundColor = unit.color.cgColor
    layer.contentsScale = UIScreen.main.scale
    layer.truncationMode = .none
    layer.opacity = 0
    self.layer.addSublayer(layer)
    unit.layer = layer
  }

  /// Repositions every existing unit's layer to match TextKit's current
  /// glyph layout - called after the container width changes and after
  /// new text is appended. Wrapped in a transaction with actions
  /// disabled, so this move is never implicitly animated and never
  /// touches `.opacity` - it can't interrupt or race an in-flight reveal
  /// animation.
  private func relayoutUnits() {
    guard !units.isEmpty else { return }

    // Force TextKit to fully commit layout for everything currently in
    // textStorage before reading ANY position out of it. NSLayoutManager
    // lays out glyphs lazily/incrementally - without this, a query for a
    // sealed, already-on-screen line's boundingRect could land while
    // that line's geometry is still provisional and get silently revised
    // the next time relayoutUnits() runs and layout has since caught up.
    liveLayoutManager.ensureLayout(for: liveTextContainer)

    // Manual lineSpacing (see the property comment above for why this
    // isn't NSParagraphStyle.lineSpacing): line 0 gets no extra offset,
    // line 1 gets one `lineSpacing`, line 2 gets two, etc. - cumulative,
    // and computed fresh from TextKit's own (lineSpacing-free) line
    // fragments every call, but an already-sealed line's own index only
    // depends on how many earlier lines exist, which is append-only, so
    // a line already on screen never has its offset revised once
    // assigned.
    let spacing = lineSpacing
    let lineRanges = spacing != 0 ? lineFragmentGlyphRanges(layoutManager: liveLayoutManager, container: liveTextContainer) : []
    func lineOffset(forGlyphLocation location: Int) -> CGFloat {
      guard spacing != 0 else { return 0 }
      for (index, range) in lineRanges.enumerated() where NSLocationInRange(location, range) {
        return spacing * CGFloat(index)
      }
      // Past the last known line fragment (shouldn't normally happen
      // right after ensureLayout above) - fall back to the last line's
      // offset rather than 0, so a unit doesn't visually jump backward.
      return spacing * CGFloat(max(lineRanges.count - 1, 0))
    }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for unit in units {
      guard let layer = unit.layer else { continue }
      let glyphRange = liveLayoutManager.glyphRange(forCharacterRange: unit.characterRange, actualCharacterRange: nil)
      var newFrame = liveLayoutManager.boundingRect(forGlyphRange: glyphRange, in: liveTextContainer)
      newFrame.origin.y += lineOffset(forGlyphLocation: glyphRange.location)
      layer.frame = newFrame
    }
    CATransaction.commit()
  }

  // MARK: Helpers

  private func resetInternal() {
    cancelPendingWork()
    for unit in units { unit.layer?.removeFromSuperlayer() }
    units = []
    if textStorage.length > 0 {
      textStorage.deleteCharacters(in: NSRange(location: 0, length: textStorage.length))
    }
    scheduleCursor = nil
    rawMarkdownSource = ""
    displayedPlainLength = 0
  }

  /// The attributes one run of text gets in `textStorage`, given a
  /// specific font/color - `currentAttributes()` below is just this
  /// called with the label's own base font/color, for the plain
  /// (non-markdown) path where every unit shares one style.
  private func attributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
    let paragraphStyle = NSMutableParagraphStyle()
    // No paragraphStyle.lineSpacing here - on purpose, see the
    // `lineSpacing` property comment above for why extra line gap is
    // applied manually in relayoutUnits() instead.
    paragraphStyle.alignment = textAlignment
    return [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraphStyle,
      // Disables ligature substitution (e.g. "fi" -> a single fused
      // glyph, "ff" the same). With granularity:"character", a
      // ligature-forming pair split across two separate reveal units
      // would otherwise resolve to the same glyph/boundingRect via
      // NSLayoutManager.glyphRange(forCharacterRange:), causing both
      // units' CATextLayers to render on top of each other. Word-
      // granularity units never hit this (a whole word is one
      // CATextLayer/one boundingRect query), but this attribute is
      // applied unconditionally since disabling ligatures has no
      // meaningful visual cost either way.
      .ligature: 0
    ]
  }

  private func currentAttributes() -> [NSAttributedString.Key: Any] {
    attributes(font: font, color: color)
  }

  // MARK: Markdown parsing/styling (only used when markdownEnabled)

  @available(iOS 15.0, *)
  private func parseMarkdown(_ source: String) -> (plainText: String, runs: [FancyLabelStyledRun]) {
    guard let parsed = try? AttributedString(
      markdown: source,
      options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    ) else {
      // Malformed enough that even the lenient .full parser threw -
      // degrade to showing the raw source as plain, unstyled text
      // rather than losing/hiding it.
      return (source, [FancyLabelStyledRun(range: NSRange(location: 0, length: source.utf16.count), style: FancyLabelInlineStyle())])
    }

    var plainText = ""
    var runs: [FancyLabelStyledRun] = []
    var cursor = 0
    for run in parsed.runs {
      let substring = String(parsed.characters[run.range])
      guard !substring.isEmpty else { continue }

      var style = FancyLabelInlineStyle()
      if let intent = run.inlinePresentationIntent {
        style.bold = intent.contains(.stronglyEmphasized)
        style.italic = intent.contains(.emphasized)
        style.code = intent.contains(.code)
      }
      style.linkURL = run.link
      if let presentationIntent = run.presentationIntent {
        for component in presentationIntent.components {
          switch component.kind {
          case .header(let level):
            style.headerLevel = level
          case .blockQuote:
            style.blockquote = true
          case .codeBlock:
            style.code = true
          default:
            break
          }
        }
      }

      let length = substring.utf16.count
      runs.append(FancyLabelStyledRun(range: NSRange(location: cursor, length: length), style: style))
      cursor += length
      plainText += substring
    }
    return (plainText, runs)
  }

  private func styleAt(_ utf16Location: Int, in runs: [FancyLabelStyledRun]) -> FancyLabelInlineStyle? {
    for run in runs where NSLocationInRange(utf16Location, run.range) {
      return run.style
    }
    return nil
  }

  /// Checks every already-displayed unit (characterRange.location < limit)
  /// against a freshly reparsed set of runs, and updates any whose style
  /// changed - font/color on the live layer plus textStorage's own
  /// attributes for that range (so TextKit's wrapping reflects the new,
  /// possibly wider/narrower font too). Purely a correction: revealed
  /// stays revealed, no animation, no unit is created or removed. If
  /// anything changed, relayoutUnits() runs once at the end, since a font
  /// swap can shift where lines wrap for everything after it.
  @available(iOS 15.0, *)
  private func applyStyleCorrections(newRuns: [FancyLabelStyledRun], upTo limit: Int) {
    guard limit > 0, !units.isEmpty else { return }
    var changed = false
    for unit in units {
      guard unit.characterRange.location < limit else { continue }
      guard let style = styleAt(unit.characterRange.location, in: newRuns) else { continue }
      let newFont = resolvedFont(base: font, style: style)
      let newColor = resolvedColor(base: color, style: style)
      guard newFont != unit.font || newColor != unit.color else { continue }
      unit.font = newFont
      unit.color = newColor
      unit.linkURL = style.linkURL
      unit.layer?.font = newFont
      unit.layer?.fontSize = newFont.pointSize
      unit.layer?.foregroundColor = newColor.cgColor
      textStorage.addAttributes(attributes(font: newFont, color: newColor), range: unit.characterRange)
      changed = true
    }
    if changed { relayoutUnits() }
  }

  /// Resolves a markdown-styled run's UIFont from the label's own base
  /// font.
  private func resolvedFont(base: UIFont, style: FancyLabelInlineStyle) -> UIFont {
    var traits: UIFontDescriptor.SymbolicTraits = []
    var pointSize = base.pointSize
    if style.bold { traits.insert(.traitBold) }
    if style.italic { traits.insert(.traitItalic) }
    if let level = style.headerLevel {
      traits.insert(.traitBold)
      // Level 1 biggest, shrinking a bit per level, never smaller than
      // the base size.
      let scale = max(1.6 - (CGFloat(max(level - 1, 0)) * 0.15), 1.0)
      pointSize = base.pointSize * scale
    }
    if style.code {
      let codeFont = UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
      guard !traits.isEmpty else { return codeFont }
      if let descriptor = codeFont.fontDescriptor.withSymbolicTraits(traits) {
        return UIFont(descriptor: descriptor, size: codeFont.pointSize)
      }
      return codeFont
    }
    guard !traits.isEmpty || pointSize != base.pointSize else { return base }
    let descriptor = base.fontDescriptor.withSize(pointSize)
    if !traits.isEmpty, let withTraits = descriptor.withSymbolicTraits(traits) {
      return UIFont(descriptor: withTraits, size: pointSize)
    }
    return UIFont(descriptor: descriptor, size: pointSize)
  }

  private func resolvedColor(base: UIColor, style: FancyLabelInlineStyle) -> UIColor {
    // Links and blockquotes get a distinguishing color - no underline
    // (CATextLayer is given a plain String, not an NSAttributedString,
    // so it can't render underline/strikethrough runs the way
    // textStorage itself could; color is the only per-unit visual cue
    // available without a bigger rendering change). Not wired to tap
    // handling for anything other than links - see
    // FancyLabelUnit.linkURL's comment.
    if style.linkURL != nil { return .systemBlue }
    if style.blockquote { return base.withAlphaComponent(0.7) }
    return base
  }

  private func notifyContentsChanged() {
    // Content just changed - tell Titanium's layout engine to re-measure
    // us (calls back into contentHeightForWidth: above) and re-run
    // layout. Without this, Ti.UI.SIZE only ever reflects the size at
    // creation time.
    //
    // self.proxy on TiUIView is statically typed as the base TiProxy,
    // which doesn't declare contentsWillChange() - that lives on
    // TiViewProxy (our TiFancylabelLabelProxy is always one).
    (proxy as? TiViewProxy)?.contentsWillChange()
  }

  /// Splits on whitespace, keeping each token's trailing space attached -
  /// so a token is exactly what one reveal unit's (or, in character mode,
  /// one group of reveal units') text should be, spacing included.
  ///
  /// "\n" is its own token boundary, split off separately from whatever
  /// precedes/follows it, rather than folded into the current run the way
  /// a plain space is. This matters because a unit's `characterRange`
  /// must never span more than one TextKit line fragment:
  /// `boundingRect(forGlyphRange:in:)` for a multi-line-fragment range
  /// returns a union rect across all of them, not a tight single-line
  /// box, which would visibly overlap/misplace that unit's `CATextLayer`
  /// against its neighbors.
  private func tokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for character in text {
      if character == "\n" {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
        tokens.append(String(character))
        continue
      }
      current.append(character)
      if character == " " {
        tokens.append(current)
        current = ""
      }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }

  private func makeUnitID() -> Int {
    defer { nextUnitID += 1 }
    return nextUnitID
  }

  private func readUIFont() -> UIFont {
    let dict = proxy.value(forKey: "font") as? [String: Any]
    let size = (dict?["fontSize"] as? NSNumber)?.doubleValue ?? 17

    var weight: UIFont.Weight = .regular
    switch dict?["fontWeight"] as? String {
    case "bold": weight = .bold
    case "semibold": weight = .semibold
    case "light": weight = .light
    default: break
    }

    if let family = dict?["fontFamily"] as? String,
       let custom = UIFont(name: family, size: CGFloat(size)) {
      return custom
    }
    return .systemFont(ofSize: CGFloat(size), weight: weight)
  }

  private func readColor() -> UIColor {
    if let hex = proxy.value(forKey: "color") as? String,
       let uiColor = TiUtils.colorValue(hex)?.color {
      return uiColor
    }
    return .label
  }

  private func readTextAlignment() -> NSTextAlignment {
    switch proxy.value(forKey: "textAlignment") as? String {
    case "center": return .center
    case "right": return .right
    default: return .left
    }
  }
}
