//
//  Plugin.swift
//  LLVS
//
//  Created by Drew McCormack on 04/03/2026.
//

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct LLVSModelMacroPlugin: CompilerPlugin {
    var providingMacros: [Macro.Type] = [
        MergeableModelMacro.self,
    ]
}
