import CryptoKit
import Foundation
import os
import Testing

@testable import DataSource
@testable import Model

@MainActor
struct BuildUpdaterTests {
    private nonisolated let body = Data("a".utf8)

    private nonisolated func manifest(_ id: String) -> BuildManifest {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return BuildManifest(buildId: id, files: [.init(path: "index.html", sha256: hash, size: 1)])
    }

    private func makeUpdater(
        latest: OSAllocatedUnfairLock<BuildManifest?>,
        watchdog: Duration = .seconds(60)
    ) -> BuildUpdater {
        let body = body
        let store = BuildStore(
            root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            fetch: { _ in body }
        )
        return BuildUpdater(
            store: store,
            location: BuildLocation(),
            fetchManifest: {
                guard let value = latest.withLock(\.self) else { throw URLError(.notConnectedToInternet) }
                return value
            },
            watchdog: watchdog
        )
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
        await updater.launch()
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
        let updater = makeUpdater(latest: latest, watchdog: .milliseconds(20))
        await updater.launch()
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        // Poll instead of sleeping a fixed time: the rollback hops through an actor and can be slow under load.
        for _ in 0..<100 where updater.rollbackMessage == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(updater.activeBuildID == "one")
        #expect(updater.rollbackMessage != nil)
        #expect(updater.loadNonce == 3)

        await updater.check()
        #expect(updater.pendingBuildID == nil)
    }

    @Test
    func a_ready_signal_keeps_the_new_build() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest, watchdog: .milliseconds(20))
        await updater.launch()
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        updater.pageReady()
        try await Task.sleep(for: .milliseconds(200))
        #expect(updater.activeBuildID == "two")
    }

    @Test
    func a_failed_check_changes_nothing() async {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest)
        await updater.launch()
        latest.withLock { $0 = nil }
        await updater.check()
        #expect(updater.activeBuildID == "one")
        #expect(updater.pendingBuildID == nil)
    }

    @Test
    func applying_twice_only_loads_once() async {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest)
        await updater.launch()
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
        let updater = makeUpdater(latest: latest, watchdog: .milliseconds(150))
        await updater.launch()
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        latest.withLock { $0 = manifest("three") }
        await updater.check()
        await updater.applyPending()
        updater.pageReady()
        try await Task.sleep(for: .milliseconds(400))
        #expect(updater.activeBuildID == "three")
        #expect(updater.rollbackMessage == nil)
    }

    @Test
    func a_ready_build_is_never_rolled_back_later() async throws {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest, watchdog: .milliseconds(20))
        await updater.launch()
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        await updater.applyPending()
        updater.pageReady()
        try await Task.sleep(for: .milliseconds(200))
        #expect(updater.activeBuildID == "two")
        #expect(updater.rollbackMessage == nil)
        #expect(updater.loadNonce == 2)
    }

    @Test
    func a_check_that_finishes_after_the_apply_does_not_offer_the_applied_build_again() async {
        let latest = OSAllocatedUnfairLock<BuildManifest?>(initialState: manifest("one"))
        let updater = makeUpdater(latest: latest)
        await updater.launch()
        latest.withLock { $0 = manifest("two") }
        await updater.check()
        async let apply: Void = updater.applyPending()
        async let again: Void = updater.check()
        _ = await (apply, again)
        #expect(updater.activeBuildID == "two")
        #expect(updater.pendingBuildID == nil)
    }
}
