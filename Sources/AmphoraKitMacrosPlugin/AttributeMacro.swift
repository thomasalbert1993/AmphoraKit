import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

/// `@Attribute("a_sortOrder", storeAs: Int32.self) var order: Int` turns the property into the
/// accessor of its storage, which the enclosing `@Entity` declares.
public struct AttributeMacro: AccessorMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        StorageExpansion.accessors(of: node, declaration, role: .attribute, macro: "Attribute", in: context)
    }
}

/// `@Relationship var notes: [Note]` reads the `r_notes: Set<Note>` storage the enclosing
/// `@Entity` declares, zombie-safe.
public struct RelationshipMacro: AccessorMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        StorageExpansion.accessors(of: node, declaration, role: .relationship, macro: "Relationship", in: context)
    }
}

/// The accessors both macros share. The `@NSManaged` storage is declared by the enclosing
/// `@Entity`: a peer macro with arbitrary names makes every member lookup of the class expand it,
/// so a `default: Kind.note` naming a nested type would be a circular reference.
enum StorageExpansion {

    static func accessors(
        of node: AttributeSyntax,
        _ declaration: some DeclSyntaxProtocol,
        role: AttributeAnnotation.Role,
        macro: String,
        in context: some MacroExpansionContext
    ) -> [AccessorDeclSyntax] {
        let annotation: AttributeAnnotation
        do {
            annotation = try AttributeAnnotation(declaration, attribute: node, role: role)
        }
        catch {
            context.diagnose(Diagnostic(node: node, message: error.diagnostic(macro)))
            return []
        }
        guard annotation.enclosingEntity(in: context) != nil else {
            context.diagnose(Diagnostic(node: node, message: MacroDiagnostic("missingEntity", "'@\(macro)' requires '@Entity' on the enclosing class, which declares the storage")))
            return []
        }
        guard let storageName = annotation.storageName(in: context) else {
            context.diagnose(Diagnostic(node: node, message: AttributeAnnotation.Failure.missingStorageName.diagnostic(macro)))
            return []
        }

        let storage = "self.\(storageName)"
        let read: String
        let write: String
        if let coder = annotation.coder {
            read = "\(coder).decode(\(storage))"
            write = "\(coder).encode(newValue)"
        }
        else {
            if annotation.isSorted {
                read = "AmphoraKit.StoredAccessor.readSorted(\(storage))"
            }
            else {
                read = annotation.defaultValue.map { "AmphoraKit.StoredAccessor.read(\(storage), default: \($0))" }
                    ?? "AmphoraKit.StoredAccessor.read(\(storage))"
            }
            write = "AmphoraKit.StoredAccessor.write(newValue)"
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
                    \(raw: storage) = \(raw: write)
                }
                """
            )
        }
        return accessors
    }
}
