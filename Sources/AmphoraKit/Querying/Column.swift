import Foundation

/// An attribute in its stored form: its storage key and its storage type, for the code that copies
/// values as stored (a sync recopying the server's value as is).
///
/// `@Entity` declares one per attribute in the nested `Columns` enum (`Note.Columns.kind:
/// Column<Note, String>`), coded columns included. The queries use `Field`, typed by the domain
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
