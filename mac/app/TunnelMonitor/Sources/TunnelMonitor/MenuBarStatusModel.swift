import Combine
import SwiftUI

/// Publishes menu-bar dot color only when traffic light changes (avoids SwiftUI main-menu invalidation loops).
@MainActor
final class MenuBarStatusModel: ObservableObject {
    @Published private(set) var light: TrafficLight = .yellow
    private var cancellable: AnyCancellable?

    func bind(to monitor: MonitorState) {
        guard cancellable == nil else { return }
        light = monitor.trafficLight
        cancellable = monitor.$presentation
            .map(\.trafficLight)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newLight in
                self?.light = newLight
            }
    }
}

struct MenuBarLabelView: View {
    @ObservedObject var status: MenuBarStatusModel

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(status.light.color, Color.clear)
                    .padding(5)
                    .glassEffect(.regular.tint(status.light.color.opacity(0.5)), in: .circle)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(status.light.color, Color.clear)
            }
        }
        .accessibilityLabel("Tunnel Monitor — \(status.light.title)")
    }
}
