import SwiftSyntax
import SwiftSyntaxMacros

/// `@StorageOnly` is a marker `@Entity` reads: it generates nothing itself.
public struct StorageOnlyMacro: PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
