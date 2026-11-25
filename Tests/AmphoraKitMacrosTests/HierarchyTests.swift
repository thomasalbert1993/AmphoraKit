import CoreData
import Testing
import AmphoraKit
import AmphoraKitTestSupport

/// Entity hierarchies declared with `@Entity`, used the way an app would.
@Suite("Entity hierarchies")
@MainActor
struct HierarchyTests {

    private func makeDatabase() throws -> Database<HierarchySchema> {
        let database = Database<HierarchySchema>.ephemeral(name: "Hierarchy")
        try database.setup()
        let context = database.viewContext.nsContext

        let zeiss = HierarchyBrand(context: context)
        zeiss.a_id = "brand-zeiss"
        zeiss.a_name = "Zeiss"
        zeiss.a_label = "ZEISS"

        let generic = HierarchyDynamicAsset(context: context)
        generic.a_id = "dynamic-1"
        generic.a_name = "Generic"
        generic.a_provider = "rental"

        for (id, mount, provider) in [("lens-pl", "PL", "rental"), ("lens-ef", "EF", "own"), ("lens-lpl", "LPL", "rental")] {
            let lens = HierarchyLens(context: context)
            lens.a_id = id
            lens.a_name = "Lens \(mount)"
            lens.a_mount = mount
            lens.a_provider = provider
            lens.r_brand = mount == "EF" ? nil : zeiss
        }
        try context.save()
        return database
    }

    @Test("a fetch on the root returns every sub-entity")
    func polymorphicRootFetch() throws {
        let database = try makeDatabase()
        let assets = try HierarchyAsset.fetch(sortedBy: [.id], in: database.viewContext)
        #expect(assets.map(\.id) == ["brand-zeiss", "dynamic-1", "lens-ef", "lens-lpl", "lens-pl"])
        #expect(assets.first is HierarchyBrand)
        #expect(try HierarchyAsset.count(matching: .name("Zeiss"), in: database.viewContext) == 1)
    }

    @Test("a fetch on a sub-entity returns it and its descendants only, typed")
    func subEntityFetch() throws {
        let database = try makeDatabase()
        let dynamicAssets: [HierarchyDynamicAsset] = try HierarchyDynamicAsset.fetch(sortedBy: [.id], in: database.viewContext)
        #expect(dynamicAssets.map(\.id) == ["dynamic-1", "lens-ef", "lens-lpl", "lens-pl"])
        let lenses: [HierarchyLens] = try HierarchyLens.fetch(in: database.viewContext)
        #expect(lenses.count == 3)
        #expect(try HierarchyBrand.count(in: database.viewContext) == 1)
    }

    @Test("a sub-entity's query has its own members and every ancestor's")
    func inheritedQueryMembers() throws {
        let database = try makeDatabase()
        let query: HierarchyLens.Query = .mount(.in(["PL", "LPL"])) && .provider("rental") && .name(.hasPrefix("Lens")) && !.id("lens-lpl")
        let lenses = try HierarchyLens.fetch(matching: [query], in: database.viewContext)
        #expect(lenses.map(\.id) == ["lens-pl"])

        // the members of a parent return the sub-entity's query
        let byProvider: HierarchyLens.Query = .provider("own")
        #expect(try HierarchyLens.fetch(matching: [byProvider], in: database.viewContext).map(\.a_mount) == ["EF"])
    }

    @Test("a relationship to a sub-entity is queried with the target's query, its parent's members included")
    func relationshipToSubEntity() throws {
        let database = try makeDatabase()
        let query: HierarchyLens.Query = .brand(.label("ZEISS") && .name("Zeiss"))
        #expect(try HierarchyLens.count(matching: [query], in: database.viewContext) == 2)
        let unbranded: HierarchyLens.Query = .brand(.isNil)
        #expect(try HierarchyLens.fetch(matching: [unbranded], in: database.viewContext).map(\.a_mount) == ["EF"])
    }

    @Test("a sub-entity's sort has its own members and every ancestor's")
    func inheritedSortMembers() throws {
        let database = try makeDatabase()
        let byMount: HierarchyLens.Sort = .mount
        #expect(try HierarchyLens.fetch(sortedBy: [byMount], in: database.viewContext).map(\.a_mount) == ["EF", "LPL", "PL"])
        let byNameDescending: HierarchyLens.Sort = HierarchyLens.Sort.name.descending
        #expect(try HierarchyLens.fetch(sortedBy: [byNameDescending], in: database.viewContext).map(\.a_mount) == ["PL", "LPL", "EF"])
    }

    @Test("a sub-entity's assignments write its own columns and its ancestors'")
    func inheritedAssignments() throws {
        let database = try makeDatabase()
        let lens = try HierarchyLens.fetch(id: "lens-ef", in: database.viewContext)
        let assignments: [HierarchyLens.Assignment] = [.mount("RF"), .provider("rental"), .name("Lens RF")]
        lens.update(with: assignments)
        #expect(lens.a_mount == "RF")
        #expect(lens.a_provider == "rental")
        #expect(lens.a_name == "Lens RF")
    }

    @Test("a sub-entity's stored values read its own columns and its ancestors'")
    func inheritedStoredValues() throws {
        let database = try makeDatabase()
        let lens = try HierarchyLens.fetch(id: "lens-pl", in: database.viewContext)
        #expect(lens.stored.mount == "PL")
        #expect(lens.stored.provider == "rental")
        #expect(lens.stored.name == "Lens PL")
        #expect(lens.stored.brand?.a_label == "ZEISS")

        // read through the parent's type, the override still answers
        let asset: HierarchyAsset = lens
        #expect(asset.stored.name == "Lens PL")
        #expect((asset.stored as? HierarchyLens.StoredValues)?.mount == "PL")
    }

    @Test("the identifier belongs to the root and is shared by the sub-entities")
    func sharedIdentifier() throws {
        let database = try makeDatabase()
        #expect(try HierarchyAsset.fetch(id: "lens-pl", in: database.viewContext) is HierarchyLens)
        #expect(try HierarchyLens.fetch(ids: ["lens-pl", "lens-ef"], in: database.viewContext).count == 2)
        #expect(throws: DatabaseError.self) { try HierarchyBrand.fetch(id: "lens-pl", in: database.viewContext) }
    }

    // MARK: Entry points

    @Test("a sub-entity's entry points take its own queries and sorts by implicit member")
    func implicitMembers() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        #expect(try HierarchyLens.fetch(matching: [.mount("PL"), .provider("rental")], in: context).map(\.id) == ["lens-pl"])
        #expect(try HierarchyLens.fetch(matching: .brand(.label("ZEISS")), sortedBy: [.mount.descending], in: context).map(\.a_mount) == ["PL", "LPL"])
        #expect(try HierarchyLens.fetchFirst(matching: .name(.hasPrefix("Lens")), sortedBy: [.name], in: context)?.a_mount == "EF")
        #expect(try HierarchyLens.count(matching: .provider("rental"), in: context) == 2)
        #expect(HierarchyLens.fetchOrEmpty(matching: [.id("lens-ef")], in: context).count == 1)
        #expect(HierarchyLens.fetchFirstOrNil(matching: .mount("LPL"), in: context)?.id == "lens-lpl")
        #expect(try HierarchyDynamicAsset.count(matching: .provider("rental"), in: context) == 3)
        #expect(try HierarchyBrand.fetch(matching: .label("ZEISS"), in: context).count == 1)
    }

    @Test("empty, default and shared members resolve without ambiguity")
    func noAmbiguity() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        #expect(try HierarchyLens.fetch(in: context).count == 3)
        #expect(try HierarchyLens.fetch(matching: [], in: context).count == 3)
        #expect(try HierarchyLens.fetch(matching: .all, in: context).count == 3)
        #expect(try HierarchyLens.fetch(matching: .id("lens-pl"), in: context).count == 1)
        #expect(try HierarchyLens.count(in: context) == 3)
        #expect(try HierarchyDynamicAsset.fetch(in: context).count == 4)
        #expect(try HierarchyAsset.fetch(in: context).count == 5)
    }

    @Test("generic code over the root sees the sub-entity through the root's types")
    func genericCode() throws {
        func names<T: DatabaseObject>(_ type: T.Type, in context: DatabaseContext<T.Schema>) throws -> Int {
            try T.fetch(matching: [], in: context).count
        }
        let database = try makeDatabase()
        #expect(try names(HierarchyLens.self, in: database.viewContext) == 3)
    }

    @Test("a sub-entity's request feeds fetch(request:) and a FetchController")
    func requests() async throws {
        let database = try makeDatabase()
        let request = HierarchyLens.request(matching: [.provider("rental")], sortedBy: [.mount])
        #expect(try HierarchyLens.fetch(request: request, in: database.viewContext).map(\.a_mount) == ["LPL", "PL"])

        let controller = FetchController(request, in: database, coalescingInterval: 0)
        #expect(controller.results.map(\.a_mount) == ["LPL", "PL"])
        let lenses: [HierarchyLens] = controller.results
        #expect(lenses.count == 2)
    }

    @Test("a sub-entity's batch requests and object updates take its own assignments")
    func batchAndUpdates() async throws {
        let database = try makeDatabase()
        try await database.enqueueBackgroundTaskAndSave { context in
            try HierarchyLens.update(matching: .mount("EF"), set: [.provider("rental"), .name("Lens EF II")], in: context)
            try HierarchyLens.insert([[.id("lens-rf"), .mount("RF"), .provider("own"), .name("Lens RF")]], in: context)
        }
        try await awaitCondition { (try? HierarchyLens.count(in: database.viewContext)) == 4 }
        let context = database.viewContext
        #expect(try HierarchyLens.count(matching: .provider("rental"), in: context) == 3)
        #expect(try HierarchyLens.fetch(id: "lens-rf", in: context).a_mount == "RF")

        let lens = try HierarchyLens.fetch(id: "lens-rf", in: context)
        lens.update(with: [.mount("Z"), .name("Lens Z")])
        #expect(lens.a_mount == "Z" && lens.a_name == "Lens Z")

        try await database.enqueueBackgroundTaskAndSave { context in
            try HierarchyLens.deleteAll(matching: .provider("own"), in: context)
        }
        // lens-ef became a rental above: only lens-rf is left to delete
        try await awaitCondition { (try? HierarchyLens.count(in: database.viewContext)) == 3 }
        #expect(try HierarchyAsset.count(in: database.viewContext) == 5)
    }

    @Test("an abstract entity can't be created, its sub-entities can, and exists takes their own queries")
    func creationInAHierarchy() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        #expect(throws: DatabaseError.abstractEntity("HierarchyAsset")) { try HierarchyAsset.create(id: "x", in: context) }
        #expect(throws: DatabaseError.abstractEntity("HierarchyAsset")) { try HierarchyAsset.fetchOrCreate(id: "x", in: context) }
        // an existing object is still found through the abstract root
        #expect(try HierarchyAsset.fetchOrCreate(id: "lens-pl", in: context) is HierarchyLens)

        let lens = try HierarchyLens.create(id: "lens-new", in: context)
        #expect(lens.a_id == "lens-new")
        #expect(throws: DatabaseError.alreadyExists(entity: "HierarchyLens", id: "lens-pl")) { try HierarchyLens.create(id: "lens-pl", in: context) }
        // the identifier is the root's: a sibling can't take it, nor return it as its own
        #expect(throws: DatabaseError.alreadyExists(entity: "HierarchyBrand", id: "lens-pl")) { try HierarchyBrand.create(id: "lens-pl", in: context) }
        #expect(throws: DatabaseError.alreadyExists(entity: "HierarchyLens", id: "lens-pl")) { try HierarchyBrand.fetchOrCreate(id: "lens-pl", in: context) }

        #expect(try HierarchyLens.exists(matching: [.mount("PL"), .provider("rental")], in: context))
        #expect(try !HierarchyLens.exists(matching: .mount("XX"), in: context))
        #expect(try HierarchyLens.fetchFirst(id: "lens-ef", in: context)?.a_mount == "EF")
    }

    @Test("a sub-entity's columns and fields name its own storage")
    func columnsAndFields() {
        #expect(HierarchyLens.Columns.mount.key == "a_mount")
        #expect(HierarchyDynamicAsset.Columns.provider.key == "a_provider")
        #expect(HierarchyLens.mount.key == "a_mount")
    }
}
