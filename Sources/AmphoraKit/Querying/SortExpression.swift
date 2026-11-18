import Foundation

/// A sort descriptor over an entity.
public struct SortExpression<Root>: Sendable, Hashable {

    /// How strings compare.
    public enum StringComparison: Sendable, Hashable {
        /// `compare(_:)`, the default.
        case standard
        /// `caseInsensitiveCompare(_:)`.
        case caseInsensitive
        /// `localizedStandardCompare(_:)`, as the Finder sorts names.
        case localizedStandard
    }

    /// The attribute key path.
    public let key: String

    /// Whether the order is ascending.
    public let ascending: Bool

    /// The string comparison, for text attributes.
    public let stringComparison: StringComparison

    public init(key: String, ascending: Bool = true, stringComparison: StringComparison = .standard) {
        self.key = key
        self.ascending = ascending
        self.stringComparison = stringComparison
    }

    /// The resulting sort descriptor.
    public var nsSortDescriptor: NSSortDescriptor {
        switch stringComparison {
            case .standard:
                return NSSortDescriptor(key: key, ascending: ascending)
            case .caseInsensitive:
                return NSSortDescriptor(key: key, ascending: ascending, selector: #selector(NSString.caseInsensitiveCompare(_:)))
            case .localizedStandard:
                return NSSortDescriptor(key: key, ascending: ascending, selector: #selector(NSString.localizedStandardCompare(_:)))
        }
    }
}
