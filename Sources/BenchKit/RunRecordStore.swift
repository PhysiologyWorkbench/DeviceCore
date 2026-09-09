import Foundation

/// The run-record store: one directory per run under the root (the records
/// directory of the bench-data repo), `<uuid>/record.json` with the raw
/// captures beside it. Git is the database, so records are written
/// pretty-printed with sorted keys — a diff reads, and a rewrite of the same
/// record is byte-stable.
public struct RunRecordStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The run's directory, where captures belong too.
    public func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString)
    }

    /// Creates the run directory and writes `record.json`; returns the
    /// record's URL.
    @discardableResult
    public func write(_ record: RunRecord) throws -> URL {
        let dir = directory(for: record.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("record.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: url, options: .atomic)
        return url
    }

    public func read(id: UUID) throws -> RunRecord {
        let url = directory(for: id).appendingPathComponent("record.json")
        guard let data = try? Data(contentsOf: url) else {
            throw RunRecordError.notFound(id)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let peek = try? decoder.decode(SchemaVersionOnly.self, from: data) else {
            throw RunRecordError.unknownSchemaVersion(-1)
        }
        guard peek.schemaVersion == RunRecord.currentSchemaVersion else {
            throw RunRecordError.unknownSchemaVersion(peek.schemaVersion)
        }
        return try decoder.decode(RunRecord.self, from: data)
    }

    /// Every run UUID present in the store.
    public func list() throws -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    private struct SchemaVersionOnly: Decodable {
        let schemaVersion: Int
    }
}

public enum RunRecordError: Error, Equatable {
    case notFound(UUID)
    /// A version this reader does not know — including a file with no
    /// readable version field at all, reported as `-1`.
    case unknownSchemaVersion(Int)
}
