import SwiftSyntax
import SwiftSyntaxMacros
import SwiftDiagnostics

/// `@Entity(attributePrefix:relationshipPrefix:generatesAccessors:)` generates the nested `Query` and `Sort` types
/// of an entity and its static `Field`s from its `@NSManaged` and `@Stored` declarations, plus a
/// read-only domain accessor for every prefixed storage property nothing exposes yet.
///
/// No operator is generated: operators declared in macro-generated types are not found by the
/// compiler from files it type-checks before expanding the macro. The boolean operators of
/// `Query` and the comparison operators of `Field` live in the package.
public struct EntityMacro: MemberMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: MacroDiagnostic("notAClass", "'@Entity' can only be applied to an NSManagedObject subclass")))
            return []
        }
        let model = EntityModel(classDecl, attribute: node, context: context)
        return model.render()
    }
}


//-------------------
// MARK: Model
//-------------------

/// What the macro knows about an entity once its members are read.
struct EntityModel {

    /// One storage property and how it is exposed.
    struct Property {
        enum Kind {
            /// A scalar attribute, queried with `Match<Exposed>`.
            case attribute(exposedType: String)
            /// A to-one relationship, queried by nullability or by the target's query.
            case toOne(target: String, storageType: String)
            /// A to-many relationship, queried with `CollectionMatch<Element>`.
            case toMany(element: String)
        }

        let storageName: String
        let domainName: String
        let kind: Kind
        let docCommentLines: [String]
        /// Whether `@Entity` writes `var domainName: Type { storage }` itself.
        let generatesAccessor: Bool
        /// Whether `@Entity` writes `static var domainName: Field<Entity, Type>` itself.
        let generatesField: Bool
        /// The type of the generated accessor, the storage type.
        let storageType: String
    }

    let typeName: String
    let access: String
    private(set) var properties: [Property] = []
    /// The nested types the class declares itself, which the macro doesn't generate again.
    private(set) var handWrittenTypes: Set<String> = []
    /// The `@NSManaged` storage of the `@Attribute` / `@Relationship` declarations: name, type, access.
    private(set) var managedDeclarations: [(name: String, type: String, access: String)] = []

    /// Members of `NSObject` / `NSManagedObject` / `DatabaseObject` a generated accessor would clash with.
    static let reservedInstanceNames: Set<String> = [
        "description", "debugDescription", "hash", "hashValue", "superclass", "classForCoder",
        "entity", "objectID", "managedObjectContext", "isInserted", "isUpdated", "isDeleted", "isFault",
        "hasChanges", "hasPersistentChangedValues", "faultingState", "changedValues", "committedValues",
        "observationInfo", "isProxy", "isZombie", "nilIfZombie", "didUpdate", "entityName", "idKey"
    ]

    /// Class members of `NSObject` / `NSManagedObject` / `DatabaseObject` a generated field would clash with.
    static let reservedStaticNames: Set<String> = [
        "description", "debugDescription", "hash", "superclass", "entity", "fetchRequest",
        "entityName", "idKey", "Query", "Sort", "Assignment", "Schema", "ID"
    ]

    init(_ classDecl: ClassDeclSyntax, attribute: AttributeSyntax, context: some MacroExpansionContext) {
        typeName = classDecl.name.text
        access = classDecl.modifiers.generatedAccessPrefix

        let arguments = attribute.labeledArguments
        let attributePrefix = arguments.argument(labeled: "attributePrefix")?.stringLiteralValue ?? ""
        let relationshipPrefix = arguments.argument(labeled: "relationshipPrefix")?.stringLiteralValue ?? ""
        let generatesAccessors = arguments.argument(labeled: "generatesAccessors")?.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind != .keyword(.false)

        var storages: [(name: String, type: TypeSyntax, node: TypeSyntax, docCommentLines: [String], role: AttributeAnnotation.Role?)] = []
        var declared: [AttributeAnnotation] = []
        var excluded: Set<String> = []
        var annotations: [String: StoredAnnotation] = [:]
        var instanceNames: Set<String> = []
        var staticNames: Set<String> = []

        for member in classDecl.memberBlock.members {
            let decl = member.decl
            if let variable = decl.as(VariableDeclSyntax.self) {
                let isStatic = variable.modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
                for binding in variable.bindings {
                    if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                        if isStatic {
                            staticNames.insert(name)
                        }
                        else {
                            instanceNames.insert(name)
                        }
                    }
                }
                if variable.attributes.first(named: "NSManaged") != nil {
                    let isStorageOnly = variable.attributes.first(named: "StorageOnly") != nil
                    for binding in variable.bindings {
                        guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                              let type = binding.typeAnnotation?.type else { continue }
                        storages.append((name, type.trimmed, type, variable.docCommentLines, nil))
                        if isStorageOnly {
                            excluded.insert(name)
                        }
                    }
                }
                else if let attribute = variable.attributes.first(named: "Attribute"),
                        let annotation = try? AttributeAnnotation(variable, attribute: attribute, role: .attribute) {
                    declared.append(annotation)
                }
                else if let attribute = variable.attributes.first(named: "Relationship"),
                        let annotation = try? AttributeAnnotation(variable, attribute: attribute, role: .relationship) {
                    declared.append(annotation)
                }
                else if let stored = variable.attributes.first(named: "Stored"),
                        let annotation = try? StoredAnnotation(variable, attribute: stored) {
                    // The first declaration exposing a storage property names it in the queries.
                    if annotations[annotation.storageName] == nil {
                        annotations[annotation.storageName] = annotation
                    }
                }
            }
            else if let function = decl.as(FunctionDeclSyntax.self) {
                let isStatic = function.modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
                if isStatic {
                    staticNames.insert(function.name.text)
                }
                else {
                    instanceNames.insert(function.name.text)
                }
            }
            else if let nested = decl.asProtocol(NamedDeclSyntax.self) {
                instanceNames.insert(nested.name.text)
                staticNames.insert(nested.name.text)
                handWrittenTypes.insert(nested.name.text)
            }
        }

        // The storage `@Attribute` and `@Relationship` stand for: written here, read like `@NSManaged`.
        for annotation in declared {
            guard let name = annotation.storageName(attributePrefix: attributePrefix, relationshipPrefix: relationshipPrefix) else { continue }
            let type = TypeSyntax(stringLiteral: annotation.storageType)
            managedDeclarations.append((name, annotation.storageType, annotation.accessPrefix))
            storages.append((name, type, annotation.exposedType, annotation.docCommentLines, annotation.role))
            annotations[name] = StoredAnnotation(storageName: name, domainName: annotation.domainName, exposedType: annotation.exposedType, docCommentLines: annotation.docCommentLines)
        }

        for storage in storages where !excluded.contains(storage.name) {
            let isRelationship = storage.role.map { $0 == .relationship } ?? (!relationshipPrefix.isEmpty && storage.name.hasPrefix(relationshipPrefix))
            let isAttribute = storage.role.map { $0 == .attribute } ?? (!attributePrefix.isEmpty && storage.name.hasPrefix(attributePrefix))
            let isUnprefixed = attributePrefix.isEmpty && relationshipPrefix.isEmpty
            let prefix: String
            if storage.role != nil {
                prefix = ""
            }
            else if isRelationship {
                prefix = relationshipPrefix
            }
            else if isAttribute {
                prefix = attributePrefix
            }
            else if isUnprefixed {
                prefix = ""
            }
            else {
                // Not one of ours: a storage property outside both prefixes.
                continue
            }

            let annotation = annotations[storage.name]
            let domainName = annotation?.domainName ?? String(storage.name.dropFirst(prefix.count))
            let docCommentLines = annotation?.docCommentLines ?? storage.docCommentLines
            let kind: Property.Kind

            // A prefixed attribute is an attribute whatever its type (a transformable `Set<String>`);
            // without prefixes, a set of standard values is one too.
            let canBeRelationship = isRelationship || (storage.role == nil && isUnprefixed && !(storage.type.setElementType?.isStandardValueType ?? false))
            if canBeRelationship, let element = storage.type.setElementType {
                kind = .toMany(element: element.trimmedDescription)
            }
            else if canBeRelationship, storage.type.isUntypedCollection {
                context.diagnose(Diagnostic(
                    node: Syntax(storage.node),
                    message: MacroDiagnostic("untypedCollection", "'@Entity' skips '\(storage.name)': declare it as 'Set<Target>' to query it", severity: .warning)
                ))
                continue
            }
            else if isRelationship {
                let target = (storage.type.optionalWrappedType ?? storage.type).trimmedDescription
                kind = .toOne(target: target, storageType: storage.type.trimmedDescription)
            }
            else {
                kind = .attribute(exposedType: annotation?.exposedType.trimmedDescription ?? storage.type.trimmedDescription)
            }

            let generatesAccessor = generatesAccessors
                && annotation == nil
                && domainName != storage.name
                && !instanceNames.contains(domainName)
                && !Self.reservedInstanceNames.contains(domainName)

            let generatesField = !staticNames.contains(domainName)
                && !Self.reservedStaticNames.contains(domainName)

            properties.append(Property(
                storageName: storage.name,
                domainName: domainName,
                kind: kind,
                docCommentLines: docCommentLines,
                generatesAccessor: generatesAccessor,
                generatesField: generatesField,
                storageType: storage.type.trimmedDescription
            ))
        }
    }


    //-------------------
    // MARK: Rendering
    //-------------------

    func render() -> [DeclSyntax] {
        var declarations: [DeclSyntax] = managedDeclarations.map { storage in
            DeclSyntax(stringLiteral: "@NSManaged \(storage.access)var \(storage.name): \(storage.type)")
        }
        if !handWrittenTypes.contains("Query") {
            declarations.append(renderQuery())
        }
        if !handWrittenTypes.contains("Sort") {
            declarations.append(renderSort())
        }
        if !handWrittenTypes.contains("Assignment") {
            declarations.append(renderAssignment())
        }
        for property in properties where property.generatesField {
            if let field = renderField(property) {
                declarations.append(field)
            }
        }
        for property in properties where property.generatesAccessor {
            declarations.append(renderAccessor(property))
        }
        return declarations
    }

    private func doc(_ lines: [String], indent: String) -> String {
        lines.map { "\(indent)\($0)\n" }.joined()
    }

    private func renderQuery() -> DeclSyntax {
        var members = ""
        for property in properties {
            let docLines = doc(property.docCommentLines, indent: "    ")
            switch property.kind {
            case .attribute(let exposedType):
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ match: AmphoraKit.Match<\(exposedType)>) -> Query {
                        .init(.match("\(property.storageName)", match))
                    }
                \(docLines)    \(access)static func \(property.domainName)(_ value: \(exposedType)) -> Query {
                        .\(property.domainName)(.equal(value))
                    }

                """
            case .toOne(let target, let storageType):
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ match: AmphoraKit.Match<\(storageType)>) -> Query {
                        .init(.match("\(property.storageName)", match))
                    }
                \(docLines)    \(access)static func \(property.domainName)(_ query: \(target).Query) -> Query {
                        .init(.relation("\(property.storageName)", query.expression))
                    }

                """
            case .toMany(let element):
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ match: AmphoraKit.CollectionMatch<\(element)>) -> Query {
                        .init(.collection("\(property.storageName)", match))
                    }

                """
            }
        }

        return DeclSyntax(stringLiteral: """
        /// The typed predicate of `\(typeName)`, generated by `@Entity`.
        \(access)struct Query: AmphoraKit.EntityQuery {
            \(access)let expression: AmphoraKit.QueryExpression<\(typeName)>
            \(access)init(_ expression: AmphoraKit.QueryExpression<\(typeName)>) {
                self.expression = expression
            }
        \(members)}
        """)
    }

    private func renderSort() -> DeclSyntax {
        var members = ""
        for property in properties {
            guard case .attribute = property.kind else { continue }
            let docLines = doc(property.docCommentLines, indent: "    ")
            members += """
            \(docLines)    \(access)static var \(property.domainName): Sort {
                    .init(key: "\(property.storageName)")
                }

            """
        }

        return DeclSyntax(stringLiteral: """
        /// The typed sort descriptor of `\(typeName)`, generated by `@Entity`.
        \(access)struct Sort: AmphoraKit.EntitySort {
            \(access)let expression: AmphoraKit.SortExpression<\(typeName)>
            \(access)init(_ expression: AmphoraKit.SortExpression<\(typeName)>) {
                self.expression = expression
            }
        \(members)}
        """)
    }

    private func renderAssignment() -> DeclSyntax {
        var members = ""
        for property in properties {
            guard case .attribute(let exposedType) = property.kind,
                  !["storageKey", "storageValue"].contains(property.domainName) else { continue }
            let docLines = doc(property.docCommentLines, indent: "    ")
            members += """
            \(docLines)    \(access)static func \(property.domainName)(_ value: \(exposedType)) -> Assignment {
                    .init(storageKey: "\(property.storageName)", storageValue: AmphoraKit.StoredAccessor.write(value) as \(property.storageType))
                }

            """
        }

        return DeclSyntax(stringLiteral: """
        /// The typed attribute values of `\(typeName)`, generated by `@Entity`.
        \(access)struct Assignment: AmphoraKit.EntityAssignment {
            \(access)typealias Root = \(typeName)
            \(access)let storageKey: String
            \(access)let storageValue: Any?
            \(access)init(storageKey: String, storageValue: Any?) {
                self.storageKey = storageKey
                self.storageValue = storageValue
            }
        \(members)}
        """)
    }

    private func renderField(_ property: Property) -> DeclSyntax? {
        let valueType: String
        switch property.kind {
        case .attribute(let exposedType):
            valueType = exposedType
        case .toOne(_, let storageType):
            valueType = storageType
        case .toMany:
            return nil
        }
        let docLines = property.docCommentLines.isEmpty
            ? "/// The `\(property.domainName)` field, for the expression form of the queries.\n"
            : doc(property.docCommentLines, indent: "")
        return DeclSyntax(stringLiteral: """
        \(docLines)\(access)static var \(property.domainName): AmphoraKit.Field<\(typeName), \(valueType)> {
            .init(key: "\(property.storageName)")
        }
        """)
    }

    private func renderAccessor(_ property: Property) -> DeclSyntax {
        let type: String
        let body: String
        let defaultDoc: String
        switch property.kind {
        case .attribute:
            type = property.storageType
            body = property.storageName
            defaultDoc = "/// The value of `\(property.storageName)`.\n"
        case .toOne(let target, _):
            type = "\(target)?"
            body = "\(property.storageName)?.nilIfZombie"
            defaultDoc = "/// The value of `\(property.storageName)`, `nil` when it is a zombie.\n"
        case .toMany(let element):
            type = "[\(element)]"
            body = "\(property.storageName).removingZombies()"
            defaultDoc = "/// The objects of `\(property.storageName)`, zombies removed.\n"
        }
        let docLines = property.docCommentLines.isEmpty ? defaultDoc : doc(property.docCommentLines, indent: "")
        return DeclSyntax(stringLiteral: """
        \(docLines)\(access)var \(property.domainName): \(type) {
            \(body)
        }
        """)
    }
}
