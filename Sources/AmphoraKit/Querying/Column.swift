import Foundation

/// An attribute in its stored form, or a relationship: its storage key and its storage type, for
/// the code that copies values as stored (a sync recopying the server's value as is) or links
/// objects by key.
///
/// `@Entity` declares one per attribute and relationship in the nested `Columns` enum
/// (`Note.Columns.kind: Column<Note, String>`, `Note.Columns.cue: Column<Note, Cue?>`,
/// `Note.Columns.tags: Column<Note, Set<Tag>>`), coded columns included. The queries use `Field`, typed by the domain
/// value instead: a `Column` carries no operator.
///
public struct Column<Root: DatabaseObject, Stored>: Sendable, Hashable {

    /// The storage key of the attribute.
    public let key: String

    /// Creates a column for a key.
    public init(key: String) {
        self.key = key
    }
}
