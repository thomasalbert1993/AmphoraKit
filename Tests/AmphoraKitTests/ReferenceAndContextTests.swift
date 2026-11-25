import CoreData
import Foundation
import Testing
@testable import AmphoraKit
import AmphoraKitTestSupport

@MainActor
struct ReferenceAndContextTests {

    @Test("a reference crosses to a background task and resolves there")
    func referenceAcrossQueues() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a"])
        let item = try TestItem.fetch(id: "a", in: database.viewContext)
        let reference = item.reference
        #expect(reference.id == "a")

        let name = try await database.enqueueBackgroundTask { context in
            try reference.resolve(in: context)?.name
        }
        #expect(name == "a")
        #expect(try DatabaseObjectReference<TestItem>(id: "z").resolve(in: database.viewContext) == nil)
        #expect(Set([reference, DatabaseObjectReference(id: "a")]).count == 1)
    }

    @Test("references resolve in one fetch, in their order, the missing ones left out")
    func resolveMany() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a", "b", "c"])
        let references = ["c", "z", "a"].map(DatabaseObjectReference<TestItem>.init(id:))
        let names = try await database.enqueueBackgroundTask { context in
            try references.resolve(in: context).map(\.name)
        }
        #expect(names == ["c", "a"])
    }

    @Test("an object is found in another context once saved, not before")
    func objectInAnotherContext() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a"])
        let saved = try TestItem.fetch(id: "a", in: database.viewContext)
        let found = try await database.enqueueBackgroundTask { [objectID = saved.objectID] context in
            let object = try context.existingObject(with: objectID, as: TestItem.self)
            return object.in(context) === object
        }
        #expect(found)

        // a second main-queue context, usable from here
        let other = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        other.persistentStoreCoordinator = database.persistentContainer.persistentStoreCoordinator
        let otherContext = DatabaseContext<TestSchema>(unsafe: other)

        let unsaved = TestItem(context: database.viewContext)
        unsaved.id = "unsaved"
        #expect(unsaved.in(otherContext) == nil)
        #expect(saved.in(otherContext)?.name == "a")
        #expect(saved.in(database.viewContext) === saved)
        #expect([saved, unsaved].in(otherContext).map(\.name) == ["a"])
        database.viewContext.nsContext.rollback()
    }

    @Test("an object knows its context and whether it is the view context")
    func contexts() async throws {
        let (database, _) = try makeDatabase()
        try await database.seedItems(["a"])
        let item = try TestItem.fetch(id: "a", in: database.viewContext)
        #expect(item.isInViewContext)
        #expect(item.databaseContext == database.viewContext)
        let answers = try await database.enqueueBackgroundTask { context in
            let item = try TestItem.fetch(id: "a", in: context)
            return [item.isInViewContext, item.databaseContext == context]
        }
        #expect(answers == [false, true])
    }
}
