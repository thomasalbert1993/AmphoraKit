import XCTest
import SwiftSyntax
import SwiftParser
@testable import AmphoraKitMacrosPlugin

final class RelationshipOrderTests: XCTestCase {

    private func annotation(_ source: String) throws -> AttributeAnnotation {
        let file = Parser.parse(source: source)
        let variable = try XCTUnwrap(file.statements.first?.item.as(VariableDeclSyntax.self))
        let attribute = try XCTUnwrap(variable.attributes.first?.as(AttributeSyntax.self))
        return try AttributeAnnotation(variable, attribute: attribute, role: .relationship)
    }

    func testToManyReadsUnorderedByDefault() throws {
        let plain = try annotation("@Relationship var cues: [Cue]")
        XCTAssertFalse(plain.isSorted)
        XCTAssertNil(plain.explicitStorageName)
    }

    func testSortedOrderAndStorageNameCombine() throws {
        let sorted = try annotation("@Relationship(.sorted) var cues: [Cue]")
        XCTAssertTrue(sorted.isSorted)
        XCTAssertNil(sorted.explicitStorageName)

        let named = try annotation(#"@Relationship(.sorted, "r_cues") var cues: [Cue]"#)
        XCTAssertTrue(named.isSorted)
        XCTAssertEqual(named.explicitStorageName, "r_cues")

        let nameOnly = try annotation(#"@Relationship("r_cues") var cues: [Cue]"#)
        XCTAssertFalse(nameOnly.isSorted)
        XCTAssertEqual(nameOnly.explicitStorageName, "r_cues")
    }
}
