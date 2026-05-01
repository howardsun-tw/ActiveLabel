# Markdown Support Design

## Context

ActiveLabel is a `UILabel` subclass that detects and taps active text ranges for
mentions, hashtags, URLs, emails, and custom regex patterns. The current parser
works from plain or attributed text and uses TextKit 1 for drawing and hit
testing.

The package does not currently parse Markdown. Apps can assign
`attributedText`, but Markdown links such as `[Apple](https://apple.com)` are not
converted into ActiveLabel URL elements, and inline Markdown styling is left to
the app.

## Goal

Add best-effort Markdown support using native Apple APIs, with no third-party
Markdown dependency.

The primary user-facing API should be simple:

```swift
label.markdownText = """
# Title

Hello **bold**, *italic*, [Apple](https://apple.com), #tag, @user
"""
```

The feature should:

- Parse Markdown with Foundation `AttributedString(markdown:)`.
- Render Markdown styling through attributes that `UILabel` can display.
- Make Markdown links tappable through the existing ActiveLabel URL tap handler.
- Preserve existing mention, hashtag, bare URL, email, and custom regex behavior.
- Fall back to plain text on Markdown parse failure.

## Non-Goals

ActiveLabel will not become a full Markdown layout engine. `UILabel` cannot match
the layout behavior of a document renderer or `UITextView`. Support is limited to
what can be represented cleanly as attributed text and TextKit 1 ranges.

No HTML rendering, no embedded images, no tables, and no custom block layout are
included in this feature.

## Public API

Add `markdownText`:

```swift
open var markdownText: String?
```

Setting `markdownText` parses Markdown and assigns the parsed attributed content
to the label. Setting `text` or `attributedText` clears the stored Markdown input
so existing API behavior stays predictable.

Do not add public parsing options in the first version. The initial surface area
is intentionally limited to `markdownText`; parser knobs can be added later if
real app usage shows a concrete need.

## Internal Design

Add a focused Markdown helper named `MarkdownParser`, owned by the ActiveLabel
target.

Responsibilities:

- Parse source Markdown into `AttributedString`.
- Convert native Markdown attributes into `NSMutableAttributedString` attributes
  that `UILabel` displays reliably.
- Extract Markdown links as URL elements before ActiveLabel's normal regex pass.
- Return both rendered attributed text and metadata for Markdown links.

Suggested internal model:

```swift
struct MarkdownParseResult {
    let attributedString: NSMutableAttributedString
    let links: [MarkdownLink]
}

struct MarkdownLink {
    let range: NSRange
    let url: URL
}
```

The helper should keep parser-specific code out of `ActiveLabel.swift`, which is
already responsible for rendering, touches, and active element state.

## Styling Rules

Use Foundation Markdown parsing as the source of truth, then normalize only the
styles that `UILabel` can display:

- Strong emphasis: apply bold font trait.
- Emphasis: apply italic font trait.
- Strong + emphasis: apply bold and italic traits when possible.
- Inline code: apply monospaced font.
- Code blocks: apply monospaced font and preserve newlines from the native parse.
- Strikethrough, if present: apply `NSAttributedString.Key.strikethroughStyle`.
- Links: preserve visible link text and add ActiveLabel URL behavior.
- Headings: apply bold and modest relative font scaling by heading level.
- Lists and block quotes: preserve native parsed text and paragraph breaks; apply
  only safe paragraph attributes such as indentation when native attributes expose
  enough information.

When a font trait cannot be applied to the current font family, fall back to
system fonts with the requested trait.

## Active Element Flow

Markdown links must be integrated into the existing URL behavior:

1. `markdownText` setter parses Markdown into attributed display text.
2. ActiveLabel stores Markdown link ranges and their destination URLs.
3. `updateTextStorage(parseText:)` starts from the parsed attributed string.
4. URL elements from Markdown links are inserted into `activeElements[.url]`.
5. Existing URL detection still runs for bare URLs in the rendered text.
6. Tap handling calls the existing `handleURLTap` closure with the destination
   URL for Markdown links.

Markdown links should not require `.url` to be visually present in the displayed
text. For `[Apple](https://apple.com)`, the displayed range is `Apple`, while the
tap result is `https://apple.com`.

## Collision Rules

Overlap handling must stay deterministic:

- Markdown link ranges win over regex-detected URLs, mentions, hashtags, emails,
  and custom types inside the same range.
- Existing regex active elements outside Markdown link ranges still work.
- If two Markdown links overlap, preserve the native parser result order and keep
  the first valid range.

This avoids nested tap targets and keeps hit testing unambiguous.

## Error Handling

Markdown parse failures should not crash or throw through the public property.

Default fallback:

- Display the raw Markdown source as plain text.
- Continue normal ActiveLabel parsing for URLs, mentions, hashtags, emails, and
  custom regex types.
- Do not create Markdown link elements.

Invalid link URLs should be ignored as Markdown links, while the visible text
remains displayed.

## Tests

Add focused unit coverage:

- `markdownText` renders plain Markdown text without syntax markers where native
  parsing removes them.
- Bold and italic ranges carry expected font traits.
- Inline code uses a monospaced font.
- `[Apple](https://apple.com)` displays `Apple` and creates a URL element whose
  tap handler receives `https://apple.com`.
- Markdown link and bare URL in the same string both tap correctly.
- Markdown link containing `#tag` or `@user` taps as the link, not nested hashtag
  or mention.
- `#tag` and `@user` outside Markdown links remain tappable.
- Malformed Markdown falls back to plain text and does not crash.

Existing URL, email, hashtag, mention, hit-test, and customization tests should
continue to pass.

## Documentation

Update `README.md` with:

- A Markdown usage section.
- A note that support is native best effort, not full document rendering.
- A note that Markdown links use `handleURLTap`.
- Examples showing Markdown links alongside hashtags and mentions.

Update `CHANGELOG.md` with a feature entry.

## Validation Constraint

The implementation must validate native Markdown attribute behavior on
iOS 17/macCatalyst 17 during tests. If Foundation does not expose a specific
Markdown style in a stable way after `NSAttributedString` conversion, keep the
rendered text correct and document the style as best effort.
