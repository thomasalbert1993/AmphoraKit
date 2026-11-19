import Foundation

/// A two-way conversion between an exposed value and its stored form, for the columns whose
/// encoding belongs to neither type: `@Attribute(storeAs: String?.self, coder: ScaleChainCoder.self)
/// var scales: [Scale]`.
///
/// Prefer `StorageConvertible` when the exposed type is yours and always stored the same way; a
/// coder is for the other cases — an array of your enums (`Array` can't take an app-internal
/// conformance), a column-specific encoding, an empty value stored as `nil`.
///
/// The typed queries encode their values with the coder, so `.scales([.wide])` matches the column
/// as written. Ordering a coded column means ordering its encoding: `@Entity` gives it no sort
/// and no static field.
///
public protocol StorageCoder {

    /// The exposed value.
    associatedtype Value

    /// The stored form, the type of the `@NSManaged` storage.
    associatedtype Stored

    /// The value a stored form encodes. A stored form it can't read decodes to a fallback of
    /// the coder's choosing.
    static func decode(_ stored: Stored) -> Value

    /// The stored form of a value.
    static func encode(_ value: Value) -> Stored
}

extension Match {

    /// The same condition on the stored forms the coder writes: what the typed query of a coded
    /// column compares against.
    public func encoded<Coder: StorageCoder>(by coder: Coder.Type) -> Match<Coder.Stored> where Coder.Value == Value {
        switch kind {
            case .compare(let comparison, let value):
                return Match<Coder.Stored>(.compare(comparison.converted(), Coder.encode(value)))
            case .between(let lower, let upper):
                return Match<Coder.Stored>(.between(Coder.encode(lower), Coder.encode(upper)))
            case .membership(let values, let negated):
                return Match<Coder.Stored>(.membership(values.map(Coder.encode), negated: negated))
            case .text(let textOperator, let text, let options):
                return Match<Coder.Stored>(.text(textOperator.converted(), text, options))
            case .null(let isNil):
                return Match<Coder.Stored>(.null(isNil: isNil))
        }
    }
}

extension Match.Comparison {

    /// The same operator on another value type: the nested enums of two `Match` types are distinct.
    func converted<Other>() -> Match<Other>.Comparison {
        switch self {
            case .equal: .equal
            case .notEqual: .notEqual
            case .lessThan: .lessThan
            case .lessOrEqual: .lessOrEqual
            case .greaterThan: .greaterThan
            case .greaterOrEqual: .greaterOrEqual
        }
    }
}

extension Match.TextOperator {

    /// The same operator on another value type.
    func converted<Other>() -> Match<Other>.TextOperator {
        switch self {
            case .contains: .contains
            case .hasPrefix: .hasPrefix
            case .hasSuffix: .hasSuffix
            case .like: .like
            case .matches: .matches
        }
    }
}
