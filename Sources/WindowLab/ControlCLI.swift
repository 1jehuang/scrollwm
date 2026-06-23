import Foundation
import AppKit

// `scrollwm <verb>` CLI: drive the running ScrollWM app from a shell.
//
// This runs in a short-lived process (the same WindowLab binary, dispatched
// here by main.swift for control verbs). It connects to the running app's
// control socket, sends the command, prints the reply, and exits with a code
// that reflects success/failure so scripts can branch on it.
//
// If the app isn't running, most verbs error out with a hint. The verbs that
// imply "start managing" (arrange/toggle) will offer to launch the app first.

private let launchVerbs: Set<String> = ["arrange", "toggle"]

func runControlCLI(_ args: [String]) -> Int32 {
    let verb = args.first ?? ""
    let command = args.joined(separator: " ")

    do {
        let reply = try ControlClient.send(command)
        return printReply(reply)
    } catch ControlClient.Failure.notRunning {
        // Not running. For arrange/toggle, try to launch the app, then retry.
        if launchVerbs.contains(verb), launchRunningApp() {
            if let reply = retryAfterLaunch(command) {
                return printReply(reply)
            }
        }
        FileHandle.standardError.write("""
        ScrollWM isn't running.
          Start it:   open -a ScrollWM        (or run `scrollwm arrange` to launch + arrange)
          Install:    https://github.com/1jehuang/scrollwm

        """.data(using: .utf8)!)
        return 3
    } catch {
        FileHandle.standardError.write("scrollwm: \(error)\n".data(using: .utf8)!)
        return 1
    }
}

/// Print the app's reply on the right stream and map it to an exit code:
/// lines beginning with "error:" go to stderr and exit non-zero.
private func printReply(_ reply: String) -> Int32 {
    if reply.hasPrefix("error:") {
        FileHandle.standardError.write((reply + "\n").data(using: .utf8)!)
        return 2
    }
    print(reply)
    return 0
}

/// Launch the installed/owning ScrollWM app (menu-bar agent). Returns true if
/// a launch was initiated.
private func launchRunningApp() -> Bool {
    // Prefer launching the bundle that contains THIS binary (so a freshly
    // built/installed app drives itself), falling back to bundle-id lookup.
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    // .../ScrollWM.app/Contents/MacOS/ScrollWM.bin -> .../ScrollWM.app
    let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    if bundle.pathExtension == "app" {
        NSWorkspace.shared.open(bundle)
        return true
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.scrollwm.app") {
        NSWorkspace.shared.open(url)
        return true
    }
    // Last resort: let LaunchServices find it by name.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", "ScrollWM"]
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
    catch { return false }
}

/// Poll the socket briefly after a launch (the app needs a moment to bind it).
private func retryAfterLaunch(_ command: String) -> String? {
    let deadline = Date().addingTimeInterval(6.0)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.2)
        if let reply = try? ControlClient.send(command) { return reply }
    }
    return nil
}
