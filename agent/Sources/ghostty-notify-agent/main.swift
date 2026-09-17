import AppKit
import CoreFoundation
import Foundation
import NotifyCore

// The app, hook and fallback worker share one native binary and code path:
//
//   ghostty-notify-agent               run as the resident LSUIElement app
//   ghostty-notify-agent --send JSON   queue one request and exit
//
//   ghostty-notify-agent --hook claude|codex [event]  stdin JSON, then exit
//   ghostty-notify-agent --worker                    captured context on stdin
//   ghostty-notify-agent --resident-pid              read-only installer preflight

let environment = ProcessInfo.processInfo.environment
let arguments = CommandLine.arguments
let isNativeHookMode =
    arguments.count >= 2 && ["--hook", "--worker", "--clear", "--focus"].contains(arguments[1])

guard let paths = try? AgentPaths(env: environment) else {
    if isNativeHookMode { _ = NativeHookRuntime.readInput() }
    FileHandle.standardError.write(Data("ghostty-notify-agent: HOME is unset\n".utf8))
    exit(isNativeHookMode ? 0 : 2)
}

if isNativeHookMode {
    let mode = arguments[1]
    let input = NativeHookRuntime.readInput()
    if mode == "--worker" { _ = setsid() }
    let work = Task { @MainActor in
        switch mode {
        case "--hook":
            await NativeHookRuntime.hook(
                arguments: Array(arguments.dropFirst(2)),
                input: input, environment: environment, paths: paths)
        case "--worker": await NativeHookRuntime.worker(input: input, paths: paths)
        default:
            await NativeHookRuntime.utility(
                mode: mode, sessionID: arguments.dropFirst(2).first ?? "",
                environment: environment, paths: paths)
        }
        exit(0)  // A notification failure must never block the CLI's work.
    }
    if mode == "--hook" || mode == "--worker" {
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { work.cancel() }
        termination.resume()
        // Keep the main thread's event loop alive for native Apple Events and
        // focus work as well as dispatching cancellation to the MainActor.
        withExtendedLifetime(termination) { CFRunLoopRun() }
        exit(0)
    }
    CFRunLoopRun()
    exit(0)
}
if arguments.dropFirst().first == "--hook-runtime-version" {
    print("native-hook-v1")
    exit(0)
}
if arguments.count == 2, arguments[1] == "--resident-pid" {
    if let pid = HookTransport(paths: paths).runningPID { print(pid) }
    exit(0)
}
if arguments.count >= 2, arguments[1] == "--send" {
    guard arguments.count >= 3 else {
        FileHandle.standardError.write(Data("usage: ghostty-notify-agent --send '<json>'\n".utf8))
        exit(2)
    }
    exit(SpoolWriter.write(json: arguments[2], to: paths.spool) ? 0 : 1)
}
if arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
    NativeHookRuntime.diagnostic("unknown option")
    exit(2)
}

// One agent per machine. See Singleton for why two are easy to get and what
// they break. Checked here, before NSApplication exists, so nothing from
// UserNotifications is touched on a launch that is about to bail out.
if let incumbent = Singleton.incumbent(paths: paths) {
    AgentLog.append("another agent is already running as \(incumbent); exiting", to: paths.log)
    exit(0)
}

// Agent installs a SIGTERM source after launch. Its graceful shutdown waits for
// outstanding hook cleanup before removing the liveness markers and exiting.
let application = NSApplication.shared
let agent = Agent(paths: paths)
application.delegate = agent
application.setActivationPolicy(.accessory)
application.run()
