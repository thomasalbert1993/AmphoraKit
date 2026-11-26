import CoreData

/// An entity whose objects a relationship can leave out when it reads them, beyond the zombies
/// and the soft-deleted objects every relationship already leaves out.
///
/// The relationships declared with `@Relationship`, and the accessors `@Entity` generates, read
/// their target through it — `nil` for a to-one, removed for a to-many — unless declared
/// `.unfiltered`:
///
/// ```swift
/// class Asset: …, RelationshipFiltering {
///     var isReadThroughToOneRelationships: Bool { true }              // a placeholder stays a link
///     var isReadThroughToManyRelationships: Bool { !isPlaceholder }   // but isn't listed
/// }
///
/// @Relationship var rentalHouses: [RentalHouse]               // no placeholders, no soft-deleted
/// @Relationship(.unfiltered) var allRentalHouses: [RentalHouse] // zombies removed only
/// ```
///
/// The filter is picked at compile time from the target type of the relationship: declare the
/// requirements in the class body, not in an extension, so that a subclass can override them.
/// Fetches and queries are left as they are.
///
public protocol RelationshipFiltering: DatabaseObject {

    /// Whether a to-one relationship reads the object, `nil` otherwise.
    var isReadThroughToOneRelationships: Bool { get }

    /// Whether a to-many relationship keeps the object.
    var isReadThroughToManyRelationships: Bool { get }
}
