import DataSource
import Foundation
import Observation

@MainActor @Observable public final class DictationController {
    public enum State: Equatable, Sendable {
        case idle
        case recording
        case transcribing
        case readyToSend
    }

    public private(set) var state = State.idle
    /// Recordings that were not transcribed yet, oldest first. They live in permanent storage.
    public private(set) var failed: [URL] = []
    public private(set) var isRetrying = false
    /// The last transcription failure, for the UI. Stays nil for user cancellation.
    public private(set) var lastFailure: MemaClient.Failure?
    public var permissionDenied = false
    /// The last attempt to start recording failed (no file, no audio session).
    public private(set) var startFailed = false

    public var failedCount: Int { failed.count }

    private let recorder: any DictationRecording
    private let store: PendingRecordingStore
    private let client: MemaClient
    private let credentials: @MainActor () -> MemaCredentials?
    private let insert: @MainActor (String) async -> Bool
    private let send: @MainActor () async -> Void
    private let copy: @MainActor (String) -> Void
    private let insertTimeout: Duration
    @ObservationIgnored private var currentFile: URL?
    @ObservationIgnored private var inFlight: Set<URL> = []
    /// True from the first tap until recording starts or fails: the permission
    /// prompt suspends voiceTapped, and a second tap must not start another recording.
    @ObservationIgnored private var isStarting = false

    public init(
        recorder: any DictationRecording,
        store: PendingRecordingStore,
        client: MemaClient,
        credentials: @escaping @MainActor () -> MemaCredentials?,
        insert: @escaping @MainActor (String) async -> Bool,
        send: @escaping @MainActor () async -> Void,
        copy: @escaping @MainActor (String) -> Void,
        insertTimeout: Duration = .seconds(5)
    ) {
        self.recorder = recorder
        self.store = store
        self.client = client
        self.credentials = credentials
        self.insert = insert
        self.send = send
        self.copy = copy
        self.insertTimeout = insertTimeout
        recorder.onInterrupted = { [weak self] in
            Task { await self?.interrupted() }
        }
    }

    /// Call at launch. Files being recorded or transcribed right now are not failures.
    public func loadPending() {
        failed = store.all().filter { $0 != currentFile && !inFlight.contains($0) }
    }

    public func voiceTapped() async {
        guard state == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard await recorder.requestPermission() else {
            permissionDenied = true
            return
        }
        permissionDenied = false
        startFailed = false
        let file: URL
        do {
            file = try store.newFile()
        } catch {
            startFailed = true
            return
        }
        do {
            try recorder.start(to: file)
            currentFile = file
            lastFailure = nil
            state = .recording
        } catch {
            // Nothing usable was captured.
            recorder.stop()
            store.delete(file)
            startFailed = true
        }
    }

    public func cancelTapped() {
        guard state == .recording, let file = currentFile else { return }
        recorder.stop()
        store.delete(file)
        currentFile = nil
        state = .idle
    }

    /// A call, a route change or the app leaving the screen ended the recording:
    /// keep what was captured and transcribe it as if the user had tapped stop.
    public func interrupted() async {
        await stopTapped()
    }

    public func stopTapped() async {
        guard state == .recording, let file = currentFile else { return }
        recorder.stop()
        currentFile = nil
        state = .transcribing
        inFlight.insert(file)
        defer { inFlight.remove(file) }
        do {
            let text = try await transcribe(file)
            guard !text.isEmpty else {
                // A confirmed transcription of silence: nothing to keep (the plan discards it).
                store.delete(file)
                state = .idle
                return
            }
            // The text goes to the clipboard first and the audio is only deleted
            // once that and the insert attempt are done, so a hung or killed
            // insert never leaves the dictation nowhere.
            copy(text)
            let inserted = await insertBounded(text)
            store.delete(file)
            state = inserted ? .readyToSend : .idle
        } catch {
            record(failure: error)
            if !failed.contains(file) { failed.append(file) }
            state = .idle
        }
    }

    public func returnTapped() async {
        guard state == .readyToSend else { return }
        // Leave readyToSend first: a second tap during the await must not send twice.
        state = .idle
        await send()
    }

    /// Retries the oldest failed recording.
    public func retryAndCopyTapped() async {
        guard !isRetrying, let file = failed.first else { return }
        guard FileManager.default.fileExists(atPath: file.path) else {
            failed.removeAll { $0 == file }
            return
        }
        isRetrying = true
        inFlight.insert(file)
        defer {
            isRetrying = false
            inFlight.remove(file)
        }
        let text: String
        do {
            text = try await transcribe(file)
        } catch {
            record(failure: error)
            return
        }
        lastFailure = nil
        copy(text)
        store.delete(file)
        // Remove by identity: other recordings may have been added meanwhile.
        failed.removeAll { $0 == file }
    }

    public func dismissFailedTapped() {
        // The oldest recording is the one a retry is uploading.
        guard !isRetrying, let file = failed.first else { return }
        store.delete(file)
        failed.removeFirst()
    }

    /// Runs the insert but gives up after `insertTimeout`, treating that as a failed insert.
    /// An unstructured race: a task group would wait for an insert that never returns.
    private func insertBounded(_ text: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let insert = insert
            let timeout = insertTimeout
            Task { @MainActor in once.resume(await insert(text)) }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                once.resume(false)
            }
        }
    }

    @MainActor private final class Once {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    private func record(failure error: any Error) {
        if error is CancellationError {
            lastFailure = nil
        } else {
            lastFailure = (error as? MemaClient.Failure) ?? .invalidResponse
        }
    }

    private func transcribe(_ file: URL) async throws -> String {
        guard let credentials = credentials() else { throw MemaClient.Failure.unreachable }
        return try await client.transcribe(file: file, credentials: credentials)
    }
}
