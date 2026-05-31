import Foundation

enum AppGroupSync {
    static let groupID = AppPreferences.suiteName
    static let fileName = "tunnel-status.json"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static var statusFileURL: URL? {
        containerURL?.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func writeWidgetSnapshot(_ snapshot: WidgetStatusSnapshot) {
        guard AppPreferences.widgetSyncEnabled else { return }
        Task.detached(priority: .utility) {
            writeWidgetSnapshotSync(snapshot)
        }
    }

    private static func writeWidgetSnapshotSync(_ snapshot: WidgetStatusSnapshot) {
        guard let base = containerURL else { return }
        let library = base.appendingPathComponent("Library", isDirectory: true)
        let file = library.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            let tmp = library.appendingPathComponent("\(fileName).tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            try FileManager.default.moveItem(at: tmp, to: file)
        } catch {
            // Widget sync is best-effort; menu bar still works from state.json.
        }
    }

    static func readWidgetSnapshot() -> WidgetStatusSnapshot? {
        guard let file = statusFileURL,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(WidgetStatusSnapshot.self, from: data)
    }
}
