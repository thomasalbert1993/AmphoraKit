import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

/// `@Stored(\.a_kind, default: .note, access: .readWrite) var kind: Kind` becomes a computed
/// property reading and writing `a_kind` through `StoredAccessor`, whose overloads pick the
/// conversion from the two types.
public struct StoredMacro: AccessorMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let annotation: StoredAnnotation
        do {
            annotation = try StoredAnnotation(declaration, attribute: node)
        }
        catch {
            context.diagnose(Diagnostic(node: node, message: error.diagnostic))
            return []
        }

        let storage = "self.\(annotation.storageName)"
        let read: String
        if let defaultValue = annotation.defaultValue {
            read = "AmphoraKit.StoredAccessor.read(\(storage), default: \(defaultValue))"
        }
        else {
            read = "AmphoraKit.StoredAccessor.read(\(storage))"
        }

        var accessors: [AccessorDeclSyntax] = [
            """
            get {
                \(raw: read)
            }
            """
        ]
        if annotation.isReadWrite {
            accessors.append(
                """
                set {
                    \(raw: storage) = AmphoraKit.StoredAccessor.write(newValue)
                }
                """
            )
        }
        return accessors
    }
}
