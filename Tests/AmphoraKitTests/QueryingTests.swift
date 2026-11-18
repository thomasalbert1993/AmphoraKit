import CoreData
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

struct QueryingTests {

    // MARK: Attribute matches

    @Test("the shorthand compares for equality")
    func shorthandIsEqual() {
        #expect(format(.name("x")) == #"name == "x""#)
        #expect(format(.isDone(true)) == "isDone == 1")
        #expect(format(.score(2)) == "score == 2")
    }

    @Test("comparisons render their operator")
    func comparisons() {
        #expect(format(.score(.greaterThan(2))) == "score > 2")
        #expect(format(.score(.lessOrEqual(2.5))) == "score <= 2.5")
        #expect(format(.order(.notEqual(3))) == "order != 3")
        #expect(format(.score(.between(1, 5))) == "score BETWEEN {1, 5}")
    }

    @Test("membership renders IN, negated with NOT")
    func membership() {
        #expect(format(.name(.in(["a", "b"]))) == #"name IN {"a", "b"}"#)
        #expect(format(.name(.notIn(["a"]))) == #"NOT name IN {"a"}"#)
    }

    @Test("text operators carry their options")
    func text() {
        #expect(format(.name(.contains("x"))) == #"name CONTAINS "x""#)
        #expect(format(.name(.contains("x", .caseInsensitive))) == #"name CONTAINS[c] "x""#)
        #expect(format(.name(.hasPrefix("Cam", [.caseInsensitive, .diacriticInsensitive]))) == #"name BEGINSWITH[cd] "Cam""#)
        #expect(format(.name(.like("Cam*"))) == #"name LIKE "Cam*""#)
        #expect(format(.note(.hasSuffix("!"))) == #"note ENDSWITH "!""#)
    }

    @Test("optional attributes get nil checks and the wrapped comparisons")
    func optionals() {
        #expect(format(.note(.isNil)) == "note == nil")
        #expect(format(.note(.isNotNil)) == "note != nil")
        #expect(format(.note(nil)) == "note == nil")
        #expect(format(.note("m")) == #"note == "m""#)
        #expect(format(.note(.greaterThan("m"))) == #"note > "m""#)
    }

    @Test("stored enums compare on their raw value")
    func rawRepresentable() {
        #expect(format(.kind(.urgent)) == #"kindRaw == "urgent""#)
        #expect(format(.kind(.in([.urgent, .archived]))) == #"kindRaw IN {"urgent", "archived"}"#)
        #expect(format(.kind(.notEqual(.plain))) == #"kindRaw != "plain""#)
    }

    @Test("storage-convertible values compare on their storage")
    func storageConvertible() {
        #expect(format(.position(.init(bar: 1, beat: 4))) == #"positionRaw == "1-4""#)
        #expect(format(.position(.equal(nil))) == "positionRaw == nil")
        #expect(format(.position(.isNil)) == "positionRaw == nil")
        #expect(format(.position(.in([.init(bar: 1, beat: 1), .init(bar: 2, beat: 1)]))) == #"positionRaw IN {"1-1", "2-1"}"#)
    }

    // MARK: Composition

    @Test("queries compose with the boolean operators")
    func composition() {
        #expect(format(.name("x") && .score(.greaterThan(2))) == #"name == "x" AND score > 2"#)
        #expect(format(.name("x") || .name("y")) == #"name == "x" OR name == "y""#)
        #expect(format(!.isDone(true)) == "NOT isDone == 1")
        let long: TestItem.Query = .name("x") && .score(.greaterThan(2)) && !(.name(.in(["a", "b"]))) || .score(.lessThan(1)) && .isDone(false)
        #expect(format(long) == #"(name == "x" AND score > 2 AND (NOT name IN {"a", "b"})) OR (score < 1 AND isDone == 0)"#)
    }

    @Test("the expression form resolves on the entity fields")
    func expressionForm() {
        #expect(format(.name == "x" && .score > 2) == #"name == "x" AND score > 2"#)
        #expect(format(.order >= 3) == "order >= 3")
        #expect(format(.kind == .urgent) == #"kindRaw == "urgent""#)
        #expect(format(!(.name ~= ["a", "b"])) == #"NOT name IN {"a", "b"}"#)
        #expect(format(.note == nil) == "note == nil")
    }

    @Test("all(of:) ANDs a list and is nil for none")
    func allOf() {
        #expect(format(TestItem.Query.all(of: [.name("x"), .score(.greaterThan(2))])!) == #"name == "x" AND score > 2"#)
        #expect(TestItem.Query.all(of: []) == nil)
        #expect(format(.all) == "TRUEPREDICATE")
    }

    // MARK: Shared members

    @Test("identifiable entities get .id and .ids on their own key")
    func identifiers() {
        #expect(format(.id("i1")) == #"id == "i1""#)
        #expect(format(.ids(["i1", "i2"])) == #"id IN {"i1", "i2"}"#)
        #expect(format(.id(.hasPrefix("i"))) == #"id BEGINSWITH "i""#)
        #expect(format(.id == "i1") == #"id == "i1""#)
        #expect(folderFormat(.id("f1")) == #"a_id == "f1""#)
        #expect(folderFormat(.id == "f1") == #"a_id == "f1""#)
    }

    // MARK: Relationships

    @Test("a to-one relationship is traversed by re-rooting the target query")
    func toOne() {
        #expect(format(.folder(.name("f"))) == #"folder.a_name == "f""#)
        #expect(format(.folder(.id("f1"))) == #"folder.a_id == "f1""#)
        #expect(format(.folder(.name("f") && .items(.isEmpty))) == #"folder.a_name == "f" AND folder.r_items.@count == 0"#)
        #expect(format(.folder(.isNil)) == "folder == nil")
    }

    @Test("a to-many relationship renders SUBQUERY and counts")
    func toMany() {
        #expect(folderFormat(.items(.any(.isDone(true)))) == "SUBQUERY(r_items, $x, $x.isDone == 1).@count > 0")
        #expect(folderFormat(.items(.none(.kind(.archived)))) == #"SUBQUERY(r_items, $x, $x.kindRaw == "archived").@count == 0"#)
        #expect(folderFormat(.items(.any(.isDone(true) && .score(.greaterThan(1))))) == "SUBQUERY(r_items, $x, $x.isDone == 1 AND $x.score > 1).@count > 0")
        #expect(folderFormat(.items(.count(.greaterThan(3)))) == "r_items.@count > 3")
        #expect(folderFormat(.items(.isEmpty)) == "r_items.@count == 0")
        #expect(folderFormat(.items(.isNotEmpty)) == "r_items.@count > 0")
    }

    // MARK: Escape hatch

    @Test("a raw format is wrapped as is")
    func unsafeFormat() {
        #expect(format(TestItem.Query(unsafeFormat: "score > %@", 3)) == "score > 3")
        #expect(format(TestItem.Query(unsafePredicate: NSPredicate(format: "order == 1"))) == "order == 1")
    }

    // MARK: Sort

    @Test("sorts carry key, direction and string comparison")
    func sorts() {
        let byName: TestItem.Sort = .name
        #expect(byName.nsSortDescriptor.key == "name")
        #expect(byName.nsSortDescriptor.ascending)
        #expect(TestItem.Sort.createdAt.descending.nsSortDescriptor.ascending == false)
        #expect(TestItem.Sort.createdAt.descending.ascending.nsSortDescriptor.ascending)
        #expect(TestItem.Sort.id.nsSortDescriptor.key == "id")
        #expect(TestFolder.Sort.id.nsSortDescriptor.key == "a_id")
        #expect(TestItem.Sort.name.comparing(.localizedStandard).nsSortDescriptor.selector == #selector(NSString.localizedStandardCompare(_:)))
    }

    // MARK: Evaluation and coding

    @Test("predicates evaluate against objects in memory")
    func evaluation() {
        let item = TestItem(entity: TestSchema.model.entitiesByName["TestItem"]!, insertInto: nil)
        item.id = "i1"
        item.name = "Camera 1"
        item.score = 3
        item.kind = .urgent
        item.position = .init(bar: 2, beat: 1)
        #expect((TestItem.Query.name(.hasPrefix("cam", .caseInsensitive)) && .score(.between(2, 4))).evaluate(with: item))
        #expect(TestItem.Query.kind(.urgent).evaluate(with: item))
        #expect(TestItem.Query.position(.init(bar: 2, beat: 1)).evaluate(with: item))
        #expect(!TestItem.Query.isDone(true).evaluate(with: item))
        #expect(TestItem.Query.note(.isNil).evaluate(with: item))
    }

    @Test("a match round-trips through Codable")
    func coding() throws {
        let match: Match<Double> = .between(1, 5)
        let data = try JSONEncoder().encode(match)
        let decoded = try JSONDecoder().decode(Match<Double>.self, from: data)
        #expect(decoded == match)
        let text: Match<String> = .contains("x", .caseInsensitive)
        #expect(try JSONDecoder().decode(Match<String>.self, from: JSONEncoder().encode(text)) == text)
    }

    // MARK: Helpers

    private func format(_ query: TestItem.Query) -> String {
        query.nsPredicate.predicateFormat
    }

    private func folderFormat(_ query: TestFolder.Query) -> String {
        query.nsPredicate.predicateFormat
    }
}
