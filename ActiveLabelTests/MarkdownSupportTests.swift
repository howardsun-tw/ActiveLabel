import XCTest
@testable import ActiveLabel

final class MarkdownSupportTests: XCTestCase {

    private let baseFont = UIFont.systemFont(ofSize: 14)

    private func font(in attributedString: NSAttributedString, matching text: String) -> UIFont {
        let range = (attributedString.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find \(text)")
        let font = attributedString.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
        return font ?? UIFont.systemFont(ofSize: 1)
    }

    private func range(in attributedString: NSAttributedString, matching text: String) -> NSRange {
        let range = (attributedString.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find \(text)")
        return range
    }

    func testMarkdownParserAppliesInlineStylesAndLinks() {
        let result = MarkdownParser.parse(
            "Hello **bold**, *italic*, `code`, [Apple](https://apple.com)",
            baseFont: baseFont
        )

        XCTAssertEqual(result.attributedString.string, "Hello bold, italic, code, Apple")

        let boldFont = font(in: result.attributedString, matching: "bold")
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))

        let italicFont = font(in: result.attributedString, matching: "italic")
        XCTAssertTrue(italicFont.fontDescriptor.symbolicTraits.contains(.traitItalic))

        let codeFont = font(in: result.attributedString, matching: "code")
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))

        XCTAssertEqual(result.links.count, 1)
        XCTAssertEqual(result.links.first?.url.absoluteString, "https://apple.com")
        XCTAssertEqual(result.links.first?.range, (result.attributedString.string as NSString).range(of: "Apple"))
    }

    func testMarkdownParserBuildsUILabelFriendlyBlocks() {
        let result = MarkdownParser.parse(
            """
            # Title

            - **one**
            - two

            > quote
            """,
            baseFont: baseFont
        )

        XCTAssertEqual(result.attributedString.string, "Title\n• one\n• two\nquote")

        let titleFont = font(in: result.attributedString, matching: "Title")
        XCTAssertTrue(titleFont.pointSize > baseFont.pointSize)
        XCTAssertTrue(titleFont.fontDescriptor.symbolicTraits.contains(.traitBold))

        let oneFont = font(in: result.attributedString, matching: "one")
        XCTAssertTrue(oneFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testMarkdownParserKeepsMalformedMarkdownVisible() {
        let result = MarkdownParser.parse("[broken link](", baseFont: baseFont)

        XCTAssertEqual(result.attributedString.string, "[broken link](")
        XCTAssertEqual(result.links.count, 0)
    }

    func testMarkdownParserPreservesParagraphsInsideBlockQuotes() {
        let result = MarkdownParser.parse(
            """
            > a
            >
            > b
            """,
            baseFont: baseFont
        )

        XCTAssertEqual(result.attributedString.string, "a\nb")
    }

    // MARK: - Block-level paragraph styling

    private func paragraphStyle(in attributedString: NSAttributedString, matching text: String) -> NSParagraphStyle? {
        let range = (attributedString.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find \(text)")
        return attributedString.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    }

    private func backgroundColor(in attributedString: NSAttributedString, matching text: String) -> UIColor? {
        let range = (attributedString.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find \(text)")
        return attributedString.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? UIColor
    }

    private func foregroundColor(in attributedString: NSAttributedString, matching text: String) -> UIColor? {
        let range = (attributedString.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "Expected to find \(text)")
        return attributedString.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
    }

    func testBlockQuoteUsesParagraphIndentInsteadOfTextualPrefix() throws {
        let result = MarkdownParser.parse(
            """
            > quoted line
            """,
            baseFont: baseFont,
            textColor: .black
        )

        XCTAssertEqual(result.attributedString.string, "quoted line")
        let style = try XCTUnwrap(paragraphStyle(in: result.attributedString, matching: "quoted line"))
        XCTAssertEqual(style.firstLineHeadIndent, 12)
        XCTAssertEqual(style.headIndent, 12)
    }

    func testBlockQuoteFadesForegroundColor() throws {
        let result = MarkdownParser.parse("> quote", baseFont: baseFont, textColor: .black)
        let color = try XCTUnwrap(foregroundColor(in: result.attributedString, matching: "quote"))
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(nil, green: nil, blue: nil, alpha: &alpha))
        XCTAssertEqual(alpha, 0.8, accuracy: 0.01)
    }

func testFencedCodeBlockRunCarriesBackgroundColor() throws {
        let result = MarkdownParser.parse(
            """
            ```
            line one
            ```
            """,
            baseFont: baseFont,
            textColor: .black,
            codeBackgroundColor: .systemGray6
        )

        let bg = try XCTUnwrap(backgroundColor(in: result.attributedString, matching: "line one"))
        XCTAssertEqual(bg, .systemGray6)
    }

    func testInlineCodeRunCarriesBackgroundColor() throws {
        let result = MarkdownParser.parse(
            "Use `print` here",
            baseFont: baseFont,
            textColor: .black,
            codeBackgroundColor: .systemGray6
        )

        let bg = try XCTUnwrap(backgroundColor(in: result.attributedString, matching: "print"))
        XCTAssertEqual(bg, .systemGray6)
    }

    func testListItemAppliesHangingHeadIndent() throws {
        let result = MarkdownParser.parse(
            """
            - first
            - second
            """,
            baseFont: baseFont
        )

        let style = try XCTUnwrap(paragraphStyle(in: result.attributedString, matching: "first"))
        XCTAssertEqual(style.headIndent, 16)
    }

    func testHeaderCarriesHeaderParagraphStyle() throws {
        let result = MarkdownParser.parse("# Title", baseFont: baseFont)
        let style = try XCTUnwrap(paragraphStyle(in: result.attributedString, matching: "Title"))
        XCTAssertEqual(style.paragraphSpacing, 4)
        XCTAssertEqual(style.paragraphSpacingBefore, 4)
    }

    func testThematicBreakEmitsFadedDashes() throws {
        let result = MarkdownParser.parse(
            """
            top

            ---

            bottom
            """,
            baseFont: baseFont,
            textColor: .black
        )

        let dashes = String(repeating: "\u{2014}", count: 8)
        XCTAssertTrue(result.attributedString.string.contains(dashes), "expected em-dash run, got \(result.attributedString.string)")
        let color = try XCTUnwrap(foregroundColor(in: result.attributedString, matching: dashes))
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(nil, green: nil, blue: nil, alpha: &alpha))
        XCTAssertEqual(alpha, 0.3, accuracy: 0.01)
    }

    func testMarkdownParserPreservesParagraphsInsideListItems() {
        let result = MarkdownParser.parse(
            """
            - first

              second
            """,
            baseFont: baseFont
        )

        XCTAssertEqual(result.attributedString.string, "• first\n  second")
    }

    func testMarkdownParserBuildsOrderedLists() {
        let result = MarkdownParser.parse(
            """
            1. one
            2. two
            """,
            baseFont: baseFont
        )

        XCTAssertEqual(result.attributedString.string, "1. one\n2. two")
    }

    func testMarkdownParserTracksMultipleUnicodeLinks() {
        let result = MarkdownParser.parse(
            "[🍎](https://apple.com) and [台灣](https://example.tw)",
            baseFont: baseFont
        )

        XCTAssertEqual(result.attributedString.string, "🍎 and 台灣")
        XCTAssertEqual(result.links.count, 2)
        XCTAssertEqual(result.links[0].url.absoluteString, "https://apple.com")
        XCTAssertEqual(result.links[0].range, range(in: result.attributedString, matching: "🍎"))
        XCTAssertEqual(result.links[1].url.absoluteString, "https://example.tw")
        XCTAssertEqual(result.links[1].range, range(in: result.attributedString, matching: "台灣"))
    }

    func testMarkdownParserAppliesStrikethrough() {
        let result = MarkdownParser.parse("This is ~~gone~~", baseFont: baseFont)
        let range = range(in: result.attributedString, matching: "gone")

        XCTAssertEqual(result.attributedString.string, "This is gone")
        XCTAssertEqual(
            result.attributedString.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    private func urlOriginals(in label: ActiveLabel) -> [String] {
        return (label.activeElements[.url] ?? []).compactMap { tuple in
            if case .url(let original, _) = tuple.element {
                return original
            }
            return nil
        }
    }

    private func urlElements(in label: ActiveLabel) -> [(original: String, trimmed: String, range: NSRange)] {
        return (label.activeElements[.url] ?? []).compactMap { tuple in
            if case .url(let original, let trimmed) = tuple.element {
                return (original, trimmed, tuple.range)
            }
            return nil
        }
    }

    private func assertFontIsBold(
        in label: ActiveLabel,
        at location: Int,
        _ expected: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let font = try XCTUnwrap(
            label.textStorage.attribute(.font, at: location, effectiveRange: nil) as? UIFont,
            file: file,
            line: line
        )
        let isBold = font.fontDescriptor.symbolicTraits.contains(.traitBold)

        if expected {
            XCTAssertTrue(isBold, file: file, line: line)
        } else {
            XCTAssertFalse(isBold, file: file, line: line)
        }
    }

    private func assertForegroundColor(
        in label: ActiveLabel,
        at location: Int,
        equals expected: UIColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let color = try XCTUnwrap(
            label.textStorage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor,
            file: file,
            line: line
        )
        XCTAssertEqual(color, expected, file: file, line: line)
    }

    private func assertBackgroundColor(
        in label: ActiveLabel,
        at location: Int,
        equals expected: UIColor?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let color = label.textStorage.attribute(.backgroundColor, at: location, effectiveRange: nil) as? UIColor
        XCTAssertEqual(color, expected, file: file, line: line)
    }

    func testMarkdownTextDisplaysLinkTextAndStoresDestinationURL() {
        let label = ActiveLabel()
        label.markdownText = "Visit [Apple](https://apple.com) and #tag"

        XCTAssertEqual(label.markdownText, "Visit [Apple](https://apple.com) and #tag")
        XCTAssertEqual(label.text, "Visit Apple and #tag")
        XCTAssertEqual(urlOriginals(in: label), ["https://apple.com"])
        XCTAssertEqual(label.activeElements[.url]?.first?.range, (label.text! as NSString).range(of: "Apple"))
        XCTAssertEqual(label.activeElements[.hashtag]?.count, 1)
    }

    func testMarkdownLinkWinsOverNestedMentionAndHashtag() {
        let label = ActiveLabel()
        label.markdownText = "[#tag @user](https://example.com) #outside @outside"

        XCTAssertEqual(label.text, "#tag @user #outside @outside")
        XCTAssertEqual(urlOriginals(in: label), ["https://example.com"])
        XCTAssertEqual(label.activeElements[.hashtag]?.map { $0.element }, [.hashtag("outside")])
        XCTAssertEqual(label.activeElements[.mention]?.map { $0.element }, [.mention("outside")])
    }

    func testMarkdownLinkAndBareURLBothCreateURLElements() {
        let label = ActiveLabel()
        label.markdownText = "[Apple](https://apple.com) https://example.com"

        XCTAssertEqual(label.text, "Apple https://example.com")
        XCTAssertEqual(urlOriginals(in: label), ["https://apple.com", "https://example.com"])
    }

    func testMarkdownBareDomainBeforeExplicitLinkDoesNotConsumeMarkdownLinkAlignment() {
        let label = ActiveLabel()
        label.urlMaximumLength = 6
        label.markdownText = "google.com [Apple](https://apple.com)"

        XCTAssertEqual(label.text, "google... Apple")

        let elements = urlElements(in: label)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.map { $0.original }, ["https://apple.com", "google.com"])
        XCTAssertEqual(elements.first { $0.original == "google.com" }?.trimmed, "google...")
        XCTAssertEqual(elements.first { $0.original == "https://apple.com" }?.trimmed, "Apple")

        let text = label.text! as NSString
        XCTAssertEqual(elements.first { $0.original == "google.com" }?.range, text.range(of: "google..."))
        XCTAssertEqual(elements.first { $0.original == "https://apple.com" }?.range, text.range(of: "Apple"))
    }

    func testMarkdownBareURLTrimsLikePlainTextAndStoresOriginalURL() {
        let label = ActiveLabel()
        let originalURL = "https://very-long.example/path"
        let trimmedURL = String(originalURL.prefix(20)) + "..."
        label.urlMaximumLength = 20
        label.markdownText = "See \(originalURL)"

        XCTAssertEqual(label.text, "See \(trimmedURL)")
        XCTAssertEqual(urlOriginals(in: label), [originalURL])
        XCTAssertEqual(label.activeElements[.url]?.first?.range, (label.text! as NSString).range(of: trimmedURL))
    }

    func testExplicitMarkdownLinkUsesDestinationURLAndDoesNotTrimVisibleText() {
        let label = ActiveLabel()
        label.urlMaximumLength = 3
        label.markdownText = "Go [Apple](https://apple.com/very-long-path)"

        XCTAssertEqual(label.text, "Go Apple")
        XCTAssertEqual(urlOriginals(in: label), ["https://apple.com/very-long-path"])
        XCTAssertEqual(label.activeElements[.url]?.first?.range, (label.text! as NSString).range(of: "Apple"))
    }

    func testMarkdownBareURLsBeforeAndAfterExplicitLinkTrimWithCorrectRanges() {
        let label = ActiveLabel()
        let beforeURL = "https://before.example/long-path"
        let afterURL = "https://after.example/long-path"
        let markdownURL = "https://apple.com/path"
        let beforeTrimmed = String(beforeURL.prefix(16)) + "..."
        let afterTrimmed = String(afterURL.prefix(16)) + "..."
        label.urlMaximumLength = 16
        label.markdownText = "\(beforeURL) [Apple](\(markdownURL)) \(afterURL)"

        XCTAssertEqual(label.text, "\(beforeTrimmed) Apple \(afterTrimmed)")

        let elements = urlElements(in: label)
        XCTAssertEqual(Set(elements.map { $0.original }), Set([beforeURL, markdownURL, afterURL]))
        XCTAssertEqual(elements.first { $0.original == beforeURL }?.trimmed, beforeTrimmed)
        XCTAssertEqual(elements.first { $0.original == markdownURL }?.trimmed, "Apple")
        XCTAssertEqual(elements.first { $0.original == afterURL }?.trimmed, afterTrimmed)

        let text = label.text! as NSString
        XCTAssertEqual(elements.first { $0.original == beforeURL }?.range, text.range(of: beforeTrimmed))
        XCTAssertEqual(elements.first { $0.original == markdownURL }?.range, text.range(of: "Apple"))
        XCTAssertEqual(elements.first { $0.original == afterURL }?.range, text.range(of: afterTrimmed))
    }

    func testMarkdownBareURLBeforeIdenticalExplicitLinkTrimsOnlyBareURL() {
        let label = ActiveLabel()
        let url = "https://example.com/path"
        let trimmed = String(url.prefix(8)) + "..."
        label.urlMaximumLength = 8
        label.markdownText = "\(url) [\(url)](\(url))"

        XCTAssertEqual(label.text, "\(trimmed) \(url)")
        let elements = urlElements(in: label)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.map { $0.original }, [url, url])
        XCTAssertEqual(elements.first { $0.trimmed == trimmed }?.range, (label.text! as NSString).range(of: trimmed))
        XCTAssertEqual(elements.first { $0.trimmed == url }?.range, (label.text! as NSString).range(of: url))
    }

    func testMarkdownExplicitLinkBeforeIdenticalBareURLTrimsOnlyBareURL() {
        let label = ActiveLabel()
        let url = "https://example.com/path"
        let trimmed = String(url.prefix(8)) + "..."
        label.urlMaximumLength = 8
        label.markdownText = "[\(url)](\(url)) \(url)"

        XCTAssertEqual(label.text, "\(url) \(trimmed)")
        let elements = urlElements(in: label)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.map { $0.original }, [url, url])
        XCTAssertEqual(elements.first { $0.trimmed == trimmed }?.range, (label.text! as NSString).range(of: trimmed))
        XCTAssertEqual(elements.first { $0.trimmed == url }?.range, (label.text! as NSString).range(of: url))
    }

    func testMarkdownDuplicateIdenticalExplicitLinksBothRemainProtected() {
        let label = ActiveLabel()
        let url = "https://example.com/path"
        label.urlMaximumLength = 8
        label.markdownText = "[\(url)](\(url)) [\(url)](\(url))"

        XCTAssertEqual(label.text, "\(url) \(url)")
        let elements = urlElements(in: label)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.map { $0.original }, [url, url])
        XCTAssertEqual(elements.map { $0.trimmed }, [url, url])
    }

    func testMarkdownExplicitLinkWithEscapedParenthesesInDestinationRemainsProtected() {
        let label = ActiveLabel()
        label.markdownText = "[x](https://example.com/path\\(thing\\))"

        XCTAssertEqual(label.text, "x")
        XCTAssertEqual(urlOriginals(in: label), ["https://example.com/path(thing)"])
        XCTAssertEqual(label.activeElements[.url]?.first?.range, (label.text! as NSString).range(of: "x"))
    }

    func testMarkdownExplicitLinkPreservesNonEscapableDestinationBackslash() {
        let label = ActiveLabel()
        label.markdownText = "[x](https://example.com/a\\qb)"

        XCTAssertEqual(label.text, "x")
        XCTAssertEqual(urlOriginals(in: label), ["https://example.com/a%5Cqb"])
        XCTAssertEqual(label.activeElements[.url]?.first?.range, (label.text! as NSString).range(of: "x"))
    }

    func testMarkdownAngleBracketDestinationWithEscapedGreaterThanRemainsProtected() throws {
        let label = ActiveLabel()
        label.markdownText = "[x](<https://example.com/a\\>b>) [y](https://y.com)"

        XCTAssertEqual(label.text, "x y")
        XCTAssertEqual(urlOriginals(in: label), ["https://example.com/a%3Eb", "https://y.com"])

        let text = label.text! as NSString
        let elements = try XCTUnwrap(label.activeElements[.url])
        XCTAssertEqual(elements.count, 2)
        guard elements.count == 2 else { return }
        XCTAssertEqual(elements[0].range, text.range(of: "x"))
        XCTAssertEqual(elements[1].range, text.range(of: "y"))
    }

    func testMarkdownEscapedBangBeforeLinkDoesNotCreateImage() {
        let label = ActiveLabel()
        label.markdownText = "\\![x](https://example.com)"

        XCTAssertEqual(label.text, "!x")
        XCTAssertEqual(urlOriginals(in: label), ["https://example.com"])
        XCTAssertEqual(label.activeElements[.url]?.first?.range, (label.text! as NSString).range(of: "x"))
    }

    func testMarkdownInvalidUnquotedTitleDoesNotProtectBareURLs() {
        let label = ActiveLabel()
        let url = "https://example.com"
        let trimmed = String(url.prefix(8)) + "..."
        label.urlMaximumLength = 8
        label.markdownText = "[\(url)](\(url) badtitle)"

        XCTAssertEqual(label.text, "[\(trimmed)](\(trimmed) badtitle)")
        let elements = urlElements(in: label)
        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements.map { $0.original }, [url, url])
        XCTAssertEqual(elements.map { $0.trimmed }, [trimmed, trimmed])
    }

    func testMarkdownMalformedEarlierCandidateDoesNotStealLaterExplicitLink() {
        let label = ActiveLabel()
        let url = "https://example.com"
        let trimmed = String(url.prefix(8)) + "..."
        label.urlMaximumLength = 8
        label.markdownText = "[\(url)](\(url) badtitle) [\(url)](\(url))"

        XCTAssertEqual(label.text, "[\(trimmed)](\(trimmed) badtitle) \(url)")
        let elements = urlElements(in: label)
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements.filter { $0.trimmed == trimmed }.count, 2)
        XCTAssertEqual(elements.filter { $0.trimmed == url }.count, 1)
    }

    func testMarkdownExplicitLinkWithSingleQuotedTitleRemainsProtected() {
        let label = ActiveLabel()
        label.urlMaximumLength = 3
        label.markdownText = "[Apple](https://apple.com 'title')"

        XCTAssertEqual(label.text, "Apple")
        XCTAssertEqual(urlOriginals(in: label), ["https://apple.com"])
        XCTAssertEqual(label.activeElements[.url]?.first?.range, (label.text! as NSString).range(of: "Apple"))
    }

    func testActiveElementSpanningMixedMarkdownRunsPreservesRunAttributes() throws {
        let label = ActiveLabel()
        label.markdownText = "**#ta**g"

        XCTAssertEqual(label.text, "#tag")
        XCTAssertEqual(label.activeElements[.hashtag]?.map { $0.element }, [.hashtag("tag")])

        try assertFontIsBold(in: label, at: 1, true)
        try assertFontIsBold(in: label, at: 3, false)
    }

    func testHashtagColorChangeAfterMarkdownTextPreservesMixedRunAttributes() throws {
        let label = ActiveLabel()
        label.markdownText = "**#ta**g"
        label.hashtagColor = .red

        XCTAssertEqual(label.text, "#tag")
        XCTAssertEqual(label.activeElements[.hashtag]?.map { $0.element }, [.hashtag("tag")])
        try assertForegroundColor(in: label, at: 1, equals: .red)
        try assertForegroundColor(in: label, at: 3, equals: .red)
        try assertFontIsBold(in: label, at: 1, true)
        try assertFontIsBold(in: label, at: 3, false)
    }

    func testMentionColorChangeAfterMarkdownTextPreservesMixedRunAttributes() throws {
        let label = ActiveLabel()
        label.markdownText = "**@us**er"
        label.mentionColor = .red

        XCTAssertEqual(label.text, "@user")
        XCTAssertEqual(label.activeElements[.mention]?.map { $0.element }, [.mention("user")])
        try assertForegroundColor(in: label, at: 1, equals: .red)
        try assertForegroundColor(in: label, at: 4, equals: .red)
        try assertFontIsBold(in: label, at: 1, true)
        try assertFontIsBold(in: label, at: 4, false)
    }

    func testURLColorChangeAfterMarkdownTextPreservesMarkdownLinkFontAttributes() throws {
        let label = ActiveLabel()
        label.markdownText = "**[Apple](https://apple.com)**"
        label.URLColor = .red

        XCTAssertEqual(label.text, "Apple")
        XCTAssertEqual(urlOriginals(in: label), ["https://apple.com"])
        try assertForegroundColor(in: label, at: 1, equals: .red)
        try assertFontIsBold(in: label, at: 1, true)
    }

    func testConfigureLinkAttributeAfterMarkdownTextPreservesMixedRunAttributes() throws {
        let label = ActiveLabel()
        label.markdownText = "**#ta**g"
        label.configureLinkAttribute = { _, attributes, _ in
            var attributes = attributes
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return attributes
        }
        label.hashtagColor = .red

        XCTAssertEqual(label.text, "#tag")
        XCTAssertEqual(label.activeElements[.hashtag]?.map { $0.element }, [.hashtag("tag")])
        XCTAssertEqual(
            label.textStorage.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            label.textStorage.attribute(.underlineStyle, at: 3, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        try assertFontIsBold(in: label, at: 1, true)
        try assertFontIsBold(in: label, at: 3, false)
    }

    @MainActor
    func testMarkdownSelectionRemovesSelectedOnlyConfigureAttributesOnDeselect() async throws {
        let label = ActiveLabel()
        label.configureLinkAttribute = { _, attributes, isSelected in
            var attributes = attributes
            if isSelected {
                attributes[.backgroundColor] = UIColor.yellow
            }
            return attributes
        }
        label.markdownText = "**#ta**g"

        let exp = XCTestExpectation(description: "deselect fires")
        label.onDeselectForTest = { exp.fulfill() }
        label.simulateTapEnded(onElementAt: 0)

        assertBackgroundColor(in: label, at: 1, equals: .yellow)
        assertBackgroundColor(in: label, at: 3, equals: .yellow)
        try assertFontIsBold(in: label, at: 1, true)
        try assertFontIsBold(in: label, at: 3, false)

        await fulfillment(of: [exp], timeout: 1.0)

        assertBackgroundColor(in: label, at: 1, equals: nil)
        assertBackgroundColor(in: label, at: 3, equals: nil)
        try assertFontIsBold(in: label, at: 1, true)
        try assertFontIsBold(in: label, at: 3, false)
    }

    @MainActor
    func testPlainSelectionRemovesSelectedOnlyConfigureAttributesOnDeselect() async {
        let label = ActiveLabel()
        label.configureLinkAttribute = { _, attributes, isSelected in
            var attributes = attributes
            if isSelected {
                attributes[.backgroundColor] = UIColor.yellow
            }
            return attributes
        }
        label.text = "#tag"

        let exp = XCTestExpectation(description: "deselect fires")
        label.onDeselectForTest = { exp.fulfill() }
        label.simulateTapEnded(onElementAt: 0)

        assertBackgroundColor(in: label, at: 1, equals: .yellow)

        await fulfillment(of: [exp], timeout: 1.0)

        assertBackgroundColor(in: label, at: 1, equals: nil)
    }

    @MainActor
    func testQuickReselectionIsNotClearedByPreviousDeselectTask() async {
        let label = ActiveLabel()
        label.enabledTypes = [.hashtag]
        label.configureLinkAttribute = { _, attributes, isSelected in
            var attributes = attributes
            if isSelected {
                attributes[.backgroundColor] = UIColor.yellow
            }
            return attributes
        }
        label.text = "#one #two"

        label.simulateTapEnded(onElementAt: 0)
        assertBackgroundColor(in: label, at: 1, equals: .yellow)

        label.simulateSelectionBegan(onElementAt: 1)
        assertBackgroundColor(in: label, at: 1, equals: nil)
        assertBackgroundColor(in: label, at: 6, equals: .yellow)

        try? await Task.sleep(for: .milliseconds(350))

        assertBackgroundColor(in: label, at: 6, equals: .yellow)
    }

    @MainActor
    func testRestyleWhileSelectedLetsDeselectCompleteWithoutRestoringStaleAttributes() async throws {
        let label = ActiveLabel()
        label.configureLinkAttribute = { _, attributes, isSelected in
            var attributes = attributes
            if isSelected {
                attributes[.backgroundColor] = UIColor.yellow
            }
            return attributes
        }
        label.markdownText = "**#ta**g"

        let exp = XCTestExpectation(description: "deselect fires")
        label.onDeselectForTest = { exp.fulfill() }
        label.simulateTapEnded(onElementAt: 0)
        assertBackgroundColor(in: label, at: 1, equals: .yellow)

        label.hashtagColor = .red

        await fulfillment(of: [exp], timeout: 1.0)

        assertBackgroundColor(in: label, at: 1, equals: nil)
        assertBackgroundColor(in: label, at: 3, equals: nil)
        try assertForegroundColor(in: label, at: 1, equals: .red)
        try assertForegroundColor(in: label, at: 3, equals: .red)
        try assertFontIsBold(in: label, at: 1, true)
        try assertFontIsBold(in: label, at: 3, false)
    }

    func testMarkdownTextClearsWhenPlainTextIsAssignedInsideCustomize() {
        let label = ActiveLabel()
        label.markdownText = "[ab](https://example.com)"
        label.customize { $0.text = "#tag" }

        XCTAssertNil(label.markdownText)
        XCTAssertEqual(label.text, "#tag")
        XCTAssertEqual(label.activeElements[.url]?.count ?? 0, 0)
        XCTAssertEqual(label.activeElements[.hashtag]?.map { $0.element }, [.hashtag("tag")])
    }

    func testMarkdownTextClearsWhenPlainTextIsAssigned() {
        let label = ActiveLabel()
        label.markdownText = "[Apple](https://apple.com)"
        label.text = "#tag"

        XCTAssertNil(label.markdownText)
        XCTAssertEqual(label.activeElements[.url]?.count ?? 0, 0)
        XCTAssertEqual(label.activeElements[.hashtag]?.count, 1)
    }

    func testMarkdownTextClearsWhenAttributedTextIsAssigned() {
        let label = ActiveLabel()
        label.markdownText = "[ab](https://example.com)"
        label.attributedText = NSAttributedString(string: "#tag")

        XCTAssertNil(label.markdownText)
        XCTAssertEqual(label.text, "#tag")
        XCTAssertEqual(label.activeElements[.url]?.count ?? 0, 0)
        XCTAssertEqual(label.activeElements[.hashtag]?.map { $0.element }, [.hashtag("tag")])
    }

    func testMarkdownLinksProtectNestedElementsWhenURLTypeDisabled() {
        let label = ActiveLabel()
        label.enabledTypes = [.mention, .hashtag]
        label.markdownText = "[#tag @user](https://example.com) #outside @outside"

        XCTAssertEqual(label.text, "#tag @user #outside @outside")
        XCTAssertEqual(label.activeElements[.url]?.count ?? 0, 0)
        XCTAssertEqual(label.activeElements[.hashtag]?.map { $0.element }, [.hashtag("outside")])
        XCTAssertEqual(label.activeElements[.mention]?.map { $0.element }, [.mention("outside")])
    }

    @MainActor
    func testSelectionPreservesMixedMarkdownRunAttributes() async throws {
        let label = ActiveLabel()
        label.markdownText = "**#ta**g"

        let exp = XCTestExpectation(description: "deselect fires")
        label.onDeselectForTest = { exp.fulfill() }
        label.simulateTapEnded(onElementAt: 0)
        var boldFont = try XCTUnwrap(label.textStorage.attribute(.font, at: 1, effectiveRange: nil) as? UIFont)
        var plainFont = try XCTUnwrap(label.textStorage.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse(plainFont.fontDescriptor.symbolicTraits.contains(.traitBold))

        await fulfillment(of: [exp], timeout: 1.0)

        boldFont = try XCTUnwrap(label.textStorage.attribute(.font, at: 1, effectiveRange: nil) as? UIFont)
        plainFont = try XCTUnwrap(label.textStorage.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse(plainFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    // MARK: - Cache

    func testParseRepeatedInputReturnsEquivalentOutput() {
        MarkdownParser.clearCache()
        let text = "**hello** *world* `code` \(UUID().uuidString)"
        let first = MarkdownParser.parse(text, baseFont: baseFont)
        let second = MarkdownParser.parse(text, baseFont: baseFont)
        XCTAssertEqual(first.attributedString.string, second.attributedString.string)
        XCTAssertTrue(first.attributedString.isEqual(to: second.attributedString))
    }

    func testParseReturnsFreshMutableInstancesPerCall() {
        MarkdownParser.clearCache()
        let text = "**hello** \(UUID().uuidString)"
        let first = MarkdownParser.parse(text, baseFont: baseFont)
        let second = MarkdownParser.parse(text, baseFont: baseFont)
        XCTAssertFalse(first.attributedString === second.attributedString,
                       "Cache must hand out independent NSMutableAttributedString instances")
    }

    func testMutatingReturnedAttributedStringDoesNotPoisonCache() {
        MarkdownParser.clearCache()
        let text = "**stable** \(UUID().uuidString)"
        let first = MarkdownParser.parse(text, baseFont: baseFont)
        let originalLength = first.attributedString.length
        first.attributedString.append(NSAttributedString(string: "POISON"))

        let second = MarkdownParser.parse(text, baseFont: baseFont)
        XCTAssertEqual(second.attributedString.length, originalLength)
        XCTAssertFalse(second.attributedString.string.contains("POISON"))
    }

    func testDifferentBaseFontPointSizeProducesDistinctOutput() {
        MarkdownParser.clearCache()
        let text = "# heading"
        let small = MarkdownParser.parse(text, baseFont: UIFont.systemFont(ofSize: 12))
        let large = MarkdownParser.parse(text, baseFont: UIFont.systemFont(ofSize: 24))

        let smallFont = small.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let largeFont = large.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertNotEqual(smallFont?.pointSize, largeFont?.pointSize,
                          "Distinct base fonts must miss the cache and re-parse")
    }

    func testDifferentTextColorProducesDistinctOutput() {
        MarkdownParser.clearCache()
        let text = "plain run"
        let red = MarkdownParser.parse(text, baseFont: baseFont, textColor: .red)
        let green = MarkdownParser.parse(text, baseFont: baseFont, textColor: .green)

        let redColor = red.attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let greenColor = green.attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertEqual(redColor, .red)
        XCTAssertEqual(greenColor, .green)
    }

    func testDynamicTextColorKeyStableAcrossTraitChanges() {
        MarkdownParser.clearCache()
        let dynamicColor = UIColor { trait in
            trait.userInterfaceStyle == .dark ? .green : .red
        }

        var lightFirst: NSAttributedString!
        var darkSecond: NSAttributedString!
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            lightFirst = MarkdownParser.parse("dynamic body", baseFont: baseFont, textColor: dynamicColor).attributedString
        }
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            darkSecond = MarkdownParser.parse("dynamic body", baseFont: baseFont, textColor: dynamicColor).attributedString
        }

        let lightForeground = lightFirst.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        let darkForeground = darkSecond.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor

        let darkResolved = UITraitCollection(userInterfaceStyle: .dark)
        XCTAssertEqual(
            lightForeground?.resolvedColor(with: darkResolved).cgColor.components ?? [],
            darkForeground?.resolvedColor(with: darkResolved).cgColor.components ?? [],
            "Dynamic color identity must survive trait flip — same key in either mode"
        )
    }

    func testClearCacheForcesReparse() {
        MarkdownParser.clearCache()
        let text = "**reparse** \(UUID().uuidString)"
        let first = MarkdownParser.parse(text, baseFont: baseFont)
        let cached = MarkdownParser.parse(text, baseFont: baseFont)
        XCTAssertFalse(first.attributedString === cached.attributedString)

        MarkdownParser.clearCache()
        let afterClear = MarkdownParser.parse(text, baseFont: baseFont)
        XCTAssertFalse(cached.attributedString === afterClear.attributedString)
        XCTAssertEqual(first.attributedString.string, afterClear.attributedString.string)
    }

    func testCachedLinksReturnedOnHit() {
        MarkdownParser.clearCache()
        let text = "see [docs](https://example.com) for details"
        let first = MarkdownParser.parse(text, baseFont: baseFont)
        let cached = MarkdownParser.parse(text, baseFont: baseFont)
        XCTAssertEqual(first.links.count, 1)
        XCTAssertEqual(cached.links.count, 1)
        XCTAssertEqual(cached.links.first?.url, first.links.first?.url)
        XCTAssertEqual(cached.links.first?.range, first.links.first?.range)
    }
}
