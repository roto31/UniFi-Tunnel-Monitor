import Foundation
import AppKit

enum Actions {
    static let tunnelCheckBin = "/usr/local/bin/tunnel-check"

    /// Run a shell command, capture stdout+stderr, return (exitCode, output).
    @discardableResult
    static func run(_ launchPath: String, args: [String]) -> (Int32, String) {
        let p = Process()
        p.launchPath = launchPath
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
        } catch {
            return (-1, "failed to launch: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    /// Run a command with osascript admin-prompt (asks user for password via macOS).
    @discardableResult
    static func runAsRoot(_ command: String) -> (Int32, String) {
        // Escape double quotes for the AppleScript string literal.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return run("/usr/bin/osascript", args: ["-e", script])
    }

    static func checkNow() -> String {
        let label = AppBranding.launchDaemonLabel
        let (code, out) = runAsRoot("/bin/launchctl kickstart -k system/\(label)")
        return code == 0 ? "Kicked daemon." : "Failed (\(code)): \(out)"
    }

    static func testEmail() -> String {
        let (code, out) = run(tunnelCheckBin, args: ["--test-email"])
        return code == 0 ? "Email sent.\n\(out)" : "Email failed (\(code)).\n\(out)"
    }

    static func testNotify() -> String {
        let (code, out) = run(tunnelCheckBin, args: ["--test-notify"])
        return code == 0 ? "Notification fired.\n\(out)" : "Notify failed (\(code)).\n\(out)"
    }

    static func resetState() -> String {
        let (code, out) = runAsRoot("\(tunnelCheckBin) --reset")
        return code == 0 ? "State reset to UP/0." : "Reset failed (\(code)): \(out)"
    }

    static func sshTest() -> String {
        let (code, out) = run(tunnelCheckBin, args: ["--ssh-test"])
        return code == 0 ? "OK\n\(out)" : "SSH test failed (\(code)):\n\(out)"
    }

    /// Opens Terminal without blocking the main thread (required for MenuBarExtra actions).
    static func openInTerminal(_ command: String) {
        Task { @MainActor in
            activateForUserAction()
        }
        Task.detached(priority: .userInitiated) {
            let escaped = escapeForAppleScript(command)
            let script = """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
            launchDetached(launchPath: "/usr/bin/osascript", args: ["-e", script])
        }
    }

    @MainActor
    private static func activateForUserAction() {
        let shell = TunnelMonitorAppDelegate.sharedShell
        let restoreAccessory = shell?.showDockIcon == false
        if restoreAccessory {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        if restoreAccessory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                shell?.applyActivationPolicy()
            }
        }
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func launchDetached(launchPath: String, args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try? process.run()
    }

    @MainActor
    static func revealLog() {
        NSWorkspace.shared.selectFile(MonitorPaths.logFile, inFileViewerRootedAtPath: MonitorPaths.installDir)
    }

    @MainActor
    static func openStateInFinder() {
        NSWorkspace.shared.selectFile(MonitorPaths.stateFile, inFileViewerRootedAtPath: MonitorPaths.installDir)
    }

    static func editConfig() -> String {
        openInTerminal("sudo -e \(MonitorPaths.config)")
        return "Opening Terminal to edit config.env (admin password required)."
    }

    static func tailLog() -> String {
        openInTerminal("tail -f \(MonitorPaths.logFile)")
        return "Opening log tail in Terminal."
    }

    @MainActor
    static func copySSHPubkeyCommand() -> String {
        // bash -lc uses double quotes so ${...} expands after sourcing config.env.
        let cmd = #"""
        /bin/bash -lc "set -a; . /opt/tunnel-monitor/config.env 2>/dev/null; echo \"${UDR7_USER:-${ROUTER_USER:-root}}@${UDR7_HOST:-${ROUTER_HOST}}\""
        """#
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")

        let (code, out) = runAsRoot(cmd)
        let target = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 || target.isEmpty || target == "@" {
            return "Could not read SSH user@host from config (set UDR7_* or ROUTER_*). Exit \(code): \(out)"
        }
        let clip = "sudo cat /opt/tunnel-monitor/.ssh/id_ed25519.pub | ssh \(target) 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys'"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clip, forType: .string)
        return "Copied to clipboard:\n\(clip)"
    }
}
