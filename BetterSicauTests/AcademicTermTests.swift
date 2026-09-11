import XCTest
@testable import Better_Sicau

final class AcademicTermTests: XCTestCase {
    func testGeneratedRangeCoversEndpoints() {
        let terms = AcademicTerm.availableTerms(from: 2025, to: 2035)

        XCTAssertEqual(terms.count, 11 * 2)
        XCTAssertEqual(terms.first, "2025-2026-1")
        XCTAssertEqual(terms.last, "2035-2036-2")
        XCTAssertTrue(terms.contains("2035-2036-2"))
    }

    func testDefaultRangeEndsAt203520362() {
        XCTAssertEqual(AcademicTerm.availableTerms().last, "2035-2036-2")
        XCTAssertFalse(AcademicTerm.availableTerms().contains("2036-2037-1"))
    }

    func testGeneratedRangeRejectsInvertedBounds() {
        XCTAssertEqual(AcademicTerm.availableTerms(from: 2035, to: 2025), [])
    }

    func testGeneratedLabelsMatchNormalizer() {
        for term in AcademicTerm.availableTerms() {
            XCTAssertEqual(AcademicHTMLParser.normalizeTerm(term), term)
        }
    }
}
