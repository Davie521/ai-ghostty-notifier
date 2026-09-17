import Foundation
import NotifyCore

/// Native modes publish through the same atomic spool writer. The old v1 wire
/// format remains available to installers and older clients through --send.
enum SpoolWriter {
    static func write(json: String, to directory: String) -> Bool {
        do {
            try AtomicSpool.write(Data(json.utf8), to: directory)
            return true
        } catch { return false }
    }
}
/// Watches complete files published by atomic rename. A vnode source makes
/// delivery event-driven; the periodic sweep only recovers a replaced inode.
@MainActor
final class SpoolWatcher {
    private let directory: String
    private let onRequest: (AgentRequest) -> Void
    private let log: (String) -> Void
    private let now: () -> Double
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var sweep: DispatchSourceTimer?

    init(
        directory: String,
        log: @escaping (String) -> Void,
        now: @escaping () -> Double = { Date().timeIntervalSince1970 },
        onRequest: @escaping (AgentRequest) -> Void
    ) {
        self.directory = directory
        self.log = log
        self.now = now
        self.onRequest = onRequest
    }

    func start() {
        do { try AtomicSpool.prepareDirectory(directory) } catch {
            log("cannot prepare private spool: \(error)")
        }
        attach()
        // Requests written while the agent was down are still valid work.
        drain()

        // Backstop. A vnode source is tied to an inode, so if the directory is
        // deleted and recreated (a stale sandbox, a user cleaning up) the watch
        // goes deaf forever. This re-attaches and catches anything missed. It
        // is a readdir on an almost-always-empty directory, not a poll of
        // Ghostty, so the cost the native rewrite was after is preserved.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.descriptor < 0 || !FileManager.default.fileExists(atPath: self.directory) {
                    try? FileManager.default.createDirectory(
                        atPath: self.directory, withIntermediateDirectories: true)
                    self.attach()
                }
                self.drain()
            }
        }
        timer.resume()
        sweep = timer
    }

    private func attach() {
        detach()
        let fd = open(directory, O_EVTONLY)
        guard fd >= 0 else {
            log("cannot watch spool \(directory): errno \(errno)")
            return
        }
        descriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let data = source.data
                if data.contains(.delete) || data.contains(.rename) {
                    // Our inode is gone; the next sweep re-attaches. Drain first
                    // in case the same event also carried a write.
                    self.drain()
                    self.detach()
                    return
                }
                self.drain()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func detach() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    func stop() {
        sweep?.cancel()
        sweep = nil
        detach()
    }

    /// Consume every request file. Each file is unlinked *before* it is decoded
    /// so a malformed one is dropped instead of being retried on every wakeup.
    private func drain() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }

        // Order by modification time, not by name. The filename's timestamp
        // prefix is only second-granular on the bash side (BSD `date` has no
        // %N), so two requests written in the same second would otherwise sort
        // arbitrarily — and `drain` depends on a dismiss never overtaking the
        // notify it cancels. APFS keeps nanosecond mtimes, so this is the real
        // arrival order; the name breaks ties.
        let candidates =
            names
            .filter { $0.hasSuffix(".json") }
            .map { name -> (name: String, path: String, modified: Double) in
                let path = directory + "/" + name
                let attributes = try? fm.attributesOfItem(atPath: path)
                let date = attributes?[.modificationDate] as? Date
                return (name, path, date?.timeIntervalSince1970 ?? 0)
            }
            .sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }

        let cutoff = now() - AgentConstants.staleNotifyAge
        for candidate in candidates {
            let data = try? Data(contentsOf: URL(fileURLWithPath: candidate.path))
            try? fm.removeItem(atPath: candidate.path)
            guard let data else { continue }

            let request: AgentRequest
            do {
                request = try RequestCodec.decode(data)
            } catch {
                log("dropped \(candidate.name): \(error)")
                continue
            }

            // Replaying an old notify posts a banner for a round that finished
            // hours ago; replaying an old dismiss or anchor is harmless and
            // still useful, so only notify has an expiry.
            if case .notify = request, candidate.modified < cutoff {
                log("dropped stale notify \(candidate.name) (queued for too long)")
                continue
            }
            if case .hookEvent(let event) = request, event.kind != .prompt,
                event.occurredAt < cutoff
            {
                log("dropped stale hook event \(candidate.name)")
                continue
            }
            onRequest(request)
        }
    }
}
