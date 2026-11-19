import Foundation

/// The options of a text comparison.
public struct TextOptions: OptionSet, Codable, Sendable, Hashable {

    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Ignores case: `"Cam" == "cam"`.
    public static let caseInsensitive = TextOptions(rawValue: 1 << 0)

    /// Ignores diacritics: `"e" == "é"`.
    public static let diacriticInsensitive = TextOptions(rawValue: 1 << 1)

    /// The `[cd]` modifier the options render to, empty for none.
    var predicateModifier: String {
        var letters = ""
        if contains(.caseInsensitive) { letters += "c" }
        if contains(.diacriticInsensitive) { letters += "d" }
        return letters.isEmpty ? "" : "[\(letters)]"
    }
}

/// A condition on one attribute, carrying the value it compares against.
///
/// `Match` is the comparator of the typed queries: `.score(.greaterThan(2))`, `.name(.contains("x"))`,
/// `.folder(.isNil)`. Its factories are constrained by what the attribute's type supports, so a
/// `greaterThan` on a `Bool` or a `contains` on a `Double` doesn't compile. Values are compared
/// through their storage representation (see `StorageConvertible`), so enums and encoded structs
/// match the column as written.
///
public struct Match<Value> {

    /// A comparison operator.
    public enum Comparison: String, Codable, Sendable, CaseIterable {
        case equal = "=="
        case notEqual = "!="
        case lessThan = "<"
        case lessOrEqual = "<="
        case greaterThan = ">"
        case greaterOrEqual = ">="
    }

    /// A text operator.
    public enum TextOperator: String, Codable, Sendable, CaseIterable {
        case contains = "CONTAINS"
        case hasPrefix = "BEGINSWITH"
        case hasSuffix = "ENDSWITH"
        case like = "LIKE"
        case matches = "MATCHES"
    }

    /// The shape of a match. Closed: new operators are new factories, usually new cases.
    public enum Kind {
        case compare(Comparison, Value)
        case between(Value, Value)
        case membership([Value], negated: Bool)
        case text(TextOperator, String, TextOptions)
        case null(isNil: Bool)
    }

    /// The match.
    public let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    /// The predicate fragment for the attribute stored under `key`.
    func fragment(forKey key: String) -> PredicateFragment {
        switch kind {
            case .compare(let comparison, let value):
                let constant = PredicateFragment.constant(storageValue(of: value))
                return PredicateFragment("\(key) \(comparison.rawValue) \(constant.format)", constant.arguments)
            case .between(let lower, let upper):
                let bounds = [storageValue(of: lower) ?? NSNull(), storageValue(of: upper) ?? NSNull()]
                return PredicateFragment("\(key) BETWEEN %@", [bounds])
            case .membership(let values, let negated):
                let list = values.map { storageValue(of: $0) ?? NSNull() }
                return PredicateFragment("\(negated ? "NOT " : "")\(key) IN %@", [list])
            case .text(let textOperator, let text, let options):
                return PredicateFragment("\(key) \(textOperator.rawValue)\(options.predicateModifier) %@", [text])
            case .null(let isNil):
                // A type storing its absence as a value is missing when the column holds it.
                if let nilStorage = nilStorage(forOptional: Value.self) {
                    let constant = PredicateFragment.constant(nilStorage)
                    return PredicateFragment("\(key) \(isNil ? "==" : "!=") \(constant.format)", constant.arguments)
                }
                return PredicateFragment("\(key) \(isNil ? "==" : "!=") nil")
        }
    }
}


//-------------------
// MARK: Equatable
//-------------------

extension Match where Value: Equatable {

    /// The attribute equals the value.
    public static func equal(_ value: Value) -> Self {
        .init(.compare(.equal, value))
    }

    /// The attribute differs from the value.
    public static func notEqual(_ value: Value) -> Self {
        .init(.compare(.notEqual, value))
    }

    /// The attribute is one of the values.
    public static func `in`(_ values: [Value]) -> Self {
        .init(.membership(values, negated: false))
    }

    /// The attribute is none of the values.
    public static func notIn(_ values: [Value]) -> Self {
        .init(.membership(values, negated: true))
    }
}


//-------------------
// MARK: Comparable
//-------------------

extension Match where Value: Comparable {

    public static func lessThan(_ value: Value) -> Self {
        .init(.compare(.lessThan, value))
    }

    public static func lessOrEqual(_ value: Value) -> Self {
        .init(.compare(.lessOrEqual, value))
    }

    public static func greaterThan(_ value: Value) -> Self {
        .init(.compare(.greaterThan, value))
    }

    public static func greaterOrEqual(_ value: Value) -> Self {
        .init(.compare(.greaterOrEqual, value))
    }

    /// The attribute lies in the closed range.
    public static func between(_ lower: Value, _ upper: Value) -> Self {
        .init(.between(lower, upper))
    }
}

extension Match where Value: OptionalValue, Value.Wrapped: Comparable {

    public static func lessThan(_ value: Value.Wrapped) -> Self {
        .init(.compare(.lessThan, wrap(value)))
    }

    public static func lessOrEqual(_ value: Value.Wrapped) -> Self {
        .init(.compare(.lessOrEqual, wrap(value)))
    }

    public static func greaterThan(_ value: Value.Wrapped) -> Self {
        .init(.compare(.greaterThan, wrap(value)))
    }

    public static func greaterOrEqual(_ value: Value.Wrapped) -> Self {
        .init(.compare(.greaterOrEqual, wrap(value)))
    }

    public static func between(_ lower: Value.Wrapped, _ upper: Value.Wrapped) -> Self {
        .init(.between(wrap(lower), wrap(upper)))
    }
}


//-------------------
// MARK: Text
//-------------------

extension Match where Value == String {

    public static func contains(_ text: String, _ options: TextOptions = []) -> Self {
        .init(.text(.contains, text, options))
    }

    public static func hasPrefix(_ text: String, _ options: TextOptions = []) -> Self {
        .init(.text(.hasPrefix, text, options))
    }

    public static func hasSuffix(_ text: String, _ options: TextOptions = []) -> Self {
        .init(.text(.hasSuffix, text, options))
    }

    /// A `LIKE` pattern, `*` and `?` as wildcards.
    public static func like(_ pattern: String, _ options: TextOptions = []) -> Self {
        .init(.text(.like, pattern, options))
    }

    /// A regular expression the whole attribute must match.
    public static func matches(_ regex: String, _ options: TextOptions = []) -> Self {
        .init(.text(.matches, regex, options))
    }
}

extension Match where Value: OptionalValue, Value.Wrapped == String {

    public static func contains(_ text: String, _ options: TextOptions = []) -> Self {
        .init(.text(.contains, text, options))
    }

    public static func hasPrefix(_ text: String, _ options: TextOptions = []) -> Self {
        .init(.text(.hasPrefix, text, options))
    }

    public static func hasSuffix(_ text: String, _ options: TextOptions = []) -> Self {
        .init(.text(.hasSuffix, text, options))
    }

    public static func like(_ pattern: String, _ options: TextOptions = []) -> Self {
        .init(.text(.like, pattern, options))
    }

    public static func matches(_ regex: String, _ options: TextOptions = []) -> Self {
        .init(.text(.matches, regex, options))
    }
}


//-------------------
// MARK: Optional
//-------------------

extension Match where Value: OptionalValue {

    /// The attribute has no value.
    public static var isNil: Self {
        .init(.null(isNil: true))
    }

    /// The attribute has a value.
    public static var isNotNil: Self {
        .init(.null(isNil: false))
    }

    /// Wraps a value of the wrapped type into the optional value type.
    static func wrap(_ value: Value.Wrapped) -> Value {
        // `Value` is some `Optional<Wrapped>`: the only `OptionalValue` conformer.
        Optional(value) as! Value
    }
}


//-------------------
// MARK: Collection
//-------------------

extension Match where Value: RangeReplaceableCollection & Equatable {

    /// The attribute is empty. A coded column compares against the coder's encoding of the empty
    /// value, so a coder writing an empty collection as `nil` matches `== nil`.
    public static var isEmpty: Self {
        .equal(Value())
    }

    /// The attribute is not empty, compared like `isEmpty` against the empty value's stored form.
    public static var isNotEmpty: Self {
        .notEqual(Value())
    }
}


//-------------------
// MARK: Codable
//-------------------

extension Match.Kind: Codable where Value: Codable { }
extension Match: Codable where Value: Codable {

    public init(from decoder: any Decoder) throws {
        kind = try Kind(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try kind.encode(to: encoder)
    }
}

extension Match.Kind: Sendable where Value: Sendable { }
extension Match: Sendable where Value: Sendable { }
extension Match.Kind: Equatable where Value: Equatable { }
extension Match: Equatable where Value: Equatable { }
