import CoreData
import Testing
import AmphoraKit
import AmphoraKitTestSupport

/// Entities sharing one prefix for attributes and relationships, Crewmate's shape.
@Suite("Shared prefix")
@MainActor
struct SharedPrefixTests {

    private func makeDatabase() throws -> Database<SharedPrefixSchema> {
        let database = Database<SharedPrefixSchema>.ephemeral(name: "SharedPrefix")
        try database.setup()
        let context = database.viewContext
        let zeiss = try SharedBrand.create(id: "brand-zeiss", in: context)
        zeiss.cd_label = "ZEISS"
        let lens = try SharedGear.create(id: "gear-lens", in: context)
        lens.cd_name = "Lens"
        lens.cd_weight = 1.2
        lens.cd_brand = zeiss
        lens.cd_rawContent = ["kind": "lens", "mount": "PL"]
        lens.cd_localizedName = ["fr": "Objectif", "en": "Lens"]
        lens.cd_keywords = ["lens", "pl"]
        lens.cd_publishedAt = .now
        let cap = try SharedGear.create(id: "gear-cap", in: context)
        cap.cd_name = "Cap"
        cap.cd_accessoryOf = [lens]
        let old = try SharedGear.create(id: "gear-old", in: context)
        old.cd_name = "Old"
        old.cd_deleted = true
        try context.nsContext.save()
        return database
    }

    @Test("attributes are told from relationships by their type")
    func classification() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        // attributes: standard values, queried by value and sorted
        #expect(try SharedGear.fetch(matching: .weight(.greaterThan(1)), sortedBy: [.name], in: context).map(\.id) == ["gear-lens"])
        #expect(try SharedAsset.count(matching: .name("Cap"), in: context) == 1)
        // to-one, by the target's query; to-many, by a collection match
        #expect(try SharedGear.fetch(matching: .brand(.label("ZEISS")), in: context).map(\.id) == ["gear-lens"])
        #expect(try SharedGear.fetch(matching: .accessoryOf(.any(.name("Lens"))), in: context).map(\.id) == ["gear-cap"])
        #expect(try SharedBrand.fetch(matching: .gears(.count(.equal(1))), in: context).count == 1)
        // transformables stay attributes: nil matches work
        #expect(try SharedGear.count(matching: .rawContent(.isNil), in: context) == 1)
        #expect(try SharedGear.count(matching: .localizedName(.isNil), in: context) == 1)
    }

    @Test("accessors and stored values read every kind of column")
    func accessors() throws {
        let database = try makeDatabase()
        let lens = try SharedGear.fetch(id: "gear-lens", in: database.viewContext)
        #expect(lens.name == "Lens")
        #expect(lens.brand?.label == "ZEISS")
        #expect(lens.accessories.map(\.id) == ["gear-cap"])
        #expect(lens.rawContent?["mount"] as? String == "PL")
        #expect(lens.localizedName?["fr"] == "Objectif")
        #expect(lens.keywords == ["lens", "pl"])
        #expect(lens.stored.weight == 1.2)
        #expect(lens.stored.brand?.cd_label == "ZEISS")
    }

    @Test("assignments write every kind of column, a value holding Any included")
    func assignments() throws {
        let database = try makeDatabase()
        let cap = try SharedGear.fetch(id: "gear-cap", in: database.viewContext)
        let brand = try SharedBrand.fetch(id: "brand-zeiss", in: database.viewContext)
        cap.update(with: [.rawContent(["kind": "cap"]), .localizedName(["en": "Cap"]), .weight(0.1), .brand(brand)])
        #expect(cap.rawContent?["kind"] as? String == "cap")
        #expect(cap.cd_localizedName == ["en": "Cap"])
        #expect(cap.cd_brand === brand)
    }

    @Test("the base class keeps its identifier, soft deletion applies, creation checks the hierarchy")
    func baseClassAndRules() throws {
        let database = try makeDatabase()
        let context = database.viewContext
        #expect(try SharedGear.fetch(in: context).count == 2)
        #expect(try SharedGear.fetch(id: "gear-old", in: context).isSoftDeleted)
        #expect(try SharedAsset.fetch(id: "gear-lens", in: context).id == "gear-lens")
        #expect(throws: DatabaseError.abstractEntity("SharedAsset")) { try SharedAsset.create(id: "x", in: context) }
        #expect(throws: DatabaseError.alreadyExists(entity: "SharedGear", id: "gear-cap")) { try SharedGear.create(id: "gear-cap", in: context) }
    }
}
