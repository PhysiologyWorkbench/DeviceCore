import Foundation

/// Runs one tool inside the provenance frame (R53: evidence is *tool @
/// commit × run UUID*): validates the invocation against the tool's declared
/// arguments, mints the run UUID and its store directory, stamps commit and
/// timestamps, folds a thrown error into an `.error` outcome rather than
/// losing the run, records the run directory's contents as the captures, and
/// writes the record. The CLI maps the outcome straight to its exit code
/// (`RunRecord.Outcome.exitCode`).
public struct BenchToolRunner: Sendable {
    public let store: RunRecordStore
    /// The producing repo's commit for `RunRecord.commit`; the executable
    /// supplies it — a library cannot know which repo built the tool chain.
    public let commit: String

    public init(store: RunRecordStore, commit: String) {
        self.store = store
        self.commit = commit
    }

    @discardableResult
    public func run(_ tool: any BenchTool, arguments: [String: String] = [:],
                    unit: String? = nil) async throws -> RunRecord {
        let declared = Set(tool.declaredArguments.map(\.name))
        for name in arguments.keys.sorted() where !declared.contains(name) {
            throw BenchToolError.undeclaredArgument(name)
        }
        for argument in tool.declaredArguments
        where argument.required && arguments[argument.name] == nil {
            throw BenchToolError.missingArgument(argument.name)
        }
        let id = UUID()
        let directory = store.directory(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = BenchContext(arguments: arguments, unit: unit, runDirectory: directory)
        let started = Self.wholeSecond()
        let output: BenchToolOutput
        do {
            output = try await tool.run(context)
        } catch {
            output = BenchToolOutput(
                outcome: .error,
                results: .object(["error": .string(String(describing: error))]))
        }
        let captures = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != "record.json" }.sorted()
        let record = RunRecord(id: id, tool: tool.name, commit: commit,
                               started: started, ended: Self.wholeSecond(), unit: unit,
                               arguments: arguments, outcome: output.outcome,
                               captures: captures, results: output.results)
        try store.write(record)
        return record
    }

    /// The schema carries provenance timestamps at second precision; stamping
    /// whole seconds keeps the returned record equal to its store round-trip.
    private static func wholeSecond() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }
}

/// Invocation and registration errors — raised before a run record exists.
public enum BenchToolError: Error, Equatable {
    case duplicateToolName(String)
    case missingArgument(String)
    case undeclaredArgument(String)
}
