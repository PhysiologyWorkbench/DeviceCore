import Foundation
import DeviceCore

/// Runs one tool inside the provenance frame (R53: evidence is *tool @
/// commit × run UUID*): validates the invocation against the tool's declared
/// arguments, mints the run UUID and its store directory, stamps commits,
/// timestamps and the `host` unit row, folds a thrown error into an `.error`
/// outcome rather than losing the run, records the run directory's contents
/// as the capture files, writes the tool's results to `results.json`, and
/// writes the record. The CLI maps the outcome straight to its exit code
/// (`RunRecord.Outcome.exitCode`).
public struct BenchToolRunner: Sendable {
    public let store: RunRecordStore
    /// `RunRecord.commits` for the records this runner writes; the
    /// executable supplies the table — a library cannot know which repos
    /// built the tool chain.
    public let commits: [String: String]
    /// The `host` unit row, exactly one per record; injectable so tests
    /// write deterministic records.
    public let host: PhysicalUnit

    public init(store: RunRecordStore, commits: [String: String],
                host: PhysicalUnit = HostUnit.current()) {
        self.store = store
        self.commits = commits
        self.host = host
    }

    @discardableResult
    public func run(_ tool: any BenchTool, arguments: [String: String] = [:],
                    unitLabel: String? = nil) async throws -> RunRecord {
        let declared = Set(tool.declaredArguments.map(\.name))
        for name in arguments.keys.sorted() where !declared.contains(name) {
            throw BenchToolError.undeclaredArgument(name)
        }
        for argument in tool.declaredArguments
        where argument.required && arguments[argument.name] == nil {
            throw BenchToolError.missingArgument(argument.name)
        }
        let runUUID = UUID()
        let directory = store.directory(for: runUUID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = BenchContext(arguments: arguments, runDirectory: directory)
        let started = Self.wholeSecond()
        let output: BenchToolOutput
        do {
            output = try await tool.run(context)
        } catch {
            output = BenchToolOutput(
                outcome: .error,
                results: .object(["error": .string(String(describing: error))]))
        }
        let captureFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != "record.json" && $0 != "results.json" }.sorted()
        let record = RunRecord(runUUID: runUUID, toolName: tool.name, commits: commits,
                               started: started, ended: Self.wholeSecond(),
                               units: Self.units(of: output, host: host, label: unitLabel),
                               arguments: arguments, outcome: output.outcome,
                               captureFiles: captureFiles)
        try store.writeResults(output.results, for: runUUID)
        try store.write(record)
        return record
    }

    /// The tool's rows, then the one `host` row. A `--unit` label lands on
    /// the tool's dut row when it has none, and mints a label-only dut row
    /// for a tool that wrote none.
    static func units(of output: BenchToolOutput, host: PhysicalUnit,
                      label: String?) -> [PhysicalUnit] {
        var units = output.units
        if let label {
            if let index = units.firstIndex(where: { $0.role == .dut && $0.label == nil }) {
                units[index].label = label
            } else if !units.contains(where: { $0.role == .dut }) {
                units.append(PhysicalUnit(role: .dut, label: label))
            }
        }
        return units + [host]
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
