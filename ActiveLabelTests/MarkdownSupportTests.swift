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

        XCTAssertEqual(result.attributedString.string, "Title\n• one\n• two\n> quote")

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

        XCTAssertEqual(result.attributedString.string, "> a\n> b")
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
}
