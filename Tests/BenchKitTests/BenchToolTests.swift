import Testing
import Foundation
@testable import BenchKit

/// A tool that writes one capture and reports what it was handed.
private struct EchoTool: BenchTool {
    let name = "wire.echo"
    let synopsis = "writes one capture, echoes its arguments"
    let declaredArguments = [
        BenchToolArgument(name: "target", help: "the device address", required: true),
        BenchToolArgument(name: "seconds", help: "how long to listen"),
    ]

    func run(_ context: BenchContext) async throws -> BenchToolOutput {
        try Data("{}\n".utf8).write(to: context.captureURL("advertisements.jsonl"))
        return BenchToolOutput(
            outcome: .pass,
            results: .object(["target": .string(context.arguments["target"] ?? "")]))
    }
}

private struct BrokenTool: BenchTool {
    struct Radio: Error {}
    let name = "wire.broken"
    let synopsis = "throws mid-run"
    let declaredArguments: [BenchToolArgument] = []

    func run(_ context: BenchContext) async throws -> BenchToolOutput {
        try Data("partial\n".utf8).write(to: context.captureURL("partial.csv"))
        throw Radio()
    }
}

@Suite struct BenchToolTests {
    let store: RunRecordStore
    let runner: BenchToolRunner

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BenchToolTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RunRecordStore(root: root)
        runner = BenchToolRunner(store: store, commit: "0123abc-dirty")
    }

    @Test func wrapsAToolRunInTheProvenanceFrame() async throws {
        let record = try await runner.run(EchoTool(), arguments: ["target": "F0:12:34"],
                                          unit: "Pine64 PineTime")
        #expect(record.tool == "wire.echo")
        #expect(record.commit == "0123abc-dirty")
        #expect(record.unit == "Pine64 PineTime")
        #expect(record.arguments == ["target": "F0:12:34"])
        #expect(record.outcome == .pass)
        #expect(record.captures == ["advertisements.jsonl"])
        #expect(record.results == .object(["target": .string("F0:12:34")]))
        #expect(record.started <= record.ended)
        #expect(record.origin == nil)
        #expect(try store.read(id: record.id) == record)
    }

    @Test func refusesAMissingRequiredArgumentWithoutMintingARun() async throws {
        await #expect(throws: BenchToolError.missingArgument("target")) {
            try await runner.run(EchoTool())
        }
        #expect(try store.list().isEmpty)
    }

    @Test func refusesAnUndeclaredArgumentWithoutMintingARun() async throws {
        await #expect(throws: BenchToolError.undeclaredArgument("tarpit")) {
            try await runner.run(EchoTool(), arguments: ["target": "F0", "tarpit": "1"])
        }
        #expect(try store.list().isEmpty)
    }

    @Test func foldsAThrownErrorIntoAnErrorRecord() async throws {
        let record = try await runner.run(BrokenTool())
        #expect(record.outcome == .error)
        #expect(record.captures == ["partial.csv"])
        guard case .object(let results) = record.results else {
            Issue.record("results not an object")
            return
        }
        #expect(results["error"] != nil)
        #expect(try store.read(id: record.id) == record)
    }

    @Test func registryMergesCataloguesNameSortedAndDispatches() throws {
        let registry = try BenchToolRegistry(catalogues: [
            BenchCatalogue(noun: "wire", tools: [EchoTool(), BrokenTool()]),
        ])
        #expect(registry.tools.map(\.name) == ["wire.broken", "wire.echo"])
        #expect(registry.tool(named: "wire.echo") != nil)
        #expect(registry.tool(named: "wire.absent") == nil)
    }

    @Test func registryRefusesADuplicateToolName() {
        #expect(throws: BenchToolError.duplicateToolName("wire.echo")) {
            try BenchToolRegistry(catalogues: [
                BenchCatalogue(noun: "wire", tools: [EchoTool()]),
                BenchCatalogue(noun: "polar", tools: [EchoTool()]),
            ])
        }
    }

    @Test func outcomesMapToTheExitCodeConvention() {
        #expect(RunRecord.Outcome.pass.exitCode == 0)
        #expect(RunRecord.Outcome.fail.exitCode == 1)
        #expect(RunRecord.Outcome.error.exitCode == 2)
    }

    @Test func benchRecordsCarryNoOriginFieldAndTheImportStampRoundTrips() async throws {
        // R54: the stamp marks the exception only — a bench-made record.json
        // must not even mention "origin".
        let record = try await runner.run(EchoTool(), arguments: ["target": "F0"])
        let url = store.directory(for: record.id).appendingPathComponent("record.json")
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!text.contains("origin"))

        var stamped = record
        stamped.origin = .nonBenchImport
        try store.write(stamped)
        let reread = try store.read(id: record.id)
        #expect(reread.origin == .nonBenchImport)
        let stampedText = String(
            decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(stampedText.contains("\"origin\" : \"non-bench-import\""))
    }
}
