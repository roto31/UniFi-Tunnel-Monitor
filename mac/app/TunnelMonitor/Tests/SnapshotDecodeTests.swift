import XCTest
@testable import TunnelMonitor

final class SnapshotDecodeTests: XCTestCase {
    func testDecodes131FixtureWithoutNewKeys() throws {
        let snapshot = try decodeFixture("state-1.3.1.json")
        XCTAssertEqual(snapshot.diagnosis, "HEALTHY")
        XCTAssertNil(snapshot.spoke_policy)
        XCTAssertNil(snapshot.remote_wan_observed)
        XCTAssertEqual(snapshot.advisories, [])
        let presentation = StatusPresentation.from(snapshot: snapshot)
        XCTAssertEqual(presentation.trafficLight, .green)
    }

    func testDecodes140FixtureWithAdvisories() throws {
        let snapshot = try decodeFixture("state-1.4.0.json")
        XCTAssertEqual(snapshot.spoke_policy?.enabled, true)
        XCTAssertEqual(snapshot.spoke_policy?.state, "0:UP")
        XCTAssertEqual(snapshot.spoke_policy?.label, "Spoke policy route")
        XCTAssertEqual(snapshot.remote_wan_observed, "198.51.100.23")
        XCTAssertEqual(snapshot.advisories, [])
        XCTAssertEqual(StatusPresentation.from(snapshot: snapshot).trafficLight, .green)
    }

    func testHealthyWithAdvisoryIsYellow() throws {
        let raw = try fixtureData("state-1.4.0.json")
        var object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        object["advisories"] = ["SPOKE_POLICY_DOWN"]
        if var policy = object["spoke_policy"] as? [String: Any] {
            policy["state"] = "3:DOWN"
            object["spoke_policy"] = policy
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        let presentation = StatusPresentation.from(snapshot: snapshot)
        XCTAssertEqual(snapshot.diagnosis, "HEALTHY")
        XCTAssertEqual(presentation.trafficLight, .yellow)
        XCTAssertTrue(presentation.issues.contains { $0.id == "advisory_SPOKE_POLICY_DOWN" })
    }

    private func decodeFixture(_ name: String) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: try fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }
}
