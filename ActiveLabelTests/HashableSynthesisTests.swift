import XCTest
@testable import ActiveLabel

final class HashableSynthesisTests: XCTestCase {

    func testNoPayloadCasesAreEqualToThemselves() {
        XCTAssertEqual(ActiveType.mention, ActiveType.mention)
        XCTAssertEqual(ActiveType.hashtag, ActiveType.hashtag)
        XCTAssertEqual(ActiveType.url, ActiveType.url)
        XCTAssertEqual(ActiveType.email, ActiveType.email)
    }

    func testNoPayloadCasesAreNotEqualToOtherCases() {
        XCTAssertNotEqual(ActiveType.mention, ActiveType.hashtag)
        XCTAssertNotEqual(ActiveType.url, ActiveType.email)
    }

    func testCustomCasesEqualByPattern() {
        XCTAssertEqual(ActiveType.custom(pattern: "abc"),
                       ActiveType.custom(pattern: "abc"))
        XCTAssertNotEqual(ActiveType.custom(pattern: "abc"),
                          ActiveType.custom(pattern: "xyz"))
    }

    func testSetMembershipDeduplicates() {
        let set: Set<ActiveType> = [
            .mention, .mention,
            .custom(pattern: "a"), .custom(pattern: "a"),
            .custom(pattern: "b")
        ]
        XCTAssertEqual(set.count, 3)
        XCTAssertTrue(set.contains(.mention))
        XCTAssertTrue(set.contains(.custom(pattern: "a")))
        XCTAssertTrue(set.contains(.custom(pattern: "b")))
    }

    func testHashConsistencyWithEquality() {
        let a = ActiveType.custom(pattern: "same")
        let b = ActiveType.custom(pattern: "same")
        var ha = Hasher()
        var hb = Hasher()
        a.hash(into: &ha)
        b.hash(into: &hb)
        XCTAssertEqual(ha.finalize(), hb.finalize())
    }
}
