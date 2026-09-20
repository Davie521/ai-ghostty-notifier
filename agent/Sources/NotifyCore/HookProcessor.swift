import Foundation

public protocol HookClockProviding: Sendable {
    func now() -> Double
    func sleep(seconds: Double) async throws
}

public struct SystemHookClock: HookClockProviding {
    public init() {}
    public func now() -> Double { Date().timeIntervalSince1970 }
    public func sleep(seconds: Double) async throws {
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
}

public protocol TerminalBindingProviding: Sendable {
    func existing(_ event: HookEvent) async -> String?
    func resolve(_ event: HookEvent) async -> String?
    func clearExternal(_ event: HookEvent) async
}

/// Shared policy/lifecycle for the resident app and native fallback worker.
/// Every async result is checked against the on-disk generation before use.
@MainActor
public final class HookProcessor {
    private struct Pending {
        var token: UUID
        var round: String
        var task: Task<Void, Never>
    }
    private let journal: any RoundJournalProviding
    private let content: any SessionContentProviding
    private let binding: any TerminalBindingProviding
    private let clock: any HookClockProviding
    private let onPrompt: (HookEvent, String?) -> Void
    private let onNotify: (HookEvent, NotifyRequest) -> Void
    private let log: (String) -> Void
    private var pending: [String: Pending] = [:]
    private var active: [UUID: Task<Void, Never>] = [:]
    private var closing = false

    public init(
        journal: any RoundJournalProviding = DiskRoundJournal(),
        content: any SessionContentProviding = DiskSessionContent(),
        binding: any TerminalBindingProviding,
        clock: any HookClockProviding = SystemHookClock(),
        onPrompt: @escaping (HookEvent, String?) -> Void,
        onNotify: @escaping (HookEvent, NotifyRequest) -> Void,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.journal = journal
        self.content = content
        self.binding = binding
        self.clock = clock
        self.onPrompt = onPrompt
        self.onNotify = onNotify
        self.log = log
    }

    @discardableResult
    public func receive(_ event: HookEvent) -> Task<Void, Never> {
        let token = UUID()
        let task = Task {
            if !closing { await handle(event) }
            active.removeValue(forKey: token)
        }
        active[token] = task
        return task
    }

    public func cancelAll() {
        for task in active.values { task.cancel() }
        for item in pending.values { item.task.cancel() }
        pending.removeAll()
    }

    /// A shutdown must wait for OSC restoration, not just set cancellation and
    /// immediately terminate the process containing the cleanup operation.
    public func shutdown() async {
        closing = true
        let tasks = Array(active.values) + pending.values.map(\.task)
        cancelAll()
        for task in tasks { await task.value }
    }

    private func handle(_ event: HookEvent) async {
        // PreToolUse binding must finish in the native hook process while the
        // TUI is blocked. Never turn it into asynchronous resident work.
        guard event.kind != .preTool, !Task.isCancelled, !closing else { return }
        guard await journal.isCurrent(event) else {
            log("dropped superseded \(event.key)")
            return
        }
        guard !Task.isCancelled, !closing else { return }
        await journal.prepare(event)
        guard await journal.isCurrent(event), !Task.isCancelled, !closing else { return }
        if event.kind == .prompt {
            for key in Array(pending.keys) where key.hasPrefix(event.key + ":") {
                // A prompt can be drained after its own Stop. It invalidates
                // previous rounds, not completion work for this very round.
                if pending[key]?.round != event.roundID {
                    pending.removeValue(forKey: key)?.task.cancel()
                }
            }
            let tab = await binding.existing(event)
            guard await journal.isCurrent(event), !Task.isCancelled, !closing else { return }
            onPrompt(event, tab)
            await binding.clearExternal(event)
            log("handled UserPromptSubmit \(event.key) round=\(event.roundID)")
            return
        }
        let key = event.key + ":" + event.kind.rawValue
        if let item = pending[key], item.round == event.roundID { return }
        pending.removeValue(forKey: key)?.task.cancel()
        let token = UUID()
        let task = Task {
            await perform(event)
            if pending[key]?.token == token { pending.removeValue(forKey: key) }
        }
        pending[key] = Pending(token: token, round: event.roundID, task: task)
        await task.value
    }

    private func valid(_ event: HookEvent) async -> Bool {
        guard !closing, !Task.isCancelled, clock.now() < event.expiresAt else { return false }
        guard await journal.isCurrent(event) else { return false }
        // Actor hops can resume after shutdown or cancellation has begun.
        return !closing && !Task.isCancelled && clock.now() < event.expiresAt
    }

    private func perform(_ event: HookEvent) async {
        guard await valid(event) else {
            await journal.finish(event)
            return
        }
        if event.source == .codex, event.kind == .stop {
            let remaining = min(
                event.options.settle - (clock.now() - event.occurredAt),
                event.expiresAt - clock.now())
            do { try await clock.sleep(seconds: max(0, remaining)) } catch { return }
            guard await valid(event) else { return }
            if await content.isContinuing(event) {
                log("continuing \(event.key); kept round start")
                return
            }
        }
        guard NotificationPolicy.qualifies(event) else {
            await journal.finish(event)
            log("suppressed \(event.key) by policy")
            return
        }
        async let title = content.title(for: event)
        async let tab = binding.resolve(event)
        let resolved = await (title, tab)
        guard await valid(event) else { return }
        if event.source == .codex, event.kind == .stop, await content.isContinuing(event) { return }
        guard await valid(event) else { return }
        // Reserve only when work is ready to publish. A cancelled title lookup
        // must not consume the slot needed by a newer round's real completion.
        guard await journal.claimRate(event, now: clock.now()) else {
            await journal.finish(event)
            log("suppressed duplicate \(event.key)")
            return
        }
        await journal.finish(event)
        guard await valid(event) else { return }
        onNotify(event, NotificationPolicy.content(event, title: resolved.0, tabID: resolved.1))
        log("handled \(event.kind.rawValue) \(event.key) round=\(event.roundID)")
    }
}
