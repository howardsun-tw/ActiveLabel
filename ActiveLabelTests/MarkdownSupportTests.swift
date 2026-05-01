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
}
