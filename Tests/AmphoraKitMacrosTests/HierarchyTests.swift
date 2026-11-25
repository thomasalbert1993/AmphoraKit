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

    @Test("a sub-entity's columns and fields name its own storage")
    func columnsAndFields() {
        #expect(HierarchyLens.Columns.mount.key == "a_mount")
        #expect(HierarchyDynamicAsset.Columns.provider.key == "a_provider")
        #expect(HierarchyLens.mount.key == "a_mount")
    }
}
