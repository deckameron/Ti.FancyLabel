// Test harness for Ti.FancyLabel.
//
// Exercises the core streaming API plus every property the module exposes:
//
//  1. Left-to-right fade sweep - watch each word/character reveal glyph by
//     glyph in writing order, instead of popping in all at once.
//  2. Auto-height inside a parent - each bubble is a Ti.FancyLabel with
//     height: Ti.UI.SIZE, stacked inside a vertical ScrollView. Watch each
//     bubble grow downward to fit its own text (never upward, never past
//     its own rounded-rect background), and the ScrollView's content grow
//     to fit every bubble as messages stream in.
//  3. animationStyle - 'fade' (default), 'scale', 'slide', 'bounce'. Each
//     reveal still fades in; scale/slide/bounce add a second, independent
//     transform animation on top - see documentation/index.md's
//     "Animation styles" section.
//  4. lineSpacing - extra vertical gap between wrapped lines. The
//     "Line spacing" button streams a multi-line message with a visibly
//     larger lineSpacing than every other bubble on screen, so you can
//     compare the gap directly.
//  5. markdown - headers, bold, italic, inline code, a fenced code block,
//     a blockquote, and a link. The "Markdown (stream)" button
//     deliberately splits a **bold phrase with spaces in it** across
//     multiple appendText() chunks, so you can watch the already-revealed
//     words (shown plain at first, since their closing "**" hasn't
//     arrived yet) snap to bold the instant it does - that's the
//     "style correction" behavior documented in
//     documentation/index.md's "Markdown support" section, not a bug if
//     you see a brief flash of literal "**" before it resolves.
//  6. VoiceOver - every bubble is accessible automatically (no wiring
//     needed in this file): turn VoiceOver on (Settings > Accessibility >
//     VoiceOver, or the Accessibility Inspector in Simulator) and swipe to
//     any bubble to hear its current text, live as it streams. The
//     "VoiceOver (announce)" button additionally sets
//     accessibilityAnnouncesOnComplete = true on its bubble, so VoiceOver
//     also announces the final text unprompted the moment that message
//     finishes streaming - see documentation/index.md's "Accessibility
//     (VoiceOver)" section.
//  7. Tap-to-open links - every bubble listens for the "link" event (see
//     createBubble() below); tap the link text in either markdown bubble
//     ("module documentation") to see it logged and opened in the
//     browser. Set bubble.linkTapOpensURL = false to only get the event,
//     without the automatic browser open.
//  8. Dynamic Type - the "Dynamic Type" button's bubble sets
//     adjustsFontForContentSizeCategory = true. Change Settings >
//     Accessibility > Display & Text Size > Larger Text (or the
//     Simulator's equivalent) while that bubble is on screen to watch its
//     font rescale and the bubble reflow live.
//
// backgroundColor + borderRadius are set on every bubble so the view's
// real native bounds are always visible, which makes auto-height/growth
// easy to verify at a glance.

import FancyLabel from 'ti.fancylabel';

const win = Ti.UI.createWindow({ backgroundColor: '#f2f2f7' });

const scrollView = Ti.UI.createScrollView({
  top: 0, left: 0, right: 0, bottom: 300,
  layout: 'vertical',
  contentWidth: Ti.UI.FILL,
  contentHeight: Ti.UI.SIZE,
  showVerticalScrollIndicator: true
});
win.add(scrollView);

// Everything lives inside this vertical stack. Its own height is
// Ti.UI.SIZE too, so it only grows as far as its children actually need -
// if that stops working, the ScrollView stops growing with it.
const stack = Ti.UI.createView({
  layout: 'vertical',
  top: 12, left: 0, right: 0,
  height: Ti.UI.SIZE,
  width: Ti.UI.FILL
});
scrollView.add(stack);

const controls = Ti.UI.createView({
  bottom: 0, left: 0, right: 0, height: 300,
  backgroundColor: '#ffffff',
  layout: 'vertical'
});
win.add(controls);

function buttonRow(buttons) {
  const row = Ti.UI.createView({ top: 10, left: 12, right: 12, height: 36, layout: 'horizontal' });
  buttons.forEach((button, i) => {
    if (i < buttons.length - 1) button.right = 8;
    row.add(button);
  });
  controls.add(row);
  return row;
}

const wordButton = Ti.UI.createButton({ title: 'Message (word)', width: Ti.UI.SIZE, height: 36 });
const charButton = Ti.UI.createButton({ title: 'Message (character)', width: Ti.UI.SIZE, height: 36 });
buttonRow([wordButton, charButton]);

const instantButton = Ti.UI.createButton({ title: 'Instant (setText)', width: Ti.UI.SIZE, height: 36 });
const shortButton = Ti.UI.createButton({ title: 'Short message', width: Ti.UI.SIZE, height: 36 });
buttonRow([instantButton, shortButton]);

const markdownStreamButton = Ti.UI.createButton({ title: 'Markdown (stream)', width: Ti.UI.SIZE, height: 36 });
const markdownInstantButton = Ti.UI.createButton({ title: 'Markdown (setText)', width: Ti.UI.SIZE, height: 36 });
buttonRow([markdownStreamButton, markdownInstantButton]);

const fadeButton = Ti.UI.createButton({ title: 'Fade', width: Ti.UI.SIZE, height: 36 });
const scaleButton = Ti.UI.createButton({ title: 'Scale', width: Ti.UI.SIZE, height: 36 });
const slideButton = Ti.UI.createButton({ title: 'Slide', width: Ti.UI.SIZE, height: 36 });
const bounceButton = Ti.UI.createButton({ title: 'Bounce', width: Ti.UI.SIZE, height: 36 });
buttonRow([fadeButton, scaleButton, slideButton, bounceButton]);

const lineSpacingButton = Ti.UI.createButton({ title: 'Line spacing (8pt)', width: Ti.UI.SIZE, height: 36 });
const a11yButton = Ti.UI.createButton({ title: 'VoiceOver (announce)', width: Ti.UI.SIZE, height: 36 });
buttonRow([lineSpacingButton, a11yButton]);

const dynamicTypeButton = Ti.UI.createButton({ title: 'Dynamic Type', width: Ti.UI.SIZE, height: 36 });
const clearButton = Ti.UI.createButton({ title: 'Clear all', width: Ti.UI.SIZE, height: 36 });
buttonRow([dynamicTypeButton, clearButton]);

// A couple of long-ish responses (to see wrapping + multi-line growth) and
// one short one (to see the sweep on a single short word/line).
const longResponses = [
  'Hi! This is a demo of Ti.FancyLabel, simulating a text stream arriving bit by bit, just like an AI assistant\'s response.',
  'Each new message grows inside the ScrollView without breaking out of its parent container\'s bounds, and the ScrollView\'s own content grows to match in real time.',
  'The fade effect sweeps left to right, glyph by glyph, within each revealed word or character - including in right-to-left text.'
];
let longIndex = 0;

function nextLongResponse() {
  const text = longResponses[longIndex % longResponses.length];
  longIndex += 1;
  return text;
}

// Deliberately breaks "**very important**" across chunk boundaries - the
// opening "**very" lands in one appendText() call, "important**" in a
// later one, so "very" gets displayed plain first, then corrected to bold
// the instant the closing "**" arrives. Also exercises a header, italic,
// inline code, a fenced code block, a blockquote, and a link.
const markdownDemo =
  '# Ti.FancyLabel + Markdown\n\n' +
  'Now with markdown support - **very important** for formatted AI responses, with *italics*, `inline code`, and blocks:\n\n' +
  '```\nconst answer = await ai.ask("hello");\n```\n\n' +
  '> Partial markdown while streaming is corrected automatically as the text arrives.\n\n' +
  'Learn more in the [module documentation](https://example.com/docs).';

function createBubble() {
  const bubble = FancyLabel.createLabel({
    font: { fontSize: 16 },
    color: '#111111',
    backgroundColor: '#e4e9f7', // makes the view's real bounds obvious for visual debugging
    borderRadius: 14,
    top: 0, bottom: 10, left: 16, right: 16,
    width: Ti.UI.FILL,
    height: Ti.UI.SIZE
  });
  // Harmless on bubbles with no links (markdown off, or no [text](url) in
  // the message) - just never fires for those. Tap the link text in either
  // markdown bubble to see this. linkTapOpensURL defaults to true, so the
  // browser also opens; this listener runs either way.
  bubble.addEventListener('link', (e) => {
    Ti.API.info(`[Ti.FancyLabel] link tapped: ${e.text.trim()} -> ${e.url}`);
  });
  stack.add(bubble);
  return bubble;
}

function streamInto(bubble, text, granularity) {
  bubble.reset();
  bubble.granularity = granularity;
  bubble.fadeDuration = granularity === 'character' ? 0.18 : 0.35;
  bubble.fadeDelayStep = granularity === 'character' ? 0.015 : 0.03;

  const words = text.split(' ').map((word, i, arr) => (i < arr.length - 1 ? word + ' ' : word));
  let i = 0;
  const timer = setInterval(() => {
    if (i >= words.length) {
      clearInterval(timer);
      bubble.complete();
      scrollToBottom();
      return;
    }
    bubble.appendText(words[i]);
    i += 1;
    scrollToBottom();
  }, 160);
}

// Best-effort auto-scroll: wait for the stack's next layout pass, then
// scroll so the newest content stays visible.
function scrollToBottom() {
  stack.addEventListener('postlayout', function onLayout() {
    stack.removeEventListener('postlayout', onLayout);
    const targetY = Math.max((stack.size.height || 0) - (scrollView.size.height || 0) + 40, 0);
    scrollView.scrollTo(0, targetY);
  });
}

wordButton.addEventListener('click', () => {
  streamInto(createBubble(), nextLongResponse(), 'word');
});

charButton.addEventListener('click', () => {
  streamInto(createBubble(), nextLongResponse(), 'character');
});

shortButton.addEventListener('click', () => {
  streamInto(createBubble(), 'Hi!', 'word');
});

instantButton.addEventListener('click', () => {
  const bubble = createBubble();
  bubble.setText(nextLongResponse());
  scrollToBottom();
});

markdownStreamButton.addEventListener('click', () => {
  const bubble = createBubble();
  bubble.markdown = true;
  streamInto(bubble, markdownDemo, 'word');
});

markdownInstantButton.addEventListener('click', () => {
  const bubble = createBubble();
  bubble.markdown = true;
  bubble.setText(markdownDemo);
  scrollToBottom();
});

function streamWithAnimationStyle(style) {
  const bubble = createBubble();
  bubble.animationStyle = style;
  // A slower pace than the default demo so each style's motion (scale/
  // slide/bounce) is actually easy to see per word, instead of blurring
  // together at the normal streaming rate.
  bubble.fadeDuration = 0.5;
  bubble.fadeDelayStep = 0.08;
  streamInto(bubble, `Animation style: ${style}. Watch how each word moves as it appears.`, 'word');
}

fadeButton.addEventListener('click', () => streamWithAnimationStyle('fade'));
scaleButton.addEventListener('click', () => streamWithAnimationStyle('scale'));
slideButton.addEventListener('click', () => streamWithAnimationStyle('slide'));
bounceButton.addEventListener('click', () => streamWithAnimationStyle('bounce'));

lineSpacingButton.addEventListener('click', () => {
  const bubble = createBubble();
  bubble.lineSpacing = 8;
  streamInto(bubble, nextLongResponse(), 'word');
});

a11yButton.addEventListener('click', () => {
  const bubble = createBubble();
  // No accessibilityLabel set on purpose - VoiceOver reads this bubble's
  // own live text automatically (see documentation/index.md's
  // "Accessibility (VoiceOver)" section). This just additionally asks for
  // a spoken announcement the instant the message finishes streaming.
  bubble.accessibilityAnnouncesOnComplete = true;
  streamInto(bubble, 'This message triggers a VoiceOver announcement the moment it finishes streaming.', 'word');
});

dynamicTypeButton.addEventListener('click', () => {
  const bubble = createBubble();
  bubble.adjustsFontForContentSizeCategory = true;
  streamInto(bubble, "This bubble follows the system's text size. Change it in Settings > Accessibility > Display & Text Size > Larger Text while it's on screen.", 'word');
});

clearButton.addEventListener('click', () => {
  const children = stack.children ? stack.children.slice() : [];
  children.forEach((child) => stack.remove(child));
  longIndex = 0;
});

win.open();

// TODO: once you're happy with the behavior here, swap streamInto()'s
// setInterval simulation for real chunks from Ti.Network.Manager, e.g.:
//
// const bubble = createBubble();
// bubble.markdown = true; // if your model streams markdown-formatted responses
// NetworkManager.stream({
//   url: 'https://api.example.com/chat',
//   onChunk: (chunk) => { bubble.appendText(chunk); scrollToBottom(); },
//   onDone: () => bubble.complete()
// });
