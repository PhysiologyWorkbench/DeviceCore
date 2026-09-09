import Foundation
import DeviceCore

/// One bench run's typed record — the provenance frame every tool's output
/// shares, and nothing else (R56, PWB `design/bench-host-toolbox.md`).
/// Evidence cites *tool @ commit × run UUID* (R53), and this type is where
/// those parts live: who ran what, when, against which units, with which
/// code, ending how. The measured results are `results.json` beside the
/// record, written by the runner; raw capture files sit in the same run
/// directory.
public struct RunRecord: Codable, Equatable, Sendable {
    /// Bumped when a field changes shape or meaning. A reader refuses a
    /// version it does not know rather than guess (`RunRecordError`).
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The run UUID — the key evidence docs cite and the store files under.
    public var runUUID: UUID
    /// The registered tool name, glossary noun–verb (`wire.survey`,
    /// `lovense.link-timing`).
    public var toolName: String
    /// The code that ran: repo directory basename → commit hash, `-dirty`
    /// suffixed when that working tree was not clean. The executable
    /// supplies the table — pre-C2 from the sibling checkouts it links,
    /// post-publication from `Package.resolved`.
    public var commits: [String: String]
    /// Provenance timestamps, second precision — measurements with real
    /// timing requirements belong in the results or the captures.
    public var started: Date
    public var ended: Date
    /// The units of the run, in the shape of PWB `design/unit-identity.md`
    /// (R55): the tool's rows (`dut`, `reference`, `path`) and the one
    /// `host` row the runner writes.
    public var units: [PhysicalUnit]
    /// The invocation arguments as given, so the run is re-runnable.
    public var arguments: [String: String]
    public var outcome: Outcome
    /// The tool's own files in the run directory, paths relative to the
    /// record; `record.json` and `results.json` are the frame's, not listed.
    public var captureFiles: [String]
    /// R54's stamp (PWB `design/bench-host-toolbox.md`, "The export
    /// boundary"): absent on every bench-made record; `nonBenchImport` on a
    /// record `pwb record export --file` produced from a recording that
    /// carries no run UUID, so the exception is visible in the store rather
    /// than silent.
    public var origin: Origin?

    /// Mirrors the CLI's exit-code convention: `pass` and `fail` are the
    /// tool's verdict on the device, `error` means the run itself broke.
    public enum Outcome: String, Codable, Sendable {
        case pass, fail, error

        /// The exit code the CLI convention assigns: 0 pass, 1 fail, 2 error.
        public var exitCode: Int32 {
            switch self {
            case .pass: 0
            case .fail: 1
            case .error: 2
            }
        }
    }

    public enum Origin: String, Codable, Sendable {
        case nonBenchImport = "non-bench-import"
    }

    public init(runUUID: UUID = UUID(), toolName: String,
                commits: [String: String], started: Date, ended: Date,
                units: [PhysicalUnit] = [], arguments: [String: String] = [:],
                outcome: Outcome, captureFiles: [String] = [],
                origin: Origin? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.runUUID = runUUID
        self.toolName = toolName
        self.commits = commits
        self.started = started
        self.ended = ended
        self.units = units
        self.arguments = arguments
        self.outcome = outcome
        self.captureFiles = captureFiles
        self.origin = origin
    }
}
