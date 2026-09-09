import Testing
import Foundation
@testable import BenchKit

@Suite struct RunRecordStoreTests {
    let store: RunRecordStore

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BenchKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RunRecordStore(root: root)
    }

    func sample(id: UUID = UUID()) -> RunRecord {
        RunRecord(
            id: id, tool: "wire.survey", commit: "0123abc-dirty",
            started: Date(timeIntervalSince1970: 1_762_000_000),
            ended: Date(timeIntervalSince1970: 1_762_000_060),
            unit: "Pine64 PineTime", arguments: ["target": "F0:12:34"],
            outcome: .pass, captures: ["advertisements.jsonl"],
            results: .object([
                "services": .array([.string("180D"), .string("180F")]),
                "rssi": .number(-63),
                "connectable": .bool(true),
                "name": .null,
            ]))
    }

    @Test func roundTripsThroughTheStore() throws {
        let record = sample()
        try store.write(record)
        #expect(try store.read(id: record.id) == record)
    }

    @Test func writesAreByteStableAndSorted() throws {
        // Git is the database: rewriting the same record must not churn the diff.
        let record = sample()
        let url = try store.write(record)
        let first = try Data(contentsOf: url)
        try store.write(record)
        #expect(try Data(contentsOf: url) == first)
        let text = String(decoding: first, as: UTF8.self)
        let keys = ["arguments", "captures", "commit", "ended", "id"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions == positions.sorted() && positions.count == keys.count)
    }

    @Test func capturesSitBesideTheRecord() throws {
        let record = sample()
        let dir = store.directory(for: record.id)
        try store.write(record)
        let capture = dir.appendingPathComponent(record.captures[0])
        try Data("{}\n".utf8).write(to: capture)
        #expect(FileManager.default.fileExists(atPath: capture.path))
    }

    @Test func listsEveryRun() throws {
        let a = sample(), b = sample()
        try store.write(a)
        try store.write(b)
        #expect(Set(try store.list()) == [a.id, b.id])
    }

    @Test func refusesAnUnknownSchemaVersion() throws {
        var record = sample()
        record.schemaVersion = RunRecord.currentSchemaVersion + 1
        try store.write(record)
        #expect(throws: RunRecordError.unknownSchemaVersion(record.schemaVersion)) {
            try store.read(id: record.id)
        }
    }

    @Test func refusesAVersionlessFile() throws {
        let id = UUID()
        let dir = store.directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"tool\": \"wire.survey\"}".utf8)
            .write(to: dir.appendingPathComponent("record.json"))
        #expect(throws: RunRecordError.unknownSchemaVersion(-1)) {
            try store.read(id: id)
        }
    }

    @Test func reportsAMissingRun() {
        let id = UUID()
        #expect(throws: RunRecordError.notFound(id)) {
            try store.read(id: id)
        }
    }

    @Test func jsonValueRoundTripsEveryCase() throws {
        let value = JSONValue.object([
            "null": .null, "bool": .bool(false), "number": .number(1.5),
            "string": .string("s"), "nested": .array([.object(["k": .number(2)])]),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
    }
}
