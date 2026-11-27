import SwiftSyntax

/// A parsed `@Stored(\.storage, default: …, access: …) var name: Type` declaration, shared by both macros.
struct StoredAnnotation {

    /// The storage property the declaration exposes, `a_kind`.
    let storageName: String

    /// The exposed name, `kind`.
    let domainName: String

    /// The exposed type, `Kind`.
    let exposedType: TypeSyntax

    /// The fallback expression, `.note`.
    let defaultValue: ExprSyntax?

    /// Whether a setter is generated.
    let isReadWrite: Bool

    /// Whether the column is declared `.opaque` (`@Attribute` only): no equality, sort or field.
    let isOpaque: Bool

    /// The documentation of the declaration.
    let docCommentLines: [String]

    /// The validation failure, when the declaration can't be expanded.
    enum Failure: Error {
        case notAVariable
        case notAVar
        case multipleBindings
        case missingType
        case hasInitializer
        case hasAccessors
        case missingKeyPath

        var diagnostic: MacroDiagnostic {
            switch self {
            case .notAVariable: MacroDiagnostic("notAVariable", "'@Stored' can only be applied to a property")
            case .notAVar: MacroDiagnostic("notAVar", "'@Stored' requires 'var': the property becomes computed")
            case .multipleBindings: MacroDiagnostic("multipleBindings", "'@Stored' can only be applied to a single property")
            case .missingType: MacroDiagnostic("missingType", "'@Stored' requires an explicit type: it decides the conversion from the storage")
            case .hasInitializer: MacroDiagnostic("hasInitializer", "'@Stored' property can't have an initial value; use 'default:' for a fallback")
            case .hasAccessors: MacroDiagnostic("hasAccessors", "'@Stored' property can't declare accessors")
            case .missingKeyPath: MacroDiagnostic("missingKeyPath", "'@Stored' expects a key path to the storage property, '\\.a_name'")
            }
        }
    }

    /// An annotation built from an `@Attribute` / `@Relationship` declaration.
    init(storageName: String, domainName: String, exposedType: TypeSyntax, isOpaque: Bool, docCommentLines: [String]) {
        self.storageName = storageName
        self.domainName = domainName
        self.exposedType = exposedType
        self.defaultValue = nil
        self.isReadWrite = false
        self.isOpaque = isOpaque
        self.docCommentLines = docCommentLines
    }

    /// Parses a declaration carrying a `@Stored` attribute.
    init(_ declaration: some DeclSyntaxProtocol, attribute: AttributeSyntax) throws(Failure) {
        guard let variable = declaration.as(VariableDeclSyntax.self) else { throw .notAVariable }
        guard variable.bindingSpecifier.tokenKind == .keyword(.var) else { throw .notAVar }
        guard variable.bindings.count == 1, let binding = variable.bindings.first else { throw .multipleBindings }
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { throw .multipleBindings }
        guard let type = binding.typeAnnotation?.type else { throw .missingType }
        guard binding.initializer == nil else { throw .hasInitializer }
        guard binding.accessorBlock == nil else { throw .hasAccessors }

        let arguments = attribute.labeledArguments
        guard let storageName = arguments.argument(labeled: nil)?.keyPathPropertyName else { throw .missingKeyPath }

        self.storageName = storageName
        self.domainName = pattern.identifier.text
        self.exposedType = type.trimmed
        self.defaultValue = arguments.argument(labeled: "default")?.trimmed
        self.isReadWrite = arguments.argument(labeled: "access")?.trimmedDescription.hasSuffix("readWrite") ?? false
        self.isOpaque = false
        self.docCommentLines = variable.docCommentLines
    }
}
