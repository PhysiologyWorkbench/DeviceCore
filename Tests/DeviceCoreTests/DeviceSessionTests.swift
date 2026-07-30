import Testing
import Foundation
@testable import DeviceCore

@Suite struct DeviceSessionTests {
    let catalog = try! DeviceCatalog()

    private func identifiedSession() async throws -> (DeviceSession, FakeConnection) {
        let connection = FakeConnection()
        let session = DeviceSession(connection: connection, catalog: catalog)
        try await session.identify()
        return (session, connection)
    }

    @Test func identifiesFromTheDeviceTypeReply() async throws {
        let (session, connection) = try await identifiedSession()
        #expect(connection.commands == ["DeviceType;"])
        #expect(await session.model?.name == "Lovense Edge")
    }

    @Test func readsBattery() async throws {
        let (session, connection) = try await identifiedSession()
        #expect(try await session.battery() == 78)
        #expect(connection.commands.last == "Battery;")
    }

    @Test func scalesOntoTheCataloguedRangeAndNumbersTheActuator() async throws {
        let (session, connection) = try await identifiedSession()
        // The Edge has two vibrators, so commands carry an actuator index.
        try await session.setVibration(0, 0)
        try await session.setVibration(1, 1)
        try await session.setVibration(0, 0.5)
        #expect(connection.commands.suffix(3) == ["Vibrate1:0;", "Vibrate2:20;", "Vibrate1:10;"])
    }

    @Test func rejectsAnAbsentFeature() async throws {
        let (session, _) = try await identifiedSession()
        await #expect(throws: SessionError.featureUnavailable("vibrate[2]")) {
            try await session.setVibration(2, 0.5)
        }
        await #expect(throws: SessionError.featureUnavailable("rotate")) {
            try await session.setRotation(0.5)
        }
    }

    @Test func refusesControlBeforeIdentify() async throws {
        let session = DeviceSession(connection: FakeConnection(), catalog: catalog)
        await #expect(throws: SessionError.notIdentified) {
            try await session.setVibration(0, 0.5)
        }
    }

    @Test func reportsWhetherTheWriteReachedTheLink() async throws {
        let (session, connection) = try await identifiedSession()
        connection.setBusy(true)
        #expect(try await session.setVibration(0, 0.5, ifBusy: .drop) == false)
        #expect(try await session.setVibration(0, 0.5, ifBusy: .wait) == true)
        // Only the `.wait` write got through, so only it was recorded.
        #expect(connection.commands.suffix(1) == ["Vibrate1:10;"])
    }
}
