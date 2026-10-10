import XCTest
@testable import TunnelMonitor

final class SpeedSnapshotTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDecodesValidSpeedFile() throws {
        let speed = try XCTUnwrap(SpeedSnapshot.load(from: fixturePath("speed-1.6.0.json")))
        XCTAssertTrue(speed.ok)
        XCTAssertEqual(speed.method, "iperf3")
        XCTAssertEqual(speed.down_mbps, 42.1)
        XCTAssertNil(speed.error)
        XCTAssertEqual(speed.valuesText, "Down 42.1 Mbps · Up 18.3 Mbps · RTT 48 ms")
        XCTAssertEqual(speed.methodText, "iperf3, router to router")
        XCTAssertNotNil(speed.measuredDate)
    }

    func testMissingRequiredFieldYieldsNilAndMissingOptionalsShowDash() throws {
        let noTimestamp = try write("speed.json", #"{"method":"ssh","ok":true,"down_mbps":5}"#)
        XCTAssertNil(SpeedSnapshot.load(from: noTimestamp))

        let minimal = try write("minimal.json", #"{"measured_at":"2026-10-09T18:00:00Z","method":"ssh","ok":false,"error":"UDM unreachable"}"#)
        let speed = try XCTUnwrap(SpeedSnapshot.load(from: minimal))
        XCTAssertEqual(speed.valuesText, "Down — · Up — · RTT —")
        XCTAssertEqual(speed.methodText, "SSH copy (lower bound)")
        XCTAssertEqual(speed.error, "UDM unreachable")
    }

    func testMalformedOrMissingFileYieldsNil() throws {
        XCTAssertNil(SpeedSnapshot.load(from: try write("bad.json", "{not json")))
        XCTAssertNil(SpeedSnapshot.load(from: tempDir.appendingPathComponent("absent.json").path))
    }

    func testStaleAfterTwelveHours() throws {
        let speed = try XCTUnwrap(SpeedSnapshot.load(from: fixturePath("speed-1.6.0.json")))
        let measured = try XCTUnwrap(speed.measuredDate)
        XCTAssertFalse(speed.isStale(now: measured.addingTimeInterval(60 * 60)))
        XCTAssertTrue(speed.isStale(now: measured.addingTimeInterval(13 * 60 * 60)))

        let badDate = try write("baddate.json", #"{"measured_at":"yesterday","method":"iperf3","ok":true}"#)
        XCTAssertTrue(try XCTUnwrap(SpeedSnapshot.load(from: badDate)).isStale())
    }

    func testSpeedFileNeverAffectsStateLoad() throws {
        let statePath = try write("state.json", String(decoding: try Data(contentsOf: URL(fileURLWithPath: fixturePath("state-1.3.1.json"))), as: UTF8.self))
        let speedPath = tempDir.appendingPathComponent("speed.json").path
        let requestPath = tempDir.appendingPathComponent("speed-request").path

        let baseline = MonitorState.loadPayload(from: statePath, speedPath: speedPath, speedRequestPath: requestPath, syncWidget: true)
        XCTAssertNil(baseline.speed)
        XCTAssertFalse(baseline.speedCheckInstalled)

        for contents in ["{not json", #"{"method":"iperf3"}"#, try String(contentsOfFile: fixturePath("speed-1.6.0.json"))] {
            try contents.write(toFile: speedPath, atomically: true, encoding: .utf8)
            let payload = MonitorState.loadPayload(from: statePath, speedPath: speedPath, speedRequestPath: requestPath, syncWidget: true)
            XCTAssertNil(payload.error)
            XCTAssertEqual(payload.snapshot, baseline.snapshot)
            XCTAssertEqual(payload.presentation, baseline.presentation)
            XCTAssertEqual(payload.widgetSnapshot, baseline.widgetSnapshot)
        }

        let missingState = MonitorState.loadPayload(from: tempDir.appendingPathComponent("none.json").path,
                                                    speedPath: speedPath, speedRequestPath: requestPath, syncWidget: true)
        XCTAssertNotNil(missingState.error)
        XCTAssertNotNil(missingState.speed, "a valid speed file still loads when state.json is missing")
    }

    func testSpeedRequestWritesOnlyAnExistingTriggerFile() throws {
        let requestPath = tempDir.appendingPathComponent("speed-request").path
        XCTAssertFalse(SpeedRequest.write(to: requestPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestPath), "never creates the trigger file")

        FileManager.default.createFile(atPath: requestPath, contents: Data("old old old old old old old\n".utf8))
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertTrue(SpeedRequest.write(to: requestPath, now: now))
        let written = try String(contentsOfFile: requestPath)
        XCTAssertEqual(written, ISO8601DateFormatter().string(from: now) + "\n")
    }

    private func write(_ name: String, _ contents: String) throws -> String {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func fixturePath(_ name: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
            .path
    }
}
