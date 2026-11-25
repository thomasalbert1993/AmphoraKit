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
        /// The coder of a coded column, which its queries and assignments encode with.
        let coder: String?
        /// Whether the exposed value can be compared: a type holding `Any` (`[String: Any]`) can't,
        /// and gets no equality member, sort or field.
        let isComparable: Bool
        /// Whether the column is the entity's soft-deletion mark (`softDeletion`): it gets no query
        /// member nor field, which would shadow `SoftDeletable`'s `.deleted(_:)`.
        let isSoftDeletionMark: Bool
    }

    /// How the generated types are shaped, from where the entity sits in its hierarchy.
    enum Shape: Equatable {
        /// A final entity inheriting from `NSManagedObject`: structs.
        case finalRoot
        /// A non-final entity at the root of a hierarchy: classes its sub-entities' types inherit from.
        case openRoot
        /// An entity inheriting from another entity: classes inheriting from the parent's.
        case subEntity(parent: String)
    }

    let typeName: String
    let access: String
    let shape: Shape
    let isFinal: Bool
    /// Whether the generated `@NSManaged` storage is `private` (`storageAccess: .private`): only
    /// the class body reads it, everything else goes through the accessors and `stored`.
    let isStoragePrivate: Bool
    /// Whether the class declares a `stored` member itself, which the macro doesn't generate again.
    private(set) var declaresStored = false
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
        "observationInfo", "isProxy", "isZombie", "nilIfZombie", "didUpdate", "entityName", "idKey",
        "stored",
        // the Objective-C names of `NSManagedObject`'s Boolean properties, visible from Swift too
        "deleted", "inserted", "updated", "fault",
        // `DatabaseObject` and `SoftDeletable` members
        "didCreate", "isSoftDeleted", "nilIfSoftDeleted"
    ]

    /// Class members of `NSObject` / `NSManagedObject` / `DatabaseObject` a generated field would clash with.
    static let reservedStaticNames: Set<String> = [
        "description", "debugDescription", "hash", "superclass", "entity", "fetchRequest",
        "entityName", "idKey", "Query", "Sort", "AttributeAssignment", "Assignment", "Columns", "StoredValues",
        "Schema", "ID"
    ]

    init(_ classDecl: ClassDeclSyntax, attribute: AttributeSyntax, context: some MacroExpansionContext) {
        typeName = classDecl.name.text
        access = classDecl.modifiers.generatedAccessPrefix

        let arguments = attribute.labeledArguments
        let attributePrefix = arguments.argument(labeled: "attributePrefix")?.stringLiteralValue ?? ""
        let relationshipPrefix = arguments.argument(labeled: "relationshipPrefix")?.stringLiteralValue ?? ""
        let generatesAccessors = arguments.argument(labeled: "generatesAccessors")?.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind != .keyword(.false)
        isStoragePrivate = arguments.argument(labeled: "storageAccess")?.as(MemberAccessExprSyntax.self)?.declName.baseName.text == "private"

        // The superclass comes first in the inheritance clause, and an entity always has one:
        // anything but `NSManagedObject` there is the parent entity, unless `root: true` says the
        // superclass is a plain base class.
        isFinal = classDecl.modifiers.contains { $0.name.tokenKind == .keyword(.final) }
        let isDeclaredRoot = arguments.argument(labeled: "root")?.as(BooleanLiteralExprSyntax.self)?.literal.tokenKind == .keyword(.true)
        let superclass = classDecl.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription
        if let superclass, !isDeclaredRoot, !["NSManagedObject", "CoreData.NSManagedObject"].contains(superclass) {
            shape = .subEntity(parent: superclass)
        }
        else {
            shape = isFinal ? .finalRoot : .openRoot
        }

        var storages: [(name: String, type: TypeSyntax, node: TypeSyntax, docCommentLines: [String], role: AttributeAnnotation.Role?)] = []
        var coders: [String: String] = [:]
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

        declaresStored = instanceNames.contains("stored")

        // The soft-deletion mark the class declares (`static var softDeletion: SoftDeletion { .flag("a_deleted") }`).
        let softDeletionKey: String? = classDecl.memberBlock.members.lazy.compactMap { member -> String? in
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.bindings.contains(where: { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "softDeletion" }) else {
                return nil
            }
            return variable.softDeletionKey
        }.first

        // The storage `@Attribute` and `@Relationship` stand for: written here, read like `@NSManaged`.
        for annotation in declared {
            guard let name = annotation.storageName(attributePrefix: attributePrefix, relationshipPrefix: relationshipPrefix) else { continue }
            let type = TypeSyntax(stringLiteral: annotation.storageType)
            managedDeclarations.append((name, annotation.storageType, annotation.accessPrefix))
            if let coder = annotation.coder {
                coders[name] = coder.trimmedDescription
            }
            storages.append((name, type, annotation.exposedType, annotation.docCommentLines, annotation.role))
            annotations[name] = StoredAnnotation(storageName: name, domainName: annotation.domainName, exposedType: annotation.exposedType, docCommentLines: annotation.docCommentLines)
        }

        // One prefix for both kinds (`cd_`): the type tells them apart, a value type being an
        // attribute and anything else — an entity, a set of entities — a relationship.
        let hasSharedPrefix = !attributePrefix.isEmpty && attributePrefix == relationshipPrefix

        for storage in storages where !excluded.contains(storage.name) {
            let isPrefixedByShared = storage.role == nil && hasSharedPrefix && storage.name.hasPrefix(attributePrefix)
            let isRelationship = storage.role.map { $0 == .relationship }
                ?? (isPrefixedByShared ? !storage.type.isAttributeValueType : (!relationshipPrefix.isEmpty && storage.name.hasPrefix(relationshipPrefix)))
            let isAttribute = storage.role.map { $0 == .attribute }
                ?? (isPrefixedByShared ? storage.type.isAttributeValueType : (!attributePrefix.isEmpty && storage.name.hasPrefix(attributePrefix)))
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

            // A coded column has no static field: `Field` carries a key, not a coder.
            let generatesField = coders[storage.name] == nil
                && storage.name != softDeletionKey
                && !(annotation?.exposedType ?? storage.type).holdsAny
                && !staticNames.contains(domainName)
                && !Self.reservedStaticNames.contains(domainName)

            properties.append(Property(
                storageName: storage.name,
                domainName: domainName,
                kind: kind,
                docCommentLines: docCommentLines,
                generatesAccessor: generatesAccessor,
                generatesField: generatesField,
                storageType: storage.type.trimmedDescription,
                coder: coders[storage.name],
                isComparable: !(annotation?.exposedType ?? storage.type).holdsAny,
                isSoftDeletionMark: storage.name == softDeletionKey
            ))
        }
    }


    //-------------------
    // MARK: Rendering
    //-------------------

    func render() -> [DeclSyntax] {
        var declarations: [DeclSyntax] = managedDeclarations.map { storage in
            DeclSyntax(stringLiteral: "@NSManaged \(isStoragePrivate ? "private " : storage.access)var \(storage.name): \(storage.type)")
        }
        if !handWrittenTypes.contains("Query") {
            declarations.append(renderQuery())
        }
        if !handWrittenTypes.contains("Sort") {
            declarations.append(renderSort())
        }
        if !handWrittenTypes.contains("AttributeAssignment") {
            declarations.append(renderAttributeAssignment())
        }
        if !handWrittenTypes.contains("Assignment") {
            declarations.append(renderAssignment())
        }
        if !handWrittenTypes.contains("Columns") {
            declarations.append(renderColumns())
        }
        if !handWrittenTypes.contains("StoredValues") && !declaresStored {
            declarations.append(contentsOf: renderStoredValues())
        }
        if case .subEntity = shape {
            declarations.append(contentsOf: renderSubEntityEntryPoints())
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

    /// The access of a generated class: `open` for a public entity, so that the sub-entities of
    /// another module inherit it.
    private var classAccess: String {
        access == "public " ? "open " : access
    }

    /// The type the generated static members return: the type's own name in a struct, `Self` in
    /// a class, so that a sub-entity's query built from a parent's member is the sub-entity's.
    private func memberType(_ name: String) -> String {
        shape == .finalRoot ? name : "Self"
    }

    /// The opening of a generated type up to its members: a struct for a final entity, a class
    /// for an open root, a class inheriting the parent's for a sub-entity, which declares no
    /// storage of its own.
    ///
    /// - Parameter storage: The stored members and initializer, given the initializer's
    ///   modifier (`required ` in a class).
    private func typeOpening(_ name: String, conformance: String, storage: (_ initModifier: String) -> String) -> String {
        switch shape {
        case .finalRoot:
            return "\(access)struct \(name): \(conformance) {\n\(storage(""))"
        case .openRoot:
            return "\(classAccess)class \(name): \(conformance) {\n\(storage("required "))"
        case .subEntity(let parent):
            return "\(isFinal ? "\(access)final " : classAccess)class \(name): \(parent).\(name) {\n"
        }
    }

    private func renderQuery() -> DeclSyntax {
        let queryType = memberType("Query")
        var members = ""
        for property in properties where !property.isSoftDeletionMark {
            let docLines = doc(property.docCommentLines, indent: "    ")
            switch property.kind {
            case .attribute(let exposedType):
                let encodedMatch = property.coder.map { "match.encoded(by: \($0).self)" } ?? "match"
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ match: AmphoraKit.Match<\(exposedType)>) -> \(queryType) {
                        .init(.match("\(property.storageName)", \(encodedMatch)))
                    }

                """
                // A value that can't be compared has no equality member, only the matches that
                // need no comparison (`.isNil`).
                guard property.isComparable else { continue }
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ value: \(exposedType)) -> \(queryType) {
                        .\(property.domainName)(.equal(value))
                    }

                """
            case .toOne(let target, let storageType):
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ match: AmphoraKit.Match<\(storageType)>) -> \(queryType) {
                        .init(.match("\(property.storageName)", match))
                    }
                \(docLines)    \(access)static func \(property.domainName)(_ query: \(target).Query) -> \(queryType) {
                        .init(.relation("\(property.storageName)", query.expression))
                    }

                """
            case .toMany(let element):
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ match: AmphoraKit.CollectionMatch<\(element)>) -> \(queryType) {
                        .init(.collection("\(property.storageName)", match))
                    }

                """
            }
        }

        return DeclSyntax(stringLiteral: """
        /// The typed predicate of `\(typeName)`, generated by `@Entity`.
        \(typeOpening("Query", conformance: "AmphoraKit.DatabaseQuery") { initModifier in """
            \(access)let expression: AmphoraKit.QueryExpression<\(typeName)>
            \(access)\(initModifier)init(_ expression: AmphoraKit.QueryExpression<\(typeName)>) {
                self.expression = expression
            }

        """ })\(members)}
        """)
    }

    private func renderSort() -> DeclSyntax {
        var members = ""
        for property in properties {
            // Ordering a coded column would order its encoding; a value holding `Any` has no order.
            guard case .attribute = property.kind, property.coder == nil, property.isComparable else { continue }
            let docLines = doc(property.docCommentLines, indent: "    ")
            members += """
            \(docLines)    \(access)static var \(property.domainName): \(memberType("Sort")) {
                    .init(key: "\(property.storageName)")
                }

            """
        }

        return DeclSyntax(stringLiteral: """
        /// The typed sort descriptor of `\(typeName)`, generated by `@Entity`.
        \(typeOpening("Sort", conformance: "AmphoraKit.DatabaseSort") { initModifier in """
            \(access)let expression: AmphoraKit.SortExpression<\(typeName)>
            \(access)\(initModifier)init(_ expression: AmphoraKit.SortExpression<\(typeName)>) {
                self.expression = expression
            }

        """ })\(members)}
        """)
    }

    private func renderAttributeAssignment() -> DeclSyntax {
        let attributeType = memberType("AttributeAssignment")
        var members = ""
        for property in properties {
            guard case .attribute(let exposedType) = property.kind,
                  !["storageKey", "storageValue"].contains(property.domainName) else { continue }
            // A column stored in another form also takes its stored value as is: a sync
            // recopying the server's value keeps what this version wouldn't decode.
            if property.storageType != exposedType {
                members += """
                    /// The stored form of `\(property.domainName)`, written as is.
                    \(access)static func \(property.domainName)(stored value: \(property.storageType)) -> \(attributeType) {
                        .init(storageKey: "\(property.storageName)", storageValue: value)
                    }

                """
            }
            if let coder = property.coder {
                let docLines = doc(property.docCommentLines, indent: "    ")
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ value: \(exposedType)) -> \(attributeType) {
                        .init(storageKey: "\(property.storageName)", storageValue: \(coder).encode(value))
                    }

                """
                continue
            }
            // An optional exposed over a non-optional column has no stored form for `nil`.
            // `OptionalStoredColumn` may be non-optional, with a stored form for `nil`.
            if TypeSyntax(stringLiteral: exposedType).optionalWrappedType != nil,
               TypeSyntax(stringLiteral: property.storageType).optionalWrappedType == nil,
               !property.storageType.hasSuffix(".OptionalStoredColumn") {
                continue
            }
            // A value that can't be nil is encoded to the wrapped column type: coercing to the
            // optional would match both the plain and the optional overloads of `write`.
            let storage = TypeSyntax(stringLiteral: property.storageType)
            let coercion = TypeSyntax(stringLiteral: exposedType).optionalWrappedType == nil
                ? (storage.optionalWrappedType?.trimmedDescription ?? property.storageType)
                : property.storageType
            let docLines = doc(property.docCommentLines, indent: "    ")
            members += """
            \(docLines)    \(access)static func \(property.domainName)(_ value: \(exposedType)) -> \(attributeType) {
                    .init(storageKey: "\(property.storageName)", storageValue: AmphoraKit.StoredAccessor.write(value) as \(coercion))
                }

            """
        }

        return DeclSyntax(stringLiteral: """
        /// The typed attribute values of `\(typeName)`, for batch requests too, generated by `@Entity`.
        \(typeOpening("AttributeAssignment", conformance: "AmphoraKit.EntityAttributeAssignment") { initModifier in """
            \(access)typealias Root = \(typeName)
            \(access)let storageKey: String
            \(access)let storageValue: Any?
            \(access)\(initModifier)init(storageKey: String, storageValue: Any?) {
                self.storageKey = storageKey
                self.storageValue = storageValue
            }

        """ })\(members)}
        """)
    }

    private func renderAssignment() -> DeclSyntax {
        let assignmentType = memberType("Assignment")
        var members = ""
        for property in properties {
            let docLines = doc(property.docCommentLines, indent: "    ")
            let key = property.storageName
            switch property.kind {
            case .attribute(let exposedType):
                guard !["storageKey", "storageValue"].contains(property.domainName) else { continue }
                // Every attribute assignment, forwarded: the same rules decide which exist.
                if property.storageType != exposedType {
                    members += """
                        /// The stored form of `\(property.domainName)`, written as is.
                        \(access)static func \(property.domainName)(stored value: \(property.storageType)) -> \(assignmentType) {
                            .init(AttributeAssignment.\(property.domainName)(stored: value))
                        }

                    """
                }
                if property.coder == nil,
                   TypeSyntax(stringLiteral: exposedType).optionalWrappedType != nil,
                   TypeSyntax(stringLiteral: property.storageType).optionalWrappedType == nil,
                   !property.storageType.hasSuffix(".OptionalStoredColumn") {
                    continue
                }
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ value: \(exposedType)) -> \(assignmentType) {
                        .init(AttributeAssignment.\(property.domainName)(value))
                    }

                """
            case .toOne(_, let storageType):
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ target: \(storageType)) -> \(assignmentType) {
                        .init(storageKey: "\(key)", storageValue: target)
                    }

                """
            case .toMany(let element):
                members += """
                \(docLines)    \(access)static func \(property.domainName)(_ targets: [\(element)]) -> \(assignmentType) {
                        .init(storageKey: "\(key)", storageValue: Set(targets))
                    }

                """
            }
        }

        return DeclSyntax(stringLiteral: """
        /// The typed attribute and relationship values of `\(typeName)` written on one object, generated by `@Entity`.
        \(typeOpening("Assignment", conformance: "AmphoraKit.EntityAssignment") { initModifier in """
            \(access)typealias Root = \(typeName)
            \(access)let storageKey: String
            \(access)let storageValue: Any?
            \(access)\(initModifier)init(storageKey: String, storageValue: Any?) {
                self.storageKey = storageKey
                self.storageValue = storageValue
            }

        """ })\(members)}
        """)
    }

    private func renderColumns() -> DeclSyntax {
        var members = ""
        for property in properties {
            // Coded columns too: a column carries the stored form, never the coder. And the
            // relationships, their storage being the related object (or set of objects).
            let defaultDoc: String
            switch property.kind {
            case .attribute:
                defaultDoc = "    /// The stored form of `\(property.domainName)`.\n"
            case .toOne, .toMany:
                defaultDoc = "    /// The `\(property.domainName)` relationship.\n"
            }
            let docLines = property.docCommentLines.isEmpty
                ? defaultDoc
                : doc(property.docCommentLines, indent: "    ")
            members += """
            \(docLines)    \(access)static var \(property.domainName): AmphoraKit.Column<\(typeName), \(property.storageType)> {
                    .init(key: "\(property.storageName)")
                }

            """
        }

        return DeclSyntax(stringLiteral: """
        /// The attributes and relationships of `\(typeName)` in their stored form, generated by `@Entity`.
        \(access)enum Columns {
        \(members)}
        """)
    }

    /// The read side of the stored-form assignments: `object.stored.kind` is the raw value of a
    /// coded or defaulted column, `object.stored.cue` the relationship as Core Data holds it, zombie
    /// or not — the code that copies or compares stored values as is reads these.
    private func renderStoredValues() -> [DeclSyntax] {
        var members = ""
        for property in properties {
            let defaultDoc: String
            switch property.kind {
            case .attribute:
                defaultDoc = "    /// The stored form of `\(property.domainName)`.\n"
            case .toOne, .toMany:
                defaultDoc = "    /// The `\(property.domainName)` relationship as stored, zombies included.\n"
            }
            let docLines = property.docCommentLines.isEmpty
                ? defaultDoc
                : doc(property.docCommentLines, indent: "    ")
            // A sub-entity's values read its own storage on the object its parent holds.
            let object = if case .subEntity = shape { "unsafeDowncast(object, to: \(typeName).self)" } else { "object" }
            members += """
            \(docLines)    \(access)var \(property.domainName): \(property.storageType) {
                    \(object).\(property.storageName)
                }

            """
        }

        let storedDoc = "/// The attributes and relationships as stored, for the code that copies or compares them as is."
        switch shape {
        case .finalRoot:
            return [
                DeclSyntax(stringLiteral: """
                /// The attributes and relationships of `\(typeName)` as stored, generated by `@Entity`: the raw
                /// value of a coded or defaulted column, a relationship as Core Data holds it.
                \(access)struct StoredValues {
                    /// The object read.
                    let object: \(typeName)
                \(members)}
                """),
                DeclSyntax(stringLiteral: """
                \(storedDoc)
                \(access)var stored: StoredValues {
                    StoredValues(object: self)
                }
                """),
            ]
        case .openRoot:
            // A class, so that a sub-entity's values inherit these and `stored` is overridden
            // with the sub-entity's.
            return [
                DeclSyntax(stringLiteral: """
                /// The attributes and relationships of `\(typeName)` as stored, generated by `@Entity`: the raw
                /// value of a coded or defaulted column, a relationship as Core Data holds it.
                \(classAccess)class StoredValues {
                    /// The object read.
                    \(access)let object: \(typeName)
                    \(access)init(object: \(typeName)) {
                        self.object = object
                    }
                \(members)}
                """),
                DeclSyntax(stringLiteral: """
                \(storedDoc)
                \(access)var stored: StoredValues {
                    StoredValues(object: self)
                }
                """),
            ]
        case .subEntity(let parent):
            return [
                DeclSyntax(stringLiteral: """
                /// The attributes and relationships of `\(typeName)` as stored, its parent's included, generated by `@Entity`.
                \(isFinal ? "\(access)final " : classAccess)class StoredValues: \(parent).StoredValues {
                \(members)}
                """),
                DeclSyntax(stringLiteral: """
                \(storedDoc)
                \(access)override var stored: StoredValues {
                    StoredValues(object: self)
                }
                """),
            ]
        }
    }

    /// The entry points of a sub-entity taking its own `Query`, `Sort` and assignments, so that
    /// their members resolve by implicit member: `Lens.fetch(matching: [.mount("PL")], in:)`.
    ///
    /// The conformance belongs to the root, whose APIs take the root's types: each entry point
    /// upcasts the sub-entity's values (`Lens.Query` inherits `Asset.Query`) and calls them. Being
    /// declared on the sub-entity, they are preferred to the root's, and a sub-entity's to its
    /// parent's, the most specific parameter type winning.
    private func renderSubEntityEntryPoints() -> [DeclSyntax] {
        let context = "AmphoraKit.DatabaseContext<Schema>"
        let queries = "queries as [RootEntity.Query]"
        let sorts = "sorts as [RootEntity.Sort]"
        let declarations = [
            """
            /// A fetch request on `\(typeName)`, filtered, sorted and limited, generated by `@Entity`.
            \(access)static func baseFetchRequest(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], limit: Int? = nil) -> AmphoraKit.EntityFetchRequest<\(typeName)> {
                baseFetchRequest(matching: \(queries), sortedBy: \(sorts), limit: limit)
            }
            """,
            """
            /// A typed request on `\(typeName)`, generated by `@Entity`: for `fetch(request:in:)` and `FetchController`.
            \(access)static func request(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], limit: Int? = nil) -> AmphoraKit.Request<\(typeName)> {
                AmphoraKit.Request(matching: \(queries), sortedBy: \(sorts), limit: limit)
            }
            """,
            """
            /// The `\(typeName)` objects matching every query, sorted, generated by `@Entity`.
            \(access)static func fetch(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], limit: Int? = nil, in context: \(context)) throws -> [\(typeName)] {
                try fetch(matching: \(queries), sortedBy: \(sorts), limit: limit, in: context)
            }
            """,
            """
            /// The `\(typeName)` objects matching the query, sorted, generated by `@Entity`.
            \(access)static func fetch(matching query: Query, sortedBy sorts: [Sort] = [], limit: Int? = nil, in context: \(context)) throws -> [\(typeName)] {
                try fetch(matching: [query], sortedBy: sorts, limit: limit, in: context)
            }
            """,
            """
            /// The first `\(typeName)` matching every query, in the sort order, generated by `@Entity`.
            \(access)static func fetchFirst(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], in context: \(context)) throws -> \(typeName)? {
                try fetchFirst(matching: \(queries), sortedBy: \(sorts), in: context)
            }
            """,
            """
            /// The first `\(typeName)` matching the query, in the sort order, generated by `@Entity`.
            \(access)static func fetchFirst(matching query: Query, sortedBy sorts: [Sort] = [], in context: \(context)) throws -> \(typeName)? {
                try fetchFirst(matching: [query], sortedBy: sorts, in: context)
            }
            """,
            """
            /// How many `\(typeName)` objects match every query, generated by `@Entity`.
            \(access)static func count(matching queries: [Query] = [], in context: \(context)) throws -> Int {
                try count(matching: \(queries), in: context)
            }
            """,
            """
            /// How many `\(typeName)` objects match the query, generated by `@Entity`.
            \(access)static func count(matching query: Query, in context: \(context)) throws -> Int {
                try count(matching: [query], in: context)
            }
            """,
            """
            /// Whether a `\(typeName)` matches every query, generated by `@Entity`.
            \(access)static func exists(matching queries: [Query] = [], in context: \(context)) throws -> Bool {
                try exists(matching: \(queries), in: context)
            }
            """,
            """
            /// Whether a `\(typeName)` matches the query, generated by `@Entity`.
            \(access)static func exists(matching query: Query, in context: \(context)) throws -> Bool {
                try exists(matching: [query], in: context)
            }
            """,
            """
            /// The `\(typeName)` objects matching every query, an empty array when the fetch fails (logged), generated by `@Entity`.
            \(access)static func fetchOrEmpty(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], limit: Int? = nil, in context: \(context)) -> [\(typeName)] {
                fetchOrEmpty(matching: \(queries), sortedBy: \(sorts), limit: limit, in: context)
            }
            """,
            """
            /// The `\(typeName)` objects matching the query, an empty array when the fetch fails (logged), generated by `@Entity`.
            \(access)static func fetchOrEmpty(matching query: Query, sortedBy sorts: [Sort] = [], limit: Int? = nil, in context: \(context)) -> [\(typeName)] {
                fetchOrEmpty(matching: [query], sortedBy: sorts, limit: limit, in: context)
            }
            """,
            """
            /// The first `\(typeName)` matching every query, `nil` when the fetch fails (logged), generated by `@Entity`.
            \(access)static func fetchFirstOrNil(matching queries: [Query] = [], sortedBy sorts: [Sort] = [], in context: \(context)) -> \(typeName)? {
                fetchFirstOrNil(matching: \(queries), sortedBy: \(sorts), in: context)
            }
            """,
            """
            /// The first `\(typeName)` matching the query, `nil` when the fetch fails (logged), generated by `@Entity`.
            \(access)static func fetchFirstOrNil(matching query: Query, sortedBy sorts: [Sort] = [], in context: \(context)) -> \(typeName)? {
                fetchFirstOrNil(matching: [query], sortedBy: sorts, in: context)
            }
            """,
            """
            /// Deletes the `\(typeName)` objects matching the query in a batch, generated by `@Entity`.
            \(access)static func deleteAll(matching query: Query = .all, in context: \(context)) throws {
                try deleteAll(matching: query as RootEntity.Query, in: context)
            }
            """,
            """
            /// Inserts `\(typeName)` objects in a batch, one row of assignments each, generated by `@Entity`.
            \(access)static func insert(_ rows: [[AttributeAssignment]], in context: \(context)) throws {
                try insert(rows.map { $0 as [RootEntity.AttributeAssignment] }, in: context)
            }
            """,
            """
            /// Sets values on the `\(typeName)` objects matching the query in a batch, generated by `@Entity`.
            \(access)static func update(matching query: Query, set assignments: [AttributeAssignment], in context: \(context)) throws {
                try update(matching: query as RootEntity.Query, set: assignments as [RootEntity.AttributeAssignment], in: context)
            }
            """,
            """
            /// Rewrites values on this object, generated by `@Entity`.
            \(access)func update(with assignments: [Assignment]) {
                update(with: assignments as [RootEntity.Assignment])
            }
            """,
        ]
        return declarations.map { DeclSyntax(stringLiteral: $0) }
    }

    private func renderField(_ property: Property) -> DeclSyntax? {
        let valueType: String
        switch property.kind {
        case .attribute(let exposedType):
            valueType = exposedType
        case .toOne(_, let storageType):
            valueType = storageType
        case .toMany:
            valueType = property.storageType
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
