import XCTest
import SwiftSyntax
@testable import AmphoraKitMacrosPlugin

final class InferredStorageTypeTests: XCTestCase {

    private func inferred(_ type: String) -> String {
        AttributeAnnotation.inferredStorageType(of: TypeSyntax(stringLiteral: type))
    }

    func testPlainTypesAreStoredAsTheyAre() {
        XCTAssertEqual(inferred("String"), "String")
        XCTAssertEqual(inferred("Int32?"), "Int32?")
        XCTAssertEqual(inferred("TimeInterval"), "TimeInterval")
        XCTAssertEqual(inferred("Foundation.Date"), "Foundation.Date")
        XCTAssertEqual(inferred("NSNumber?"), "NSNumber?")
    }

    func testCollectionsAreStoredAsTheyAre() {
        XCTAssertEqual(inferred("[String]"), "[String]")
        XCTAssertEqual(inferred("[String: String]?"), "[String: String]?")
        XCTAssertEqual(inferred("Set<String>"), "Set<String>")
    }

    func testCollectionsOfOtherTypesNameTheirElementsColumn() {
        XCTAssertEqual(inferred("[Kind]"), "[Kind.StoredColumn]")
        XCTAssertEqual(inferred("Set<ClockType>"), "Set<ClockType.StoredColumn>")
        XCTAssertEqual(inferred("Set<Kind>?"), "Set<Kind.StoredColumn>?")
        XCTAssertEqual(inferred("Array<Kind>"), "[Kind.StoredColumn]")
    }

    func testOtherTypesNameTheirStoredColumn() {
        XCTAssertEqual(inferred("Kind"), "Kind.StoredColumn")
        XCTAssertEqual(inferred("Note.Kind"), "Note.Kind.StoredColumn")
        XCTAssertEqual(inferred("BarBeatPosition?"), "BarBeatPosition.OptionalStoredColumn")
        XCTAssertEqual(inferred("Optional<Kind>"), "Kind.OptionalStoredColumn")
    }
}
