import SwiftSyntax
import SwiftDiagnostics

/// A diagnostic emitted by the AmphoraKit macros.
struct MacroDiagnostic: DiagnosticMessage, Error {
    let message: String
    let diagnosticID: MessageID
    let severity: DiagnosticSeverity

    init(_ id: String, _ message: String, severity: DiagnosticSeverity = .error) {
        self.message = message
        self.diagnosticID = MessageID(domain: "AmphoraKitMacros", id: id)
        self.severity = severity
    }
}

extension AttributeListSyntax {

    /// The first attribute with the name, `Stored` matching both `@Stored` and `@AmphoraKit.Stored`.
    func first(named name: String) -> AttributeSyntax? {
        for element in self {
            guard case .attribute(let attribute) = element else { continue }
            if attribute.attributeName.lastComponentName == name {
                return attribute
            }
        }
        return nil
    }
}

extension TypeSyntax {

    /// `Note.Kind` → `Kind`, `Kind` → `Kind`.
    var lastComponentName: String? {
        if let identifier = self.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        if let member = self.as(MemberTypeSyntax.self) {
            return member.name.text
        }
        return nil
    }

    /// `X?` → `X`, `Optional<X>` → `X`, otherwise `nil`.
    var optionalWrappedType: TypeSyntax? {
        if let optional = self.as(OptionalTypeSyntax.self) {
            return optional.wrappedType
        }
        if let identifier = self.as(IdentifierTypeSyntax.self), identifier.name.text == "Optional",
           let argument = identifier.genericArgumentClause?.arguments.first {
            return Syntax(argument.argument).as(TypeSyntax.self)
        }
        return nil
    }

    /// `[X]` or `Array<X>` → `X`, otherwise `nil`.
    var arrayElementType: TypeSyntax? {
        if let array = self.as(ArrayTypeSyntax.self) {
            return array.element
        }
        if let identifier = self.as(IdentifierTypeSyntax.self), identifier.name.text == "Array",
           let argument = identifier.genericArgumentClause?.arguments.first {
            return Syntax(argument.argument).as(TypeSyntax.self)
        }
        return nil
    }

    /// Whether the type is an array, a set or a dictionary.
    var isCollection: Bool {
        arrayElementType != nil || setElementType != nil || self.is(DictionaryTypeSyntax.self)
    }

    /// `Set<X>` → `X`, otherwise `nil`.
    var setElementType: TypeSyntax? {
        guard let identifier = self.as(IdentifierTypeSyntax.self), identifier.name.text == "Set",
              let argument = identifier.genericArgumentClause?.arguments.first else {
            return nil
        }
        return Syntax(argument.argument).as(TypeSyntax.self)
    }

    /// Whether the type is a standard value type, which no relationship targets.
    var isStandardValueType: Bool {
        [
            "String", "Substring", "Character", "Bool", "Int", "Int8", "Int16", "Int32", "Int64",
            "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Float", "Double", "Decimal",
            "Date", "Data", "UUID", "URL"
        ].contains(lastComponentName ?? "")
    }

    /// Whether the type is stored as an attribute, by its type alone: a standard value, a number,
    /// a collection (an array, a dictionary, a set of standard values — transformables), or a
    /// type holding `Any`. Anything else — an entity, a set of entities — is a relationship. Used
    /// when attributes and relationships share their prefix.
    var isAttributeValueType: Bool {
        let type = optionalWrappedType ?? self
        if type.isStandardValueType || ["NSNumber", "NSDecimalNumber", "NSString", "NSData", "NSDate"].contains(type.lastComponentName ?? "") {
            return true
        }
        if let element = type.setElementType {
            return element.isStandardValueType
        }
        return type.arrayElementType != nil || type.is(DictionaryTypeSyntax.self) || type.holdsAny
    }

    /// Whether the type holds `Any` or `AnyObject` somewhere: it can't be compared.
    var holdsAny: Bool {
        tokens(viewMode: .sourceAccurate).contains { token in
            switch token.tokenKind {
                case .identifier("Any"), .identifier("AnyObject"), .keyword(.Any), .keyword(.any):
                    return true
                default:
                    return false
            }
        }
    }

    /// Whether the type is an untyped Core Data collection the macro can't type.
    var isUntypedCollection: Bool {
        ["NSSet", "NSOrderedSet", "NSMutableSet", "NSMutableOrderedSet"].contains(lastComponentName ?? "")
    }
}

extension VariableDeclSyntax {

    /// The key of a `softDeletion` declaration: `"a_deleted"` in `.flag("a_deleted")` or `.date("a_deleted")`.
    var softDeletionKey: String? {
        for call in tokens(viewMode: .sourceAccurate) where call.tokenKind == .identifier("flag") || call.tokenKind == .identifier("date") {
            var token = call.nextToken(viewMode: .sourceAccurate)
            guard token?.tokenKind == .leftParen else { continue }
            token = token?.nextToken(viewMode: .sourceAccurate)
            guard token?.tokenKind == .stringQuote else { continue }
            if case .stringSegment(let key)? = token?.nextToken(viewMode: .sourceAccurate)?.tokenKind {
                return key
            }
        }
        return nil
    }
}

extension ExprSyntax {

    /// `\.a_kind` or `\Note.a_kind` → `a_kind`.
    var keyPathPropertyName: String? {
        guard let keyPath = self.as(KeyPathExprSyntax.self),
              let last = keyPath.components.last,
              let property = last.component.as(KeyPathPropertyComponentSyntax.self) else {
            return nil
        }
        return property.declName.baseName.text
    }

    /// The type of a metatype argument: `Int32.self` → `Int32`, `String?.self` → `String?`.
    var metatypeArgument: TypeSyntax? {
        guard let member = self.as(MemberAccessExprSyntax.self), member.declName.baseName.tokenKind == .keyword(.self),
              let base = member.base else {
            return nil
        }
        return TypeSyntax(stringLiteral: base.trimmedDescription)
    }

    /// The text of a plain string literal.
    var stringLiteralValue: String? {
        guard let literal = self.as(StringLiteralExprSyntax.self) else { return nil }
        return literal.segments.compactMap { $0.as(StringSegmentSyntax.self)?.content.text }.joined()
    }
}

extension LabeledExprListSyntax {

    /// The expression of the argument with the label, or the unlabeled argument at the index when `label` is `nil`.
    func argument(labeled label: String?, index: Int = 0) -> ExprSyntax? {
        if let label {
            return first { $0.label?.text == label }?.expression
        }
        let unlabeled = filter { $0.label == nil }
        guard unlabeled.count > index else { return nil }
        return unlabeled[unlabeled.index(unlabeled.startIndex, offsetBy: index)].expression
    }
}

extension AttributeSyntax {

    /// The labeled argument list, empty when the attribute has none.
    var labeledArguments: LabeledExprListSyntax {
        if case .argumentList(let list) = arguments {
            return list
        }
        return []
    }
}

extension SyntaxProtocol {

    /// The documentation comment lines (`///`, `/** */`) leading the node, each trimmed of its indentation.
    var docCommentLines: [String] {
        leadingTrivia.compactMap { piece in
            switch piece {
            case .docLineComment(let text), .docBlockComment(let text):
                return text
            default:
                return nil
            }
        }
    }
}

extension DeclModifierListSyntax {

    /// The access modifier the generated members mirror: `public ` for `public` / `open`, `package `, or nothing.
    var generatedAccessPrefix: String {
        for modifier in self {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open):
                return "public "
            case .keyword(.package):
                return "package "
            default:
                continue
            }
        }
        return ""
    }
}
