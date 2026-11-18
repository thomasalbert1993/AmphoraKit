import SwiftSyntax
import SwiftSyntaxMacros

/// A parsed `@Attribute(…) var name: Type` or `@Relationship(…) var name: Type` declaration, shared
/// by the macros themselves (storage + accessors) and by `@Entity` (queries, fields, assignments).
struct AttributeAnnotation {

    /// Which macro declared the property.
    enum Role {
        case attribute
        case relationship
    }

    let role: Role

    /// The exposed name, `order`.
    let domainName: String

    /// The exposed type, `Int`.
    let exposedType: TypeSyntax

    /// The storage name given explicitly, `"a_sortOrder"`.
    let explicitStorageName: String?

    /// The stored type given by `storeAs:`, `Int32`.
    let storeAs: TypeSyntax?

    /// The fallback expression, `Kind.note`.
    let defaultValue: ExprSyntax?

    /// Whether a setter is generated.
    let isReadWrite: Bool

    /// The documentation of the declaration.
    let docCommentLines: [String]

    /// The access modifier the storage mirrors.
    let accessPrefix: String

    /// The validation failure, when the declaration can't be expanded.
    enum Failure: Error {
        case notAVariable
        case notAVar
        case multipleBindings
        case missingType
        case hasInitializer
        case hasAccessors
        case relationshipType
        case missingStorageName

        func diagnostic(_ macro: String) -> MacroDiagnostic {
            switch self {
            case .notAVariable: MacroDiagnostic("notAVariable", "'@\(macro)' can only be applied to a property")
            case .notAVar: MacroDiagnostic("notAVar", "'@\(macro)' requires 'var': the property becomes computed")
            case .multipleBindings: MacroDiagnostic("multipleBindings", "'@\(macro)' can only be applied to a single property")
            case .missingType: MacroDiagnostic("missingType", "'@\(macro)' requires an explicit type")
            case .hasInitializer: MacroDiagnostic("hasInitializer", "'@\(macro)' property can't have an initial value; use 'default:' for a fallback")
            case .hasAccessors: MacroDiagnostic("hasAccessors", "'@\(macro)' property can't declare accessors")
            case .relationshipType: MacroDiagnostic("relationshipType", "'@Relationship' expects 'Target?' for a to-one relationship or '[Target]' for a to-many one")
            case .missingStorageName: MacroDiagnostic("missingStorageName", "'@\(macro)' needs a storage name, or a prefix on the enclosing '@Entity': the storage can't share the property's name")
            }
        }
    }

    /// Parses a declaration carrying `@Attribute` or `@Relationship`.
    init(_ declaration: some SyntaxProtocol, attribute: AttributeSyntax, role: Role) throws(Failure) {
        guard let variable = declaration.as(VariableDeclSyntax.self) else { throw .notAVariable }
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else { throw .notAVar }
        guard variable.bindings.count == 1, let binding = variable.bindings.first,
              let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { throw .multipleBindings }
        guard let type = binding.typeAnnotation?.type else { throw .missingType }
        guard binding.initializer == nil else { throw .hasInitializer }
        guard binding.accessorBlock == nil else { throw .hasAccessors }

        let arguments = attribute.labeledArguments
        self.role = role
        self.domainName = pattern.identifier.text
        self.exposedType = type.trimmed
        self.explicitStorageName = arguments.argument(labeled: nil)?.stringLiteralValue
        self.storeAs = arguments.argument(labeled: "storeAs")?.metatypeArgument
        self.defaultValue = arguments.argument(labeled: "default")?.trimmed
        self.isReadWrite = arguments.argument(labeled: "access")?.trimmedDescription.hasSuffix("readWrite") ?? false
        self.docCommentLines = variable.docCommentLines
        self.accessPrefix = variable.modifiers.generatedAccessPrefix

        if role == .relationship, type.arrayElementType == nil, type.optionalWrappedType == nil {
            throw .relationshipType
        }
    }

    /// The storage name: the explicit one, or the property name behind the entity's prefix.
    func storageName(attributePrefix: String, relationshipPrefix: String) -> String? {
        if let explicitStorageName {
            return explicitStorageName
        }
        let prefix = role == .attribute ? attributePrefix : relationshipPrefix
        return prefix.isEmpty ? nil : prefix + domainName
    }

    /// The `@Entity` attribute of the enclosing class, if any.
    func enclosingEntity(in context: some MacroExpansionContext) -> AttributeSyntax? {
        for enclosing in context.lexicalContext {
            if let classDecl = enclosing.as(ClassDeclSyntax.self) {
                return classDecl.attributes.first(named: "Entity")
            }
        }
        return nil
    }

    /// The storage name, the prefixes read from the `@Entity` of the enclosing class.
    func storageName(in context: some MacroExpansionContext) -> String? {
        let arguments = enclosingEntity(in: context)?.labeledArguments ?? []
        return storageName(
            attributePrefix: arguments.argument(labeled: "attributePrefix")?.stringLiteralValue ?? "",
            relationshipPrefix: arguments.argument(labeled: "relationshipPrefix")?.stringLiteralValue ?? ""
        )
    }

    /// The type of the `@NSManaged` storage: `storeAs:`, the exposed type, `Set<Target>` for a to-many.
    var storageType: String {
        switch role {
        case .attribute:
            return (storeAs ?? exposedType).trimmedDescription
        case .relationship:
            if let element = exposedType.arrayElementType {
                return "Set<\(element.trimmedDescription)>"
            }
            return exposedType.trimmedDescription
        }
    }
}
