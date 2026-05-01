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
    // the email regex pipeline.
    func testMailtoLinkFilteredOut() {
        label.enabledTypes = [.url, .email]
        label.text = "send to mailto:foo@bar.com today"
        XCTAssertEqual(urlElements.count, 0,
                       "mailto: links must be filtered so the email regex owns them")
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
}
