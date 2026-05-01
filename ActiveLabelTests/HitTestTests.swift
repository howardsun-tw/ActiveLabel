import XCTest
@testable import ActiveLabel

final class HitTestTests: XCTestCase {

    private static let testFont = UIFont.systemFont(ofSize: 14)
    private static let testText = "#tag x"

    /// Builds a fully-laid-out ActiveLabel large enough to hold the text on a
    /// single line. We set `preferredMaxLayoutWidth` so that
    /// `intrinsicContentSize` populates `textContainer.size` (otherwise it
    /// stays at zero and `glyphIndex(for:)` can't be queried).
    private func makeLabel() -> ActiveLabel {
        let width: CGFloat = 300
        let label = ActiveLabel(frame: CGRect(x: 0, y: 0, width: width, height: 40))
        label.font = HitTestTests.testFont
        label.numberOfLines = 1
        label.preferredMaxLayoutWidth = width
        label.text = HitTestTests.testText
        // Force textContainer.size to be configured (intrinsicContentSize uses
        // preferredMaxLayoutWidth) so glyph indexing has a coordinate space.
        _ = label.intrinsicContentSize
        return label
    }

    /// Returns the centre x-coordinate of the glyph at the given character
    /// index, by measuring all preceding characters and half of the target
    /// character with the same font ActiveLabel is using. This avoids having
    /// to reach into ActiveLabel's private NSLayoutManager.
    private func centerX(charIndex: Int) -> CGFloat {
        let text = HitTestTests.testText as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: HitTestTests.testFont]
        let prefix = text.substring(to: charIndex) as NSString
        let prefixWidth = prefix.size(withAttributes: attrs).width
        let target = text.substring(with: NSRange(location: charIndex, length: 1)) as NSString
        let targetWidth = target.size(withAttributes: attrs).width
        return prefixWidth + targetWidth / 2
    }

    /// Off-by-one regression for ActiveLabel.element(at:): a tap that maps to
    /// the glyph index *immediately after* the last character of an active
    /// element previously matched that element because the bounds check used
    /// `<=`. The fix uses `<`.
    ///
    /// Strategy: lay out "#tag x" so the hashtag occupies indices 0..3, the
    /// space occupies index 4, and "x" occupies index 5. Tap the centre of
    /// the space glyph — `glyphIndex(for:)` returns 4, which equals
    /// `element.range.location + element.range.length` (0 + 4). With the bug
    /// (`<=`) this matches the hashtag; the fix (`<`) returns nil.
    func testTapJustPastElementEndDoesNotMatch() {
        let label = makeLabel()
        // Centre of the " " (space) glyph at character index 4.
        let x = centerX(charIndex: 4)
        // y must lie inside the glyph bounding rect. heightCorrection stays 0
        // until drawText(in:) runs, so the rect starts at y=0 and is roughly
        // one line height tall. Pick a y comfortably inside that band.
        let point = CGPoint(x: x, y: 4)
        XCTAssertNil(label.element(at: point),
                     "Tap on the character immediately past an element's range must not hit it")
    }

    /// Sanity-check companion: a tap clearly inside the hashtag glyph range
    /// must hit. Establishes that the off-by-one fix didn't shrink the hit
    /// region wrong.
    func testTapInsideElementHits() {
        let label = makeLabel()
        // Centre of the "a" glyph at character index 2 (inside #tag).
        let x = centerX(charIndex: 2)
        // y must lie inside the glyph bounding rect. heightCorrection stays 0
        // until drawText(in:) runs, so the rect starts at y=0 and is roughly
        // one line height tall. Pick a y comfortably inside that band.
        let point = CGPoint(x: x, y: 4)
        XCTAssertNotNil(label.element(at: point),
                        "Tap inside the hashtag glyph range must hit the element")
    }
}
