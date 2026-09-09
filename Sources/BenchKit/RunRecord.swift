import Foundation

/// One bench run's typed record — the provenance frame every tool's output
/// shares. Evidence cites *tool @ commit × run UUID* (PWB
/// `design/host-toolbox.md` R53), and this type is where those parts live:
/// who ran what, when, against which unit, with which code, ending how. The
/// measured results are a `JSONValue` tree the tool owns; raw capture files
/// sit beside the record in its run directory.
public struct RunRecord: Codable, Equatable, Sendable {
    /// Bumped when a field changes shape or meaning. A reader refuses a
    /// version it does not know rather than guess (`RunRecordError`).
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The run UUID — the key evidence docs cite and the store files under.
    public var id: UUID
    /// The registered tool name, glossary noun–verb (`wire.survey`,
    /// `lovense.link-timing`).
    public var tool: String
    /// The code that ran: the producing repo's commit hash, with a `-dirty`
    /// suffix when the working tree was not clean. Free-form until C2
    /// publication settles what "the" repo is for a multi-repo build.
    public var commit: String
    /// Provenance timestamps, second precision — measurements with real
    /// timing requirements belong in `results` or the captures.
    public var started: Date
    public var ended: Date
    /// The benched unit as the catalogue names it; nil for unit-less tools
    /// (a wire survey names its target in `arguments` instead).
    public var unit: String?
    /// The invocation arguments as given, so the run is re-runnable.
    public var arguments: [String: String]
    public var outcome: Outcome
    /// Raw capture files in the run directory, paths relative to the record.
    public var captures: [String]
    /// The tool's measured results; shape owned by the tool.
    public var results: JSONValue

    /// Mirrors the CLI's exit-code convention: `pass` and `fail` are the
    /// tool's verdict on the device, `error` means the run itself broke.
    public enum Outcome: String, Codable, Sendable {
        case pass, fail, error
    }

    public init(id: UUID = UUID(), tool: String, commit: String,
                started: Date, ended: Date, unit: String? = nil,
                arguments: [String: String] = [:], outcome: Outcome,
                captures: [String] = [], results: JSONValue = .object([:])) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.tool = tool
        self.commit = commit
        self.started = started
        self.ended = ended
        self.unit = unit
        self.arguments = arguments
        self.outcome = outcome
        self.captures = captures
        self.results = results
    }
}
