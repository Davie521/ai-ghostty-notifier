import AppKit
import Foundation
import NotifyCore

/// `ghostty-notify-agent --where <tab-id>`: everything a jump would learn
/// about a tab before deciding whether to travel, printed and changing
/// nothing. For the live check of issue #63, and for a report that says a
/// click still brought the window over: the answer shows which window the
/// jump took the tab to be in, and whether it could see where that was.
@MainActor
enum Whereabouts {
    static func run(tabID: String) async -> Int32 {
        print("accessibility=\(WindowServer.isTrusted ? "granted" : "missing")")
        let topology = WindowServer.topology()
        for display in topology?.displays ?? [] {
            let bounds = WindowServer.displayBounds(display.identifier).map {
                "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))"
            }
            print(
                "display \(display.identifier) current=\(display.current.map(String.init) ?? "?")"
                    + " spaces=\(list(display.spaces)) bounds=\(bounds ?? "?")")
        }
        // Asking a Ghostty that is not running would start it.
        guard Ghostty.processID != nil else {
            print("Ghostty is not running")
            return 1
        }
        let (probe, windows) = await Ghostty.locate(tabID: tabID)
        for window in windows { print("window \(window.id) title=\(window.title)") }
        var ordered: [OrderedWindow] = []
        var seen: [SeenWindow] = []
        if let pid = Ghostty.processID {
            ordered = WindowServer.orderedWindows(ownedBy: pid)
            seen = WindowServer.seenWindows(ownedBy: pid) ?? []
        }
        for window in ordered {
            let bounds = WindowServer.bounds(of: window.number).map {
                "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))"
            }
            print(
                "ordered \(window.number) spaces=\(list(window.spaces)) bounds=\(bounds ?? "?")")
        }
        for window in seen {
            print(
                "seen \(window.number)\(window.minimized ? " minimized" : "") title=\(window.title)"
            )
        }
        switch probe {
        case .notFound:
            print("tab \(tabID) not found")
            return 1
        case .unknown:
            print("tab \(tabID): Ghostty did not answer")
            return 1
        case .found(let window):
            guard let topology else {
                print("tab \(tabID) window=\(window) place=unknown (no Space topology)")
                return 1
            }
            let place = WindowPlace.of(
                window, scripted: windows, ordered: ordered,
                seen: WindowServer.isTrusted ? seen : nil,
                visibleSpaces: topology.visibleSpaces)
            let described: String
            switch place {
            case .showing: described = "showing"
            case .unknown: described = "unknown"
            case .unsettled: described = "unsettled"
            case .hidden(let candidates):
                described = "hidden candidates=\(list(candidates.map(\.number)))"
            }
            print("tab \(tabID) window=\(window) place=\(described)")
            return 0
        }
    }

    private static func list<T: BinaryInteger>(_ values: [T]) -> String {
        values.map { "\($0)" }.joined(separator: ",")
    }
}
