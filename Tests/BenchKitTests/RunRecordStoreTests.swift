import Testing
import Foundation
import DeviceCore
@testable import BenchKit

@Suite struct RunRecordStoreTests {
    let store: RunRecordStore

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BenchKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RunRecordStore(root: root)
    }

    func sample(runUUID: UUID = UUID()) -> RunRecord {
        RunRecord(
            runUUID: runUUID, toolName: "wire.survey",
            commits: ["PWB": "0123abc-dirty", "DeviceCore": "77aa88b"],
            started: Date(timeIntervalSince1970: 1_762_000_000),
            ended: Date(timeIntervalSince1970: 1_762_000_060),
            units: [
                PhysicalUnit(role: .dut, label: "Pine64 PineTime",
                     claims: ["ble.name": "InfiniTime", "dis.model": "InfiniTime"],
                     bindings: ["cb.peripheral": "AAAAAAAA-0000-0000-0000-000000000001"]),
                PhysicalUnit(role: .host, claims: ["apple.model": "Mac15,6"]),
            ],
            arguments: ["target": "F0:12:34"],
            outcome: .pass, captureFiles: ["advertisements.jsonl"])
    }

    @Test func roundTripsThroughTheStore() throws {
        let record = sample()
        try store.write(record)
        #expect(try store.read(id: record.runUUID) == record)
    }

    @Test func writesAreByteStableAndSorted() throws {
        // Git is the database: rewriting the same record must not churn the diff.
        let record = sample()
        let url = try store.write(record)
        let first = try Data(contentsOf: url)
        try store.write(record)
        #expect(try Data(contentsOf: url) == first)
        let text = String(decoding: first, as: UTF8.self)
        let keys = ["arguments", "captureFiles", "commits", "ended", "outcome",
                    "runUUID", "schemaVersion", "started", "toolName", "units"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions == positions.sorted() && positions.count == keys.count)
        let unitKeys = ["bindings", "claims", "label", "role"]
        let unitPositions = unitKeys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(unitPositions == unitPositions.sorted() && unitPositions.count == unitKeys.count)
    }

    @Test func resultsLiveBesideTheRecordAndRoundTrip() throws {
        let record = sample()
        try store.write(record)
        #expect(try store.readResults(id: record.runUUID) == nil)
        let results = JSONValue.object([
            "services": .array([.string("180D"), .string("180F")]),
            "rssi": .number(-63),
            "connectable": .bool(true),
            "name": .null,
        ])
        let url = try store.writeResults(results, for: record.runUUID)
        #expect(url.lastPathComponent == "results.json")
        #expect(url.deletingLastPathComponent() == store.directory(for: record.runUUID))
        #expect(try store.readResults(id: record.runUUID) == results)
    }

    @Test func capturesSitBesideTheRecord() throws {
        let record = sample()
        let dir = store.directory(for: record.runUUID)
        try store.write(record)
        let capture = dir.appendingPathComponent(record.captureFiles[0])
        try Data("{}\n".utf8).write(to: capture)
        #expect(FileManager.default.fileExists(atPath: capture.path))
    }

    @Test func listsEveryRun() throws {
        let a = sample(), b = sample()
        try store.write(a)
        try store.write(b)
        #expect(Set(try store.list()) == [a.runUUID, b.runUUID])
    }

    @Test func refusesAnUnknownSchemaVersion() throws {
        var record = sample()
        record.schemaVersion = RunRecord.currentSchemaVersion + 1
        try store.write(record)
        #expect(throws: RunRecordError.unknownSchemaVersion(record.schemaVersion)) {
            try store.read(id: record.runUUID)
        }
    }

    @Test func refusesAVersionlessFile() throws {
        let id = UUID()
        let dir = store.directory(for: id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{\"toolName\": \"wire.survey\"}".utf8)
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
