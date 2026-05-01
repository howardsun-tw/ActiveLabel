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
}
