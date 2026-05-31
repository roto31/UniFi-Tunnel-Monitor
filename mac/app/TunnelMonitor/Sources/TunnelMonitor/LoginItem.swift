import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var lastError: String?

    private let service = SMAppService.mainApp

    init() {
        Task { refresh() }
    }

    func refresh() {
        isEnabled = service.status == .enabled
    }

    func toggle() {
        Task {
            do {
                if service.status == .enabled {
                    try await service.unregister()
                } else {
                    try await service.register()
                }
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            refresh()
        }
    }
}
