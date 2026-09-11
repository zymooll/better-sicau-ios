import XCTest
@testable import Better_Sicau

final class FormEncodingTests: XCTestCase {
    func testGB18030FormEncodingUsesPlusAndPercentBytes() {
        let fields = [
            AcademicHTMLParser.FormField(name: "学期", value: "2025-2026-1"),
            AcademicHTMLParser.FormField(name: "课程名称", value: "高等数学 A"),
        ]
        let encoded = ClassicASPFormEncoder.string(fields)

        XCTAssertEqual(encoded, "%D1%A7%C6%DA=2025-2026-1&%BF%CE%B3%CC%C3%FB%B3%C6=%B8%DF%B5%C8%CA%FD%D1%A7+A")
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertTrue(encoded.contains("+"))
    }

    func testOverrideReplacesDuplicateFieldsWithoutChangingOrder() {
        let fields = [
            AcademicHTMLParser.FormField(name: "xueqi", value: "old"),
            AcademicHTMLParser.FormField(name: "keep", value: "yes"),
            AcademicHTMLParser.FormField(name: "xueqi", value: "duplicate"),
        ]
        let output = ClassicASPFormEncoder.overriding(fields, with: ["xueqi": "new"])
        XCTAssertEqual(output.map(\.name), ["xueqi", "keep"])
        XCTAssertEqual(output.first?.value, "new")
    }
}
