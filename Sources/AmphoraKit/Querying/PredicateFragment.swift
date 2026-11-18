import Foundation

/// A piece of predicate format with its arguments, the unit every query renders to.
///
/// Keys are inlined (they come from code, never from input); constants always go through `%@`
/// arguments so that `NSPredicate` quotes and converts them.
struct PredicateFragment {

    var format: String
    var arguments: [Any]

    init(_ format: String, _ arguments: [Any] = []) {
        self.format = format
        self.arguments = arguments
    }

    /// The fragment resolved into a predicate.
    var nsPredicate: NSPredicate {
        NSPredicate(format: format, argumentArray: arguments)
    }

    /// Joins fragments with a boolean operator, each one parenthesized.
    static func joined(_ fragments: [PredicateFragment], by operator: String) -> PredicateFragment {
        PredicateFragment(
            fragments.map { "(\($0.format))" }.joined(separator: " \(`operator`) "),
            fragments.flatMap(\.arguments)
        )
    }

    /// The constant placed in a format: `%@` with the value as argument, or `nil` inline.
    static func constant(_ value: Any?) -> (format: String, arguments: [Any]) {
        guard let value else { return ("nil", []) }
        return ("%@", [value])
    }
}
