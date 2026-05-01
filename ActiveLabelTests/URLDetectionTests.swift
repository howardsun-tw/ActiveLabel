import XCTest
@testable import ActiveLabel

final class URLDetectionTests: XCTestCase {

    var label: ActiveLabel!

    override func setUp() {
        super.setUp()
        label = ActiveLabel()
    }

    private var urlElements: [ActiveElement] {
        return (label.activeElements[.url] ?? []).map { $0.element }
    }

    private func urlString(_ element: ActiveElement) -> String? {
        if case .url(let original, _) = element { return original }
        return nil
    }

    @MainActor private func createURLResult(_ text: String,
                                            excluding excludedRanges: [NSRange]) -> URLBuildResult {
        return ActiveBuilder.createURLElements(
            from: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            maximumLength: nil,
            excluding: excludedRanges
        )
    }

    // §5.1 row 6: bare domain now matches.
    func testBareDomainMatches() {
        label.text = "google.com"
        XCTAssertEqual(urlElements.count, 1)
        XCTAssertEqual(urlElements.first.flatMap(urlString), "google.com")
    }

    // §5.1 row 1: scheme-prefixed URL still matches with full string.
    func testSchemePrefixedURLStillMatches() {
        label.text = "http://www.google.com"
        XCTAssertEqual(urlElements.count, 1)
        XCTAssertEqual(urlElements.first.flatMap(urlString), "http://www.google.com")
    }

    // §5.1 row 3: trailing punctuation excluded.
    func testTrailingDotExcluded() {
        label.text = "http://www.google.com."
        XCTAssertEqual(urlElements.count, 1)
        XCTAssertEqual(urlElements.first.flatMap(urlString), "http://www.google.com")
    }

    // Negative case: short non-domain word does not register.
    func testShortNonDomainWordIgnored() {
        label.text = "picfoo"
        XCTAssertEqual(urlElements.count, 0)
    }

    // §5.2: NSDataDetector matches "mailto:foo@bar.com" as a link with scheme
    // mailto. ActiveBuilder must filter these out so emails route through
    // the email regex pipeline. Spec requires both halves: zero .url elements
    // AND exactly one .email element.
    func testMailtoLinkFilteredOut() {
        label.enabledTypes = [.url, .email]
        label.text = "send to mailto:foo@bar.com today"
        XCTAssertEqual(urlElements.count, 0,
                       "mailto: links must be filtered so the email regex owns them")
        XCTAssertEqual(label.activeElements[.email]?.count, 1,
                       "email regex must still detect the address after the URL filter")
    }

    // Regression for the duplicate-URL trim bug. The old implementation used
    // text.replacingOccurrences(of: word, with: trimmedWord) which rewrote
    // BOTH copies on the first hit and then range(of: trimmedWord) only
    // located the first one — so the second URL element pointed at the
    // wrong range. New impl rewrites per-match right-to-left.
    func testDuplicateLongURLsTrimmedIndependently() {
        let url = "https://very-long-url.example.com/path"
        label.urlMaximumLength = 25
        label.text = "see \(url)/a and \(url)/b"

        XCTAssertEqual(urlElements.count, 2)
        // Both elements should report the original (untrimmed) URL.
        let originals = urlElements.compactMap(urlString)
        XCTAssertEqual(originals.filter { $0 == "\(url)/a" }.count, 1)
        XCTAssertEqual(originals.filter { $0 == "\(url)/b" }.count, 1)
    }

    @MainActor func testURLDetectorSkipsExcludedRanges() {
        let text = "Go to https://inside.example now"
        let excluded = (text as NSString).range(of: "https://inside.example")

        let result = ActiveBuilder.createURLElements(
            from: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            maximumLength: nil,
            excluding: [excluded]
        )

        XCTAssertEqual(result.elements.count, 0)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.replacements.count, 0)
    }

    @MainActor func testURLDetectorReportsTrimReplacement() {
        let text = "Go to https://very-long.example/path now"
        let result = ActiveBuilder.createURLElements(
            from: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            maximumLength: 20,
            excluding: []
        )

        XCTAssertEqual(result.elements.count, 1)
        XCTAssertEqual(result.text, "Go to https://very-long.ex... now")
        XCTAssertEqual(result.replacements.count, 1)
        XCTAssertEqual(result.replacements.first?.range, (text as NSString).range(of: "https://very-long.example/path"))
        XCTAssertEqual(result.replacements.first?.replacement, "https://very-long.ex...")
        XCTAssertEqual(result.replacements.first?.delta, -7)
    }

    @MainActor func testZeroLengthExcludedRangeInsideURLDoesNotSuppressDetection() {
        let text = "Go to https://inside.example now"
        let urlRange = (text as NSString).range(of: "https://inside.example")
        let excluded = NSRange(location: urlRange.location + 5, length: 0)

        let result = createURLResult(text, excluding: [excluded])

        XCTAssertEqual(result.elements.count, 1)
        XCTAssertEqual(result.elements.first?.range, urlRange)
        XCTAssertEqual(result.elements.first.flatMap { urlString($0.element) }, "https://inside.example")
    }

    @MainActor func testAdjacentExcludedRangeDoesNotSuppressURLDetection() {
        let text = "Go to https://adjacent.example now"
        let urlRange = (text as NSString).range(of: "https://adjacent.example")
        let excluded = NSRange(location: urlRange.location + urlRange.length, length: 1)

        let result = createURLResult(text, excluding: [excluded])

        XCTAssertEqual(result.elements.count, 1)
        XCTAssertEqual(result.elements.first?.range, urlRange)
        XCTAssertEqual(result.elements.first.flatMap { urlString($0.element) }, "https://adjacent.example")
    }

    @MainActor func testPartiallyOverlappingExcludedRangeSuppressesURLDetection() {
        let text = "Go to https://partial.example now"
        let urlRange = (text as NSString).range(of: "https://partial.example")
        let excluded = NSRange(location: urlRange.location + 8, length: 7)

        let result = createURLResult(text, excluding: [excluded])

        XCTAssertEqual(result.elements.count, 0)
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.replacements.count, 0)
    }

    @MainActor func testExcludedRangeOnlySkipsMatchingURLWhenMultipleURLsExist() {
        let text = "Go to https://one.example and https://two.example now"
        let firstURLRange = (text as NSString).range(of: "https://one.example")
        let secondURLRange = (text as NSString).range(of: "https://two.example")

        let result = createURLResult(text, excluding: [secondURLRange])

        XCTAssertEqual(result.elements.count, 1)
        XCTAssertEqual(result.elements.first?.range, firstURLRange)
        XCTAssertEqual(result.elements.first.flatMap { urlString($0.element) }, "https://one.example")
    }

    @MainActor func testExcludedRangeUsesUTF16CoordinatesWithUnicodePrefix() {
        let prefix = "Tap 🙂 then "
        let text = "\(prefix)https://unicode.example now"
        let nsText = text as NSString
        let urlRange = nsText.range(of: "https://unicode.example")

        let result = createURLResult(text, excluding: [urlRange])

        XCTAssertEqual(urlRange.location, (prefix as NSString).length)
        XCTAssertEqual(result.elements.count, 0)
        XCTAssertEqual(result.text, text)
    }
}
