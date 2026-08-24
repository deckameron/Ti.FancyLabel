//
//  TiFancylabelLabelProxy.swift
//  Ti.FancyLabel
//
//  Copyright (c) 2026 Your Company. All rights reserved.
//
//  JS-facing proxy for Ti.FancyLabel.createLabel({...}).
//  By Titanium convention, a proxy class named "<ModulePrefix><Name>Proxy"
//  is automatically paired at runtime with a view class named
//  "<ModulePrefix><Name>" (see TiFancylabelLabel.swift) - no explicit
//  wiring is required for that part.
//
//  Supported creation/runtime properties, all read directly off this proxy
//  via TiViewProxy's own generic KVC-backed property system - none of them
//  need an explicit @objc property or setter here. TiFancylabelLabel reads
//  each one lazily (as a computed property, via `proxy.value(forKey:)`)
//  wherever it's needed, so setting one at runtime (e.g.
//  `label.lineSpacing = 8`) takes effect on the very next call that reads
//  it - see TiFancylabelLabel.swift for the exact default/behavior of
//  each:
//
//    text                             String    Initial text, shown fully opaque (no fade-in).
//    font                             Dictionary { fontFamily, fontSize, fontWeight }
//    color                            String    Hex color, e.g. "#FFFFFF".
//    textAlignment                    String    "left" (default) | "center" | "right"
//    granularity                      String    "word" (default) | "character" - controls
//                                                stagger between tokens; each token's own
//                                                glyphs always sweep left-to-right (RTL-aware).
//    fadeDuration                     Number    Seconds each token takes to fade in. Default 0.35.
//    fadeDelayStep                    Number    Seconds of stagger between consecutive tokens. Default 0.02.
//    lineSpacing                      Number    Extra vertical gap between wrapped lines. Default 0.
//    animationStyle                   String    "fade" (default) | "scale" | "slide" | "bounce".
//    markdown                         Boolean   Parse appendText()/setText() input as Markdown. Default false, iOS 15+.
//    accessibilityLabel               String    Explicit VoiceOver label; unset falls back live to the
//                                                label's own current text (see the "Accessibility
//                                                (VoiceOver)" section in TiFancylabelLabel.swift).
//    accessibilityAnnouncesOnComplete Boolean   Post a VoiceOver announcement with the final text when
//                                                complete() runs. Default false (opt-in).
//    linkTapOpensURL                  Boolean   Tapping a markdown link opens it via
//                                                UIApplication.shared.open(_:). Default true. A "link"
//                                                event ({url, text}) fires on every link tap either way.
//    adjustsFontForContentSizeCategory Boolean  Scale `font` (and reflow existing text) to match the
//                                                user's Settings > Accessibility > Larger Text
//                                                preference, via UIFontMetrics. Default false (matches
//                                                UILabel's own default).
//
//  Methods:
//
//    appendText(chunk)   Appends `chunk` and fades it in.
//    setText(text)       Replaces the whole label instantly, no animation.
//    reset()             Clears the label and cancels any in-flight animation.
//    complete()          Immediately finishes any in-flight fade.
//
//  Requires iOS 13.0+. `markdown: true` specifically needs iOS 15+
//  (Foundation's AttributedString(markdown:)); on iOS 13/14 it silently
//  falls back to showing the raw text literally, syntax characters
//  included.
//

import UIKit
import TitaniumKit

@objc(TiFancylabelLabelProxy)
public class TiFancylabelLabelProxy: TiViewProxy {

  private var labelView: TiFancylabelLabel? {
    return self.view as? TiFancylabelLabel
  }

  // MARK: Ti.UI.SIZE support
  //
  // Hand-written equivalent of the USE_VIEW_FOR_CONTENT_WIDTH /
  // USE_VIEW_FOR_CONTENT_HEIGHT macros TiUILabelProxy.m uses (Swift can't
  // use C macros): forward the proxy-level measurement calls Titanium's
  // layout engine makes straight to the view's own implementation.
  // Explicit @objc selector names so this is found by selector, regardless
  // of what Swift's default ObjC-import naming would have produced for an
  // `override`.

  @objc(contentWidthForWidth:)
  func contentWidthForWidth(_ suggestedWidth: CGFloat) -> CGFloat {
    return labelView?.contentWidthForWidth(suggestedWidth) ?? 0
  }

  @objc(contentHeightForWidth:)
  func contentHeightForWidth(_ width: CGFloat) -> CGFloat {
    return labelView?.contentHeightForWidth(width) ?? 0
  }

  // MARK: JS methods
  //
  // Every one of these takes `arguments: Any?`, not `arguments: [Any]?`.
  // A concrete `[Any]?` parameter makes Swift generate an Objective-C
  // bridging thunk that unconditionally force-bridges the incoming object
  // to an NSArray, which crashes if a caller ever hands this a bare value
  // instead of an arguments array. `firstStringArgument(from:)` below
  // accepts either shape safely via plain `as?` checks.

  private func firstStringArgument(from arguments: Any?) -> String? {
    if let array = arguments as? [Any] {
      return array.first as? String
    }
    return arguments as? String
  }

  @objc(appendText:)
  func appendText(arguments: Any?) {
    guard let chunk = firstStringArgument(from: arguments), !chunk.isEmpty else { return }
    labelView?.appendText(chunk)
  }

  @objc(setText:)
  func setText(arguments: Any?) {
    labelView?.setText(firstStringArgument(from: arguments) ?? "")
  }

  @objc(reset:)
  func reset(arguments: Any?) {
    labelView?.reset()
  }

  @objc(complete:)
  func complete(arguments: Any?) {
    labelView?.complete()
  }
}
