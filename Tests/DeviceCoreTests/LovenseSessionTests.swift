import Testing
import Foundation
@testable import DeviceCore

@Suite struct LovenseSessionTests {
    let catalog = try! DeviceCatalog()

    private func identifiedSession() async throws -> (LovenseSession, FakeConnection) {
        let connection = FakeConnection()
        let session = LovenseSession(connection: connection, catalog: catalog)
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
        let session = LovenseSession(connection: FakeConnection(), catalog: catalog)
        await #expect(throws: SessionError.notIdentified) {
            try await session.setVibration(0, 0.5)
        }
    }

    // MARK: Sensor input

    @Test func depthEnablesTheStreamAndYieldsFrames() async throws {
        let (session, connection) = try await identifiedSession()
        let stream = try await session.depth()
        // Unconditionally on every connection: `TouchMode` resets to 0 across a
        // power cycle, so there is never a previous enable to inherit.
        #expect(connection.commands.last == "TouchMode:3;")

        connection.push(Data(hex: "aa70000b02142d14321432143214325f"))
        var iterator = stream.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.positions == [45, 50, 50, 50, 50])
        #expect(frame?.velocity == 20)
    }

    /// A sensor frame must not answer a query running underneath it.
    @Test func aSensorFrameDoesNotSatisfyAQuery() async throws {
        let (session, connection) = try await identifiedSession()
        _ = try await session.depth()
        connection.push(Data(hex: "aa70000b02142d14321432143214325f"))
        #expect(try await session.battery() == 78)
    }

    @Test func endingTheDepthStreamDisablesIt() async throws {
        let (session, connection) = try await identifiedSession()
        do { _ = try await session.depth() }
        // The stream is deallocated here; termination is asynchronous.
        try await Task.sleep(for: .milliseconds(50))
        #expect(connection.commands.last == "TouchMode:0;")
    }

    /// In `TouchMode:5` the firmware drives the motor itself and ignores every stop
    /// this library can send, so a session that means to claim it can stop the toy
    /// has to read the mode back and clear it.
    @Test func ensureStoppableClearsFirmwareDrive() async throws {
        let (session, connection) = try await identifiedSession()
        connection.setReportedTouchMode(5)
        #expect(try await session.ensureStoppable() == true)
        #expect(connection.commands.suffix(2) == ["TouchMode;", "TouchMode:0;"])
    }

    @Test func ensureStoppableLeavesASafeModeAlone() async throws {
        let (session, connection) = try await identifiedSession()
        for mode in [0, 3] {
            connection.setReportedTouchMode(mode)
            #expect(try await session.ensureStoppable() == false)
            #expect(connection.commands.last == "TouchMode;")
        }
    }

    /// Most toys have no `TouchMode` at all: Edge 2 and Solace Pro answer with
    /// silence, Gemini and Ferri with `unkown`. Both mean there is nothing to clear.
    @Test func ensureStoppableToleratesToysWithoutTouchMode() async throws {
        let connection = FakeConnection()
        let session = LovenseSession(connection: connection, catalog: catalog)
        try await session.identify()
        connection.setReportedTouchMode(nil)
        #expect(try await session.ensureStoppable(timeout: .milliseconds(50)) == false)
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
