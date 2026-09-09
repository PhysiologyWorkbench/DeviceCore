import Foundation

/// One host-side bench tool: the frame the vendor kits fill (R46, PWB
/// `design/bench-host-toolbox.md` layer 1). A tool measures and verdicts; the
/// provenance frame around it — run UUID, commit, timestamps, the record on
/// disk — is `BenchToolRunner`'s, so every tool's output lands in the same
/// typed record.
public protocol BenchTool: Sendable {
    /// Registered name, glossary noun–verb dot-joined: `wire.survey`,
    /// `lovense.link-timing`.
    var name: String { get }
    /// One line for `pwb bench list`.
    var synopsis: String { get }
    /// The arguments the tool understands. The runner refuses an invocation
    /// missing a required one or carrying an undeclared one, before a run
    /// record exists — a bad invocation is not a bench run.
    var declaredArguments: [BenchToolArgument] { get }
    /// One run. Captures go into `context.runDirectory`; everything found
    /// there afterwards is recorded as a capture. Throwing ends the run as
    /// `.error` — a verdict on the *device* is a returned `.fail` instead.
    func run(_ context: BenchContext) async throws -> BenchToolOutput
}

/// One declared argument, validated by the runner before the tool sees it.
public struct BenchToolArgument: Equatable, Sendable {
    /// Bare name; the CLI spells it `--name`.
    public let name: String
    public let help: String
    public let required: Bool

    public init(name: String, help: String, required: Bool = false) {
        self.name = name
        self.help = help
        self.required = required
    }
}

/// What the runner hands a tool: the validated arguments and the minted run
/// directory.
public struct BenchContext: Sendable {
    public let arguments: [String: String]
    public let unit: String?
    public let runDirectory: URL

    public init(arguments: [String: String], unit: String?, runDirectory: URL) {
        self.arguments = arguments
        self.unit = unit
        self.runDirectory = runDirectory
    }

    /// Where a capture of this name belongs. Naming convention: lowercase,
    /// hyphenated, extension by content — `advertisements.jsonl`,
    /// `gatt-walk.json`, `notify-log.csv`.
    public func captureURL(_ name: String) -> URL {
        runDirectory.appendingPathComponent(name)
    }
}

/// The tool-owned half of a run's outcome; the runner wraps it in the record.
public struct BenchToolOutput: Sendable {
    public var outcome: RunRecord.Outcome
    public var results: JSONValue

    public init(outcome: RunRecord.Outcome, results: JSONValue = .object([:])) {
        self.outcome = outcome
        self.results = results
    }
}
