import DataSource
import Foundation
import Observation

@MainActor @Observable public final class BuildUpdater {
    public private(set) var activeBuildID: String?
    public private(set) var pendingBuildID: String?
    public private(set) var needsFirstDownload = false
    public private(set) var isChecking = false
    /// Incremented whenever the web view should load the current build.
    public private(set) var loadNonce = 0
    public var rollbackMessage: String?

    private let store: BuildStore
    private let location: BuildLocation
    private let fetchManifest: @Sendable () async throws -> BuildManifest
    private let watchdog: Duration
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?
    /// The build that was just applied and has not signalled ready yet.
    @ObservationIgnored private var awaitingReadyID: String?
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var rejectedBuildID: String?

    public init(
        store: BuildStore,
        location: BuildLocation,
        fetchManifest: @escaping @Sendable () async throws -> BuildManifest,
        watchdog: Duration = .seconds(15)
    ) {
        self.store = store
        self.location = location
        self.fetchManifest = fetchManifest
        self.watchdog = watchdog
    }

    public func launch() async {
        if let id = await store.pointer().current, let directory = await store.currentDirectory() {
            activeBuildID = id
            location.current = directory
            loadNonce += 1
        }
        await check()
    }

    public func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let manifest = try await fetchManifest()
            guard manifest.buildId != activeBuildID, manifest.buildId != rejectedBuildID else { return }
            try await store.prepare(manifest)
            // State may have changed while the download ran: an apply or a rollback can
            // have made this build active or rejected it.
            guard manifest.buildId != activeBuildID, manifest.buildId != rejectedBuildID else { return }
            if activeBuildID == nil {
                try await switchTo(manifest.buildId)
                needsFirstDownload = false
            } else {
                pendingBuildID = manifest.buildId
            }
        } catch {
            if activeBuildID == nil { needsFirstDownload = true }
        }
    }

    public func applyPending() async {
        guard !isApplying, let id = pendingBuildID else { return }
        isApplying = true
        defer { isApplying = false }
        pendingBuildID = nil
        do {
            try await switchTo(id)
            armWatchdog(for: id)
        } catch {
            rollbackMessage = "The new build could not be applied."
        }
    }

    public func pageReady() {
        awaitingReadyID = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func switchTo(_ id: String) async throws {
        try await store.activate(id)
        activeBuildID = id
        location.current = await store.currentDirectory()
        loadNonce += 1
    }

    private func armWatchdog(for id: String) {
        watchdogTask?.cancel()
        awaitingReadyID = id
        watchdogTask = Task { [weak self, watchdog] in
            try? await Task.sleep(for: watchdog)
            guard !Task.isCancelled else { return }
            await self?.rollBack(from: id)
        }
    }

    private func rollBack(from id: String) async {
        // A ready signal or a newer apply may have landed between the timer and now.
        guard awaitingReadyID == id, activeBuildID == id else { return }
        awaitingReadyID = nil
        watchdogTask = nil
        guard let previous = try? await store.rollback() else { return }
        rejectedBuildID = id
        activeBuildID = previous
        location.current = await store.currentDirectory()
        loadNonce += 1
        rollbackMessage = "Build \(id) did not load, so the previous build was restored."
    }
}
