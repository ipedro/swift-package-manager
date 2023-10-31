//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014-2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import Foundation
import PackageLoading

import class TSCBasic.Process

public protocol AuxiliaryFileType {
    static var name: String { get }

    static func getFileContents(inputs: [Node]) throws -> String
}

public enum WriteAuxiliary {
    public static let fileTypes: [AuxiliaryFileType.Type] = [
        ClangModuleMap.self,
        EntitlementPlist.self,
        LinkFileList.self,
        SourcesFileList.self,
        SwiftGetVersion.self,
        SwiftModuleMap.self,
        XCTestInfoPlist.self
    ]

    public struct EntitlementPlist: AuxiliaryFileType {
        public static let name = "entitlement-plist"

        public static func computeInputs(entitlement: String) -> [Node] {
            [.virtual(Self.name), .virtual(entitlement)]
        }

        public static func getFileContents(inputs: [Node]) throws -> String {
            guard let entitlementName = inputs.last?.extractedVirtualNodeName else {
                throw Error.undefinedEntitlementName
            }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let result = try encoder.encode([entitlementName: true])

            let contents = String(decoding: result, as: UTF8.self)
            return contents
        }

        private enum Error: Swift.Error {
            case undefinedEntitlementName
        }
    }

    public struct SwiftModuleMap: AuxiliaryFileType {
        public static let name = "swift-modulemap"

        public static func computeInputs(
            moduleName: String,
            objCompatibilityHeaderPath: AbsolutePath
        ) -> [Node] {
            return [
                .virtual(Self.name),
                .virtual(moduleName),
                // this can't be a path since we don't create any rule to generate this file, it's a byproduct of the compilation
                .virtual(objCompatibilityHeaderPath.pathString)
            ]
        }

        public static func getFileContents(inputs: [Node]) throws -> String {
            guard inputs.count == 2 else {
                throw StringError("invalid module map generation task, inputs: \(inputs)")
            }

            let moduleName = inputs[0].extractedVirtualNodeName
            let objCompatibilityHeaderPath = try AbsolutePath(validating: inputs[1].extractedVirtualNodeName)

            return #"""
                module \#(moduleName) {
                    header "\#(objCompatibilityHeaderPath.pathString)"
                    requires objc
                }

                """#
        }
    }

    public struct ClangModuleMap: AuxiliaryFileType {
        public static let name = "modulemap"

        private enum GeneratedModuleMapType: String {
            case umbrellaDirectory
            case umbrellaHeader
        }

        public static func computeInputs(
            targetName: String, 
            moduleName: String, 
            publicHeadersDir: AbsolutePath, 
            type: PackageLoading.GeneratedModuleMapType
        ) -> [Node] {
            let typeNodes: [Node]
            switch type {
            case .umbrellaDirectory(let path):
                typeNodes = [.virtual(GeneratedModuleMapType.umbrellaDirectory.rawValue), .directory(path)]
            case .umbrellaHeader(let path):
                typeNodes = [.virtual(GeneratedModuleMapType.umbrellaHeader.rawValue), .file(path)]
            }
            return [.virtual(Self.name), .virtual(targetName), .virtual(moduleName), .directory(publicHeadersDir)] + typeNodes
        }

        public static func getFileContents(inputs: [Node]) throws -> String {
            guard inputs.count == 5 else {
                throw StringError("invalid module map generation task, inputs: \(inputs)")
            }

            let generator = ModuleMapGenerator(
                targetName: inputs[0].extractedVirtualNodeName,
                moduleName: inputs[1].extractedVirtualNodeName,
                publicHeadersDir: try AbsolutePath(validating: inputs[2].name),
                fileSystem: localFileSystem
            )

            let declaredType = inputs[3].extractedVirtualNodeName
            let path = try AbsolutePath(validating: inputs[4].name)
            let type: PackageLoading.GeneratedModuleMapType
            switch declaredType {
            case GeneratedModuleMapType.umbrellaDirectory.rawValue:
                type = .umbrellaDirectory(path)
            case GeneratedModuleMapType.umbrellaHeader.rawValue:
                type = .umbrellaHeader(path)
            default:
                throw StringError("invalid module map type in generation task: \(declaredType)")
            }

            return try generator.generateModuleMap(type: type)
        }
    }

    public struct LinkFileList: AuxiliaryFileType {
        public static let name = "link-file-list"

        // FIXME: We should extend the `InProcessTool` support to allow us to specify these in a typed way, but today we have to flatten all the inputs into a generic `Node` array (rdar://109844243).
        public static func computeInputs(objects: [AbsolutePath]) -> [Node] {
            return [.virtual(Self.name)] + objects.map { Node.file($0) }
        }

        public static func getFileContents(inputs: [Node]) throws -> String {
            let objects = inputs.compactMap {
                if $0.kind == .file {
                    return $0.name
                } else {
                    return nil
                }
            }

            var content = objects
                .map { $0.spm_shellEscaped() }
                .joined(separator: "\n")

            // not sure this is needed, added here for backward compatibility
            if !content.isEmpty {
                content.append("\n")
            }

            return content
        }
    }

    public struct SourcesFileList: AuxiliaryFileType {
        public static let name = "sources-file-list"

        public static func computeInputs(sources: [AbsolutePath]) -> [Node] {
            return [.virtual(Self.name)] + sources.map { Node.file($0) }
        }

        public static func getFileContents(inputs: [Node]) throws -> String {
            let sources = inputs.compactMap {
                if $0.kind == .file {
                    return $0.name
                } else {
                    return nil
                }
            }

            guard sources.count > 0 else { return "" }

            var contents = sources
                .map { $0.spm_shellEscaped() }
                .joined(separator: "\n")
            contents.append("\n")
            return contents
        }
    }

    public struct SwiftGetVersion: AuxiliaryFileType {
        public static let name = "swift-get-version"

        public static func computeInputs(swiftCompilerPath: AbsolutePath) -> [Node] {
            return [.virtual(Self.name), .file(swiftCompilerPath)]
        }

        public static func getFileContents(inputs: [Node]) throws -> String {
            guard let swiftCompilerPathString = inputs.first(where: { $0.kind == .file })?.name else {
                throw Error.unknownSwiftCompilerPath
            }
            let swiftCompilerPath = try AbsolutePath(validating: swiftCompilerPathString)
            return try TSCBasic.Process.checkNonZeroExit(args: swiftCompilerPath.pathString, "-version")
        }

        private enum Error: Swift.Error {
            case unknownSwiftCompilerPath
        }
    }

    public struct XCTestInfoPlist: AuxiliaryFileType {
        public static let name = "xctest-info-plist"

        public static func computeInputs(principalClass: String) -> [Node] {
            return [.virtual(Self.name), .virtual(principalClass)]
        }

        public static func getFileContents(inputs: [Node]) throws -> String {
            guard let principalClass = inputs.last?.extractedVirtualNodeName else {
                throw Error.undefinedPrincipalClass
            }

            let plist = InfoPlist(NSPrincipalClass: String(principalClass))
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let result = try encoder.encode(plist)

            let contents = String(decoding: result, as: UTF8.self)
            return contents
        }

        private struct InfoPlist: Codable {
            let NSPrincipalClass: String
        }

        private enum Error: Swift.Error {
            case undefinedPrincipalClass
        }
    }
}

public struct LLBuildManifest {
    public typealias TargetName = String
    public typealias CmdName = String

    /// The targets in the manifest.
    public private(set) var targets: [TargetName: Target] = [:]

    /// The commands in the manifest.
    public private(set) var commands: [CmdName: Command] = [:]

    /// The default target to build.
    public var defaultTarget: String = ""

    public init() {
    }

    public func getCmdToolMap<T: ToolProtocol>(kind: T.Type) -> [CmdName: T] {
        var result = [CmdName: T]()
        for (cmdName, cmd) in commands {
            if let tool = cmd.tool as? T {
                result[cmdName] = tool
            }
        }
        return result
    }

    public mutating func createTarget(_ name: TargetName) {
        guard !targets.keys.contains(name) else { return }
        targets[name] = Target(name: name, nodes: [])
    }

    public mutating func addNode(_ node: Node, toTarget target: TargetName) {
        targets[target, default: Target(name: target, nodes: [])].nodes.append(node)
    }

    public mutating func addPhonyCmd(
        name: String,
        inputs: [Node],
        outputs: [Node]
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = PhonyTool(inputs: inputs, outputs: outputs)
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addTestDiscoveryCmd(
        name: String,
        inputs: [Node],
        outputs: [Node]
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = TestDiscoveryTool(inputs: inputs, outputs: outputs)
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addTestEntryPointCmd(
        name: String,
        inputs: [Node],
        outputs: [Node]
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = TestEntryPointTool(inputs: inputs, outputs: outputs)
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addCopyCmd(
        name: String,
        inputs: [Node],
        outputs: [Node]
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = CopyTool(inputs: inputs, outputs: outputs)
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addEntitlementPlistCommand(entitlement: String, outputPath: AbsolutePath) {
        let inputs = WriteAuxiliary.EntitlementPlist.computeInputs(entitlement: entitlement)
        let tool = WriteAuxiliaryFile(inputs: inputs, outputFilePath: outputPath)
        let name = outputPath.pathString
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addWriteLinkFileListCommand(
        objects: [AbsolutePath],
        linkFileListPath: AbsolutePath
    ) {
        let inputs = WriteAuxiliary.LinkFileList.computeInputs(objects: objects)
        let tool = WriteAuxiliaryFile(inputs: inputs, outputFilePath: linkFileListPath)
        let name = linkFileListPath.pathString
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addWriteSourcesFileListCommand(
        sources: [AbsolutePath],
        sourcesFileListPath: AbsolutePath
    ) {
        let inputs = WriteAuxiliary.SourcesFileList.computeInputs(sources: sources)
        let tool = WriteAuxiliaryFile(inputs: inputs, outputFilePath: sourcesFileListPath)
        let name = sourcesFileListPath.pathString
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addSwiftGetVersionCommand(
        swiftCompilerPath: AbsolutePath,
        swiftVersionFilePath: AbsolutePath
    ) {
        let inputs = WriteAuxiliary.SwiftGetVersion.computeInputs(swiftCompilerPath: swiftCompilerPath)
        let tool = WriteAuxiliaryFile(inputs: inputs, outputFilePath: swiftVersionFilePath, alwaysOutOfDate: true)
        let name = swiftVersionFilePath.pathString
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addWriteInfoPlistCommand(principalClass: String, outputPath: AbsolutePath) {
        let inputs = WriteAuxiliary.XCTestInfoPlist.computeInputs(principalClass: principalClass)
        let tool = WriteAuxiliaryFile(inputs: inputs, outputFilePath: outputPath)
        let name = outputPath.pathString
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addWriteSwiftModuleMapCommand(
        moduleName: String,
        objCompatibilityHeaderPath: AbsolutePath,
        outputPath: AbsolutePath
    ) {
        let inputs = WriteAuxiliary.SwiftModuleMap.computeInputs(
            moduleName: moduleName,
            objCompatibilityHeaderPath: objCompatibilityHeaderPath
        )
        let tool = WriteAuxiliaryFile(inputs: inputs, outputFilePath: outputPath)
        let name = outputPath.pathString
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addWriteClangModuleMapCommand(
        targetName: String,
        moduleName: String,
        publicHeadersDir: AbsolutePath,
        type: GeneratedModuleMapType,
        outputPath: AbsolutePath
    ) {
        let inputs = WriteAuxiliary.ClangModuleMap.computeInputs(
            targetName: targetName,
            moduleName: moduleName,
            publicHeadersDir: publicHeadersDir,
            type: type
        )
        let tool = WriteAuxiliaryFile(inputs: inputs, outputFilePath: outputPath)
        let name = outputPath.pathString
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addPkgStructureCmd(
        name: String,
        inputs: [Node],
        outputs: [Node]
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = PackageStructureTool(inputs: inputs, outputs: outputs)
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addShellCmd(
        name: String,
        description: String,
        inputs: [Node],
        outputs: [Node],
        arguments: [String],
        environment: EnvironmentVariables = .empty(),
        workingDirectory: String? = nil,
        allowMissingInputs: Bool = false
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = ShellTool(
            description: description,
            inputs: inputs,
            outputs: outputs,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            allowMissingInputs: allowMissingInputs
        )
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addSwiftFrontendCmd(
        name: String,
        moduleName: String,
        packageName: String,
        description: String,
        inputs: [Node],
        outputs: [Node],
        arguments: [String]
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = SwiftFrontendTool(
                moduleName: moduleName,
                description: description,
                inputs: inputs,
                outputs: outputs,
                arguments: arguments
        )
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addClangCmd(
        name: String,
        description: String,
        inputs: [Node],
        outputs: [Node],
        arguments: [String],
        dependencies: String? = nil
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = ClangTool(
            description: description,
            inputs: inputs,
            outputs: outputs,
            arguments: arguments,
            dependencies: dependencies
        )
        commands[name] = Command(name: name, tool: tool)
    }

    public mutating func addSwiftCmd(
        name: String,
        inputs: [Node],
        outputs: [Node],
        executable: AbsolutePath,
        moduleName: String,
        moduleAliases: [String: String]?,
        moduleOutputPath: AbsolutePath,
        importPath: AbsolutePath,
        tempsPath: AbsolutePath,
        objects: [AbsolutePath],
        otherArguments: [String],
        sources: [AbsolutePath],
        fileList: AbsolutePath,
        isLibrary: Bool,
        wholeModuleOptimization: Bool,
        outputFileMapPath: AbsolutePath
    ) {
        assert(commands[name] == nil, "already had a command named '\(name)'")
        let tool = SwiftCompilerTool(
            inputs: inputs,
            outputs: outputs,
            executable: executable,
            moduleName: moduleName,
            moduleAliases: moduleAliases,
            moduleOutputPath: moduleOutputPath,
            importPath: importPath,
            tempsPath: tempsPath,
            objects: objects,
            otherArguments: otherArguments,
            sources: sources,
            fileList: fileList,
            isLibrary: isLibrary,
            wholeModuleOptimization: wholeModuleOptimization,
            outputFileMapPath: outputFileMapPath
        )
        commands[name] = Command(name: name, tool: tool)
    }
}
