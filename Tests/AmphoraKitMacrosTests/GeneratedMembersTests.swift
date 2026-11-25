import CoreData
import Testing
import AmphoraKit
import AmphoraKitTestSupport

/// The members `@Entity` and `@Stored` generate, used the way an app would.
@Suite("Generated members")
@MainActor
struct GeneratedMembersTests {

    private func makeDatabase() throws -> Database<MacroSchema> {
        let database = Database<MacroSchema>.ephemeral(name: "Macros")
        try database.setup()
        return database
    }

    @discardableResult
    private func seed(in database: Database<MacroSchema>) throws -> MacroFolder {
        let context = database.viewContext
        let folder = MacroFolder(context: context.nsContext)
        folder.a_id = "f1"
        folder.a_name = "Inbox"
        for (index, name) in ["a", "b", "c"].enumerated() {
            let item = MacroItem(context: context.nsContext)
            item.a_id = "i\(index)"
            item.a_name = name
            item.a_score = Double(index)
            item.isPinned = index == 1
            item.kind = index == 2 ? .urgent : .plain
            item.position = index == 0 ? TestItem.Position(bar: 1, beat: index + 1) : nil
            item.a_secret = "s"
            item.r_folder = index < 2 ? folder : nil
        }
        try context.save()
        return folder
    }

    @Test("Generated accessors read and write the storage with the right conversion")
    func accessors() throws {
        let database = try makeDatabase()
        let folder = try seed(in: database)
        let context = database.viewContext

        let b = try #require(try MacroItem.fetchFirst(matching: .name("b"), in: context))
        #expect(b.id == "i1")
        #expect(b.name == "b")
        #expect(b.isPinned)
        #expect(b.kind == .plain)
        #expect(b.position == nil)
        #expect(b.folder === folder)
        #expect(folder.items.count == 2)

        let a = try #require(try MacroItem.fetchFirst(matching: .name("a"), in: context))
        #expect(a.position == TestItem.Position(bar: 1, beat: 1))
        #expect(a.a_position == "1-1")

        a.kind = .urgent
        #expect(a.a_kind == "urgent")
        a.a_kind = "garbage"
        #expect(a.kind == .plain)
    }

    @Test("Both query syntaxes resolve on the generated members")
    func querySyntaxes() throws {
        let database = try makeDatabase()
        try seed(in: database)
        let context = database.viewContext

        let listForm = try MacroItem.fetch(matching: [.isPinned(false), .score(.greaterOrEqual(1))], sortedBy: [.name], in: context)
        #expect(listForm.map(\.name) == ["c"])

        let expressionForm = try MacroItem.fetch(matching: MacroItem.isPinned == false && MacroItem.score >= 1, sortedBy: [.score.descending], in: context)
        #expect(expressionForm.map(\.name) == ["c"])

        let mixed = try MacroItem.fetch(matching: [.isPinned(false), MacroItem.score >= 1], in: context)
        #expect(mixed.map(\.name) == ["c"])

        let urgent = try MacroItem.count(matching: .kind(.urgent), in: context)
        #expect(urgent == 1)
        let plain = try MacroItem.count(matching: MacroItem.kind == .plain, in: context)
        #expect(plain == 2)
        let unpositioned = try MacroItem.count(matching: .position(.isNil), in: context)
        #expect(unpositioned == 2)
        let positioned = try MacroItem.count(matching: .position(TestItem.Position(bar: 1, beat: 1)), in: context)
        #expect(positioned == 1)
        let byIds = try MacroItem.count(matching: .id(.in(["i0", "i2"])), in: context)
        #expect(byIds == 2)
        let byIdField = try MacroItem.count(matching: MacroItem.id == "i0" || !(.name("a")), in: context)
        #expect(byIdField == 3)
        let inList = try MacroItem.count(matching: MacroItem.name ~= ["a", "zzz"], in: context)
        #expect(inList == 1)
    }

    @Test("Relationships are queried through the target's query and with collection matches")
    func relationships() throws {
        let database = try makeDatabase()
        try seed(in: database)
        let context = database.viewContext

        let inInbox = try MacroItem.count(matching: .folder(.name("Inbox")), in: context)
        #expect(inInbox == 2)
        let orphans = try MacroItem.count(matching: .folder(.isNil), in: context)
        #expect(orphans == 1)
        let orphansByField = try MacroItem.count(matching: MacroItem.folder == nil, in: context)
        #expect(orphansByField == 1)
        let foldersWithA = try MacroFolder.count(matching: .items(.any(.name("a"))), in: context)
        #expect(foldersWithA == 1)
        let foldersWithTwo = try MacroFolder.count(matching: .items(.count(.equal(2))), in: context)
        #expect(foldersWithTwo == 1)
        let emptyFolders = try MacroFolder.count(matching: .items(.isEmpty), in: context)
        #expect(emptyFolders == 0)
    }
}
