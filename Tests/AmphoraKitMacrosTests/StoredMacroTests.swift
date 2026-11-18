import XCTest
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import AmphoraKitMacrosPlugin

final class StoredMacroTests: XCTestCase {

    private let macros: [String: any Macro.Type] = ["Stored": StoredMacro.self]

    func testReadonlyAccessor() {
        assertMacroExpansion(
            """
            final class Note: NSManagedObject {
                @NSManaged var a_pinned: Bool
                /// Whether the note is pinned.
                @Stored(\\.a_pinned) var isPinned: Bool
            }
            """,
            expandedSource: """
            final class Note: NSManagedObject {
                @NSManaged var a_pinned: Bool
                /// Whether the note is pinned.
                var isPinned: Bool {
                    get {
                        AmphoraKit.StoredAccessor.read(self.a_pinned)
                    }
                }
            }
            """,
            macros: macros,
            indentationWidth: .spaces(4)
        )
    }

    func testReadWriteAccessorWithDefault() {
        assertMacroExpansion(
            """
            final class Note: NSManagedObject {
                @NSManaged var a_kind: String
                @Stored(\\Note.a_kind, default: Kind.note, access: .readWrite) var kind: Kind
            }
            """,
            expandedSource: """
            final class Note: NSManagedObject {
                @NSManaged var a_kind: String
                var kind: Kind {
                    get {
                        AmphoraKit.StoredAccessor.read(self.a_kind, default: Kind.note)
                    }
                    set {
                        self.a_kind = AmphoraKit.StoredAccessor.write(newValue)
                    }
                }
            }
            """,
            macros: macros,
            indentationWidth: .spaces(4)
        )
    }

    func testRejectsLetAndInitialValue() {
        assertMacroExpansion(
            """
            final class Note: NSManagedObject {
                @Stored(\\.a_pinned) let isPinned: Bool
                @Stored(\\.a_kind) var kind: Kind = .note
            }
            """,
            expandedSource: """
            final class Note: NSManagedObject {
                let isPinned: Bool
                var kind: Kind = .note
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'@Stored' requires 'var': the property becomes computed", line: 2, column: 5),
                DiagnosticSpec(message: "'@Stored' property can't have an initial value; use 'default:' for a fallback", line: 3, column: 5)
            ],
            macros: macros,
            indentationWidth: .spaces(4)
        )
    }
}
