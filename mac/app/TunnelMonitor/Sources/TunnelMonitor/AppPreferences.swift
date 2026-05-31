import Foundation
import Combine
import AppKit

enum AppPreferences {
    static let suiteName = "group.com.tunnel.monitor"

    enum Keys {
        static let showMenuBar = "showMenuBar"
        static let showDockIcon = "showDockIcon"
        static let openDashboardAtLaunch = "openDashboardAtLaunch"
        static let refreshIntervalSeconds = "refreshIntervalSeconds"
        static let widgetSyncEnabled = "widgetSyncEnabled"
        static let hasShownIntroWindow = "hasShownIntroWindow"
    }

    static var defaults: UserDefaults {
        UserDefaults.standard
    }

    static var showMenuBar: Bool {
        get { defaults.object(forKey: Keys.showMenuBar) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showMenuBar) }
    }

    static var showDockIcon: Bool {
        get { defaults.object(forKey: Keys.showDockIcon) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.showDockIcon) }
    }

    static var openDashboardAtLaunch: Bool {
        get { defaults.object(forKey: Keys.openDashboardAtLaunch) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Keys.openDashboardAtLaunch) }
    }

    static var refreshIntervalSeconds: TimeInterval {
        get {
            let v = defaults.double(forKey: Keys.refreshIntervalSeconds)
            return v > 0 ? v : 5.0
        }
        set { defaults.set(newValue, forKey: Keys.refreshIntervalSeconds) }
    }

    static var widgetSyncEnabled: Bool {
        get { defaults.object(forKey: Keys.widgetSyncEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.widgetSyncEnabled) }
    }

    /// One-time dashboard on first launch so Finder open is visible; not repeated every run.
    static var hasShownIntroWindow: Bool {
        get { defaults.bool(forKey: Keys.hasShownIntroWindow) }
        set { defaults.set(newValue, forKey: Keys.hasShownIntroWindow) }
    }
}

@MainActor
final class AppShellController: ObservableObject {
    @Published var showMenuBar: Bool {
        didSet {
            guard oldValue != showMenuBar else { return }
            AppPreferences.showMenuBar = showMenuBar
            ensureVisibleSurface()
        }
    }
    @Published var showDockIcon: Bool {
        didSet {
            guard oldValue != showDockIcon else { return }
            AppPreferences.showDockIcon = showDockIcon
            applyActivationPolicy()
            ensureVisibleSurface()
        }
    }
    @Published var openDashboardAtLaunch: Bool {
        didSet { AppPreferences.openDashboardAtLaunch = openDashboardAtLaunch }
    }
    @Published var refreshIntervalSeconds: Double {
        didSet { AppPreferences.refreshIntervalSeconds = refreshIntervalSeconds }
    }
    @Published var widgetSyncEnabled: Bool {
        didSet { AppPreferences.widgetSyncEnabled = widgetSyncEnabled }
    }
    @Published var openDashboardRequest = false
    @Published var openSetupWizardRequest = false

    init() {
        showMenuBar = AppPreferences.showMenuBar
        showDockIcon = AppPreferences.showDockIcon
        openDashboardAtLaunch = AppPreferences.openDashboardAtLaunch
        refreshIntervalSeconds = AppPreferences.refreshIntervalSeconds
        widgetSyncEnabled = AppPreferences.widgetSyncEnabled
        applyActivationPolicy()
    }

    func applyActivationPolicy() {
        if showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func requestOpenDashboard() {
        openDashboardRequest = true
    }

    func requestSetupWizard() {
        openSetupWizardRequest = true
    }

    func clearSetupWizardRequest() {
        openSetupWizardRequest = false
    }

    func updateMenuBarInserted(_ inserted: Bool) {
        guard showMenuBar != inserted else { return }
        showMenuBar = inserted
    }

    private func ensureVisibleSurface() {
        if !showMenuBar && !showDockIcon {
            showDockIcon = true
        }
    }
}
