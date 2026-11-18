import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct AmphoraKitMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        EntityMacro.self,
        StoredMacro.self,
        StorageOnlyMacro.self
    ]
}
