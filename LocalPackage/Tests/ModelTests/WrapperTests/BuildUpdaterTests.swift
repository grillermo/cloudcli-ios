import CryptoKit
import Foundation
import os
import Testing

@testable import DataSource
@testable import Model

/// Stands in for Task.sleep: every watchdog timer waits here until the test fires it, so no test
/// depends on wall-clock time. Timers are numbered from 1 in the order they start sleeping.
final class TimerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<Int> = []
    private var count = 0

    var registered: Int { lock.withLock { count } }

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in count += 1; return count }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if cancelled.contains(id) { return true }
                    waiters[id] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                cancelled.insert(id)
                return waiters.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Lets timer `id` run out. Does nothing if it was cancelled.
    func fire(_ id: Int) {
        lock.withLock { waiters.removeValue(forKey: id) }?.resume()
    }

    /// Waits, boundedly, until `n` timers have started sleeping.
    func waitForTimers(_ n: Int) async {
        for _ in 0..<2000 where registered < n {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BuildUpdaterTests {
    private nonisolated let body = Data("a".utf8)

    private nonisolated func manifest(_ id: String) -> BuildManifest {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return BuildManifest(buildId: id, files: [.init(path: "index.html", sha256: hash, size: 1)])
    }

    private nonisolated func makeStore() -> BuildStore {
        let body = body
        return BuildStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            fetch: { _ in body }
        )
    }

    private func makeUpdater(
        latest: OSAllocatedUnfairLock<BuildManifest?>,
        watchdog: Duration = .seconds(60),
        store: BuildStore? = nil,
        gate: TimerGate? = nil
    ) -> BuildUpdater {
        BuildUpdater(
            store: store ?? makeStore(),
            location: BuildLocation(),
            fetchManifest: {
                guard let value = latest.withLock(\.self) else { throw URLError(.notConnectedToInternet) }
                return value
            },
            watchdog: watchdog,
            sleep: gate.map { gate in { @Sendable duration in try await gate.sleep(duration) } }
                ?? { @Sendable duration in try await Task.sleep(for: duration) }
        )
    }

    /// Gives pending main-actor and store work every chance to run, without any wall-clock wait.
    private func drain(_ store: BuildStore) async {
        for _ in 0..<30 {
            await Task.yield()
            _ = await store.pointer()
        }
    }

    /// Launches and reports the loaded build as ready, so later applies have a confirmed build to fall back to.
    private func launchConfirmed(_ updater: BuildUpdater) async {
        await updater.launch()
        updater.pageReady()
        await updater.settle()
    }

    private func waitForRollback(_ updater: BuildUpdater) async throws {
        for _ in 0..<100 where updater.rollbackMessage == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test
    func first_launch_downloads_and_loads_without_asking() async {
        let updater = makeUpdater(latest: .init(initialState: manifest("one")))
        await updater.launch()
        #expect(updater.activeBuildID == "one")
        #expect(updater.pendingBuildID == nil)
        #expect(updater.loadNonce == 1)
    }

    @Test
    func a_cancelled_check_is_not_a_failed_first_download() async {
        let updater = BuildUpdater(
            store: makeStore(),
            location: BuildLocation(),
            fetchManifest: { throw CancellationError() }
        )
        await updater.launch()
        #expect(!updater.needsFirstDownload)
        #expect(updater.activeBuildID == nil)
        #expect(!updater.isChecking)
    }

    @Test
    func first_launch_offline_reports_it() async {
        let updater = makeUpdater(latest: .init(initialState: nil))
        await updater.launch()
        #expect(updater.needsFirstDownload)
        #expect(updater.activeBuildID == nil)
    }

    @Test
    func a_new_build_waits_for_the_tap() async {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        #expect(updater.activeBuildID == "one")
        #expect(updater.pendingBuildID == "two")
        #expect(updater.loadNonce == 1)

        await updater.applyPending()
        #expect(updater.activeBuildID == "two")
        #expect(updater.pendingBuildID == nil)
        #expect(updater.loadNonce == 2)
    }

    @Test
    func a_build_that_never_signals_ready_rolls_back() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let gate = TimerGate()
        let updater = makeUpdater(latest: latest, gate: gate)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        await gate.waitForTimers(1)
        gate.fire(1)
        // Poll instead of sleeping a fixed time: the rollback hops through an actor and can be slow under load.
        try await waitForRollback(updater)
        #expect(updater.activeBuildID == "one")
        #expect(updater.rollbackMessage != nil)
        #expect(updater.loadNonce == 3)

        await updater.check()
        #expect(updater.pendingBuildID == nil)
    }

    @Test
    func a_ready_signal_keeps_the_new_build() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let store = makeStore()
        let gate = TimerGate()
        let updater = makeUpdater(latest: latest, store: store, gate: gate)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        await gate.waitForTimers(1)
        updater.pageReady()
        gate.fire(1)
        await drain(store)
        #expect(updater.activeBuildID == "two")
        #expect(updater.rollbackMessage == nil)
    }

    @Test
    func a_failed_check_changes_nothing() async {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest)
        await launchConfirmed(updater)
        latest.withLock { $0 = nil }
        await updater.check()
        #expect(updater.activeBuildID == "one")
        #expect(updater.pendingBuildID == nil)
    }

    @Test
    func applying_twice_only_loads_once() async {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        async let first: Void = updater.applyPending()
        async let second: Void = updater.applyPending()
        _ = await (first, second)
        #expect(updater.activeBuildID == "two")
        #expect(updater.loadNonce == 2)
    }

    @Test
    func a_stale_timer_cannot_roll_back_a_newer_build() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let store = makeStore()
        let gate = TimerGate()
        let updater = makeUpdater(latest: latest, store: store, gate: gate)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        await gate.waitForTimers(1)
        latest.withLock { $0 = manifest("three") }
        await updater.check()
        await updater.applyPending()
        await gate.waitForTimers(2)
        // Build two's timer runs out after build three is already active.
        gate.fire(1)
        await drain(store)
        #expect(updater.activeBuildID == "three")
        #expect(updater.rollbackMessage == nil)

        // Build three's own timer still works.
        gate.fire(2)
        try await waitForRollback(updater)
        #expect(updater.activeBuildID == "one")
    }

    @Test
    func a_ready_build_is_never_rolled_back_later() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let store = makeStore()
        let gate = TimerGate()
        let updater = makeUpdater(latest: latest, store: store, gate: gate)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        await gate.waitForTimers(1)
        updater.pageReady()
        gate.fire(1)
        await drain(store)
        #expect(updater.activeBuildID == "two")
        #expect(updater.rollbackMessage == nil)
        #expect(updater.loadNonce == 2)
    }

    @Test
    func a_check_that_finishes_after_the_apply_does_not_offer_the_applied_build_again() async {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        async let apply: Void = updater.applyPending()
        async let again: Void = updater.check()
        _ = await (apply, again)
        #expect(updater.activeBuildID == "two")
        #expect(updater.pendingBuildID == nil)
    }

    @Test
    func rollback_skips_a_build_that_never_signalled_ready() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let gate = TimerGate()
        let updater = makeUpdater(latest: latest, gate: gate)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        await gate.waitForTimers(1)
        latest.withLock { $0 = manifest("three") }
        await updater.check()
        await updater.applyPending()
        await gate.waitForTimers(2)
        gate.fire(2)
        try await waitForRollback(updater)
        #expect(updater.activeBuildID == "one")
    }

    @Test
    func a_relaunch_into_an_unconfirmed_build_rolls_back() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let store = makeStore()
        let first = makeUpdater(latest: latest, store: store)
        await launchConfirmed(first)
        latest.withLock { $0 = manifest("two") }
        await first.check()
        await first.applyPending()
        // The app is killed here, before build two signalled ready.
        let gate = TimerGate()
        let second = makeUpdater(latest: latest, store: store, gate: gate)
        await second.launch()
        #expect(second.activeBuildID == "two")
        await gate.waitForTimers(1)
        gate.fire(1)
        try await waitForRollback(second)
        #expect(second.activeBuildID == "one")
        #expect(second.pendingBuildID == nil)
    }

    @Test
    func a_relaunch_into_the_very_first_build_does_not_roll_back_to_nothing() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let store = makeStore()
        let first = makeUpdater(latest: latest, store: store)
        await first.launch()
        let gate = TimerGate()
        let second = makeUpdater(latest: latest, store: store, gate: gate)
        await second.launch()
        await drain(store)
        // No watchdog was armed, because there is no confirmed build to return to.
        #expect(gate.registered == 0)
        #expect(second.activeBuildID == "one")
        #expect(second.rollbackMessage == nil)
        second.pageReady()
        await second.settle()
        #expect(await store.pointer().confirmed == "one")
    }

    @Test
    func a_ready_signal_from_an_older_page_does_not_confirm_the_new_build() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let gate = TimerGate()
        let updater = makeUpdater(latest: latest, gate: gate)
        await launchConfirmed(updater)
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        await gate.waitForTimers(1)
        updater.pageReady(buildID: "one")
        gate.fire(1)
        try await waitForRollback(updater)
        #expect(updater.activeBuildID == "one")
    }

    @Test
    func an_apply_cannot_interleave_with_a_rollback() async throws {
        for _ in 0..<15 {
            let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
            let store = makeStore()
            let gate = TimerGate()
            let updater = makeUpdater(latest: latest, store: store, gate: gate)
            await launchConfirmed(updater)
            latest.withLock { $0 = manifest("two") }
            await updater.check()
            await updater.applyPending()
            await gate.waitForTimers(1)
            latest.withLock { $0 = manifest("three") }
            await updater.check()
            // The timer runs out in the same instant the user taps apply.
            gate.fire(1)
            await updater.applyPending()
            await drain(store)
            // The store and the updater must agree on what is loaded.
            #expect(await store.pointer().current == updater.activeBuildID)
        }
    }
}
