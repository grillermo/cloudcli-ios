import Foundation
import os
import Testing

@testable import DataSource
@testable import Model

@MainActor
final class FakeRecorder: DictationRecording {
    var granted = true
    var startCount = 0
    var stopCount = 0
    var startError: (any Error)?
    var onInterrupted: (@MainActor () -> Void)?

    func requestPermission() async -> Bool {
        await Task.yield()
        return granted
    }

    func start(to file: URL) throws {
        startCount += 1
        try Data("audio".utf8).write(to: file)
        if let startError { throw startError }
    }

    func stop() {
        stopCount += 1
    }
}

/// Holds a request until the test releases it.
actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DictationControllerTests {
    final class Sink {
        var inserted: [String] = []
        var sends = 0
        var clipboard: String?
        var insertSucceeds = true
    }

    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let credentials = MemaCredentials(baseURL: URL(string: "https://mema.example")!, token: "t")

    private func makeController(
        recorder: FakeRecorder = FakeRecorder(),
        sink: Sink,
        store: PendingRecordingStore,
        status: OSAllocatedUnfairLock<Int>,
        hasCredentials: Bool = true,
        handler: Handler? = nil,
        insert: (@MainActor (String) async -> Bool)? = nil,
        sendGate: Gate? = nil,
        insertTimeout: Duration = .seconds(5)
    ) -> DictationController {
        let client = MemaClient(send: handler ?? { request in
            let code = request.httpMethod == "POST" ? status.withLock(\.self) : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"text":"hola"}"#.utf8), response)
        }, busyDelay: .zero)
        let available = hasCredentials ? credentials : nil
        return DictationController(
            recorder: recorder,
            store: store,
            client: client,
            credentials: { available },
            insert: insert ?? { text in
                sink.inserted.append(text)
                return sink.insertSucceeds
            },
            send: {
                sink.sends += 1
                await sendGate?.wait()
            },
            copy: { sink.clipboard = $0 },
            insertTimeout: insertTimeout
        )
    }

    private func makeStore() -> PendingRecordingStore {
        PendingRecordingStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    nonisolated private static func okResponse(_ request: URLRequest, status: Int = 200, headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
        (Data(#"{"text":"hola"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    /// Polls until the condition holds. Fails the test when the deadline passes.
    private func waitUntil(
        _ what: String = "condition",
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test
    func happy_path_runs_voice_stop_return_idle() async {
        let sink = Sink()
        let store = makeStore()
        let sut = makeController(sink: sink, store: store, status: .init(initialState: 200))
        await sut.voiceTapped()
        #expect(sut.state == .recording)
        await sut.stopTapped()
        #expect(sut.state == .readyToSend)
        #expect(sink.inserted == ["hola"])
        #expect(store.all().isEmpty)
        await sut.returnTapped()
        #expect(sut.state == .idle)
        #expect(sink.sends == 1)
    }

    @Test
    func cancel_discards_the_recording() async {
        let sink = Sink()
        let store = makeStore()
        let recorder = FakeRecorder()
        let sut = makeController(recorder: recorder, sink: sink, store: store, status: .init(initialState: 200))
        await sut.voiceTapped()
        sut.cancelTapped()
        #expect(sut.state == .idle)
        #expect(recorder.stopCount == 1)
        #expect(store.all().isEmpty)
        #expect(sink.inserted.isEmpty)
    }

    @Test
    func a_failure_keeps_the_recording_and_shows_the_bar() async {
        let store = makeStore()
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 500))
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sut.state == .idle)
        #expect(sut.failedCount == 1)
        #expect(store.all().count == 1)
    }

    @Test
    func a_successful_retry_copies_and_removes_the_recording() async {
        let sink = Sink()
        let store = makeStore()
        let status = OSAllocatedUnfairLock(initialState: 500)
        let sut = makeController(sink: sink, store: store, status: status)
        await sut.voiceTapped()
        await sut.stopTapped()
        status.withLock { $0 = 200 }
        await sut.retryAndCopyTapped()
        #expect(sink.clipboard == "hola")
        #expect(sink.inserted.isEmpty)
        #expect(sut.failedCount == 0)
        #expect(store.all().isEmpty)
    }

    @Test
    func a_failed_retry_keeps_the_bar() async {
        let store = makeStore()
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 500))
        await sut.voiceTapped()
        await sut.stopTapped()
        await sut.retryAndCopyTapped()
        #expect(sut.failedCount == 1)
        #expect(store.all().count == 1)
    }

    @Test
    func failed_recordings_return_on_next_launch() throws {
        let store = makeStore()
        try Data("audio".utf8).write(to: store.newFile())
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200))
        sut.loadPending()
        #expect(sut.failedCount == 1)
    }

    @Test
    func dismiss_removes_the_recording() async {
        let store = makeStore()
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 500))
        await sut.voiceTapped()
        await sut.stopTapped()
        sut.dismissFailedTapped()
        #expect(sut.failedCount == 0)
        #expect(store.all().isEmpty)
    }

    @Test
    func text_with_no_composer_on_screen_goes_to_the_clipboard() async {
        let sink = Sink()
        sink.insertSucceeds = false
        let sut = makeController(sink: sink, store: makeStore(), status: .init(initialState: 200))
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sink.clipboard == "hola")
        #expect(sut.state == .idle)
    }

    @Test
    func denied_permission_does_not_record() async {
        let recorder = FakeRecorder()
        recorder.granted = false
        let sut = makeController(recorder: recorder, sink: Sink(), store: makeStore(), status: .init(initialState: 200))
        await sut.voiceTapped()
        #expect(sut.state == .idle)
        #expect(sut.permissionDenied)
    }

    @Test
    func missing_settings_keep_the_recording() async {
        let store = makeStore()
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200), hasCredentials: false)
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sut.failedCount == 1)
        #expect(store.all().count == 1)
    }

    // MARK: Races and edge cases

    @Test
    func a_double_tap_on_voice_starts_one_recording() async {
        let recorder = FakeRecorder()
        let store = makeStore()
        let sut = makeController(recorder: recorder, sink: Sink(), store: store, status: .init(initialState: 200))
        async let first: Void = sut.voiceTapped()
        async let second: Void = sut.voiceTapped()
        _ = await (first, second)
        #expect(recorder.startCount == 1)
        #expect(sut.state == .recording)
        #expect(store.all().count == 1)
    }

    @Test
    func a_failed_start_leaves_no_file_and_stays_idle() async {
        let recorder = FakeRecorder()
        recorder.startError = URLError(.cannotCreateFile)
        let store = makeStore()
        let sut = makeController(recorder: recorder, sink: Sink(), store: store, status: .init(initialState: 200))
        await sut.voiceTapped()
        #expect(sut.state == .idle)
        #expect(store.all().isEmpty)
        #expect(sut.failedCount == 0)
    }

    @Test
    func permission_granted_later_clears_the_denied_flag() async {
        let recorder = FakeRecorder()
        recorder.granted = false
        let sut = makeController(recorder: recorder, sink: Sink(), store: makeStore(), status: .init(initialState: 200))
        await sut.voiceTapped()
        #expect(sut.permissionDenied)
        recorder.granted = true
        await sut.voiceTapped()
        #expect(!sut.permissionDenied)
        #expect(sut.state == .recording)
    }

    @Test
    func an_interruption_while_recording_transcribes_what_was_captured() async {
        let sink = Sink()
        let recorder = FakeRecorder()
        let store = makeStore()
        let sut = makeController(recorder: recorder, sink: sink, store: store, status: .init(initialState: 200))
        await sut.voiceTapped()
        recorder.onInterrupted?()
        await waitUntil { sut.state == .readyToSend }
        #expect(sut.state == .readyToSend)
        #expect(sink.inserted == ["hola"])
        #expect(recorder.stopCount == 1)
        #expect(store.all().isEmpty)
    }

    @Test
    func an_interruption_with_no_server_keeps_the_audio() async {
        let recorder = FakeRecorder()
        let store = makeStore()
        let sut = makeController(recorder: recorder, sink: Sink(), store: store, status: .init(initialState: 500))
        await sut.voiceTapped()
        await sut.interrupted()
        #expect(sut.state == .idle)
        #expect(sut.failedCount == 1)
        #expect(store.all().count == 1)
    }

    @Test
    func interrupted_when_not_recording_does_nothing() async {
        let recorder = FakeRecorder()
        let sut = makeController(recorder: recorder, sink: Sink(), store: makeStore(), status: .init(initialState: 200))
        await sut.interrupted()
        #expect(recorder.stopCount == 0)
        #expect(sut.state == .idle)
    }

    @Test
    func a_double_tap_on_return_sends_once() async {
        let sink = Sink()
        let gate = Gate()
        let sut = makeController(sink: sink, store: makeStore(), status: .init(initialState: 200), sendGate: gate)
        await sut.voiceTapped()
        await sut.stopTapped()
        let first = Task { await sut.returnTapped() }
        await waitUntil("the first send to start") { sink.sends == 1 }
        // The first send is suspended: this tap really interleaves with it.
        // It runs as a task so a broken guard fails the count instead of hanging on the gate.
        let second = Task { await sut.returnTapped() }
        try? await Task.sleep(for: .milliseconds(50))
        await gate.open()
        await first.value
        await second.value
        #expect(sink.sends == 1)
        #expect(sut.state == .idle)
    }

    @Test
    func stop_while_transcribing_is_ignored_and_voice_cannot_start() async {
        let gate = Gate()
        let store = makeStore()
        let recorder = FakeRecorder()
        let sut = makeController(recorder: recorder, sink: Sink(), store: store, status: .init(initialState: 200), handler: { request in
            if request.httpMethod == "POST" { await gate.wait() }
            return Self.okResponse(request)
        })
        await sut.voiceTapped()
        let stopping = Task { await sut.stopTapped() }
        await waitUntil { sut.state == .transcribing }
        await sut.voiceTapped()
        await sut.stopTapped()
        sut.cancelTapped()
        #expect(recorder.startCount == 1)
        #expect(recorder.stopCount == 1)
        #expect(sut.state == .transcribing)
        await gate.open()
        await stopping.value
        #expect(sut.state == .readyToSend)
    }

    @Test
    func cancellation_during_transcription_keeps_the_audio_without_an_error() async {
        let store = makeStore()
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200), handler: { request in
            if request.httpMethod == "POST" { throw CancellationError() }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sut.state == .idle)
        #expect(store.all().count == 1)
        #expect(sut.failedCount == 1)
        #expect(sut.lastFailure == nil)
    }

    @Test
    func each_failure_kind_keeps_the_audio_and_is_reported() async {
        let cases: [(Int, [String: String], MemaClient.Failure)] = [
            (500, [:], .status(500)),
            (401, [:], .status(401)),
            (503, ["Retry-After": "1"], .busy),
        ]
        for (code, headers, expected) in cases {
            let store = makeStore()
            let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200), handler: { request in
                request.httpMethod == "POST" ? Self.okResponse(request, status: code, headers: headers) : Self.okResponse(request)
            })
            await sut.voiceTapped()
            await sut.stopTapped()
            #expect(sut.lastFailure == expected)
            #expect(store.all().count == 1)
            #expect(sut.state == .idle)
        }
        for (error, expected) in [(URLError(.timedOut), MemaClient.Failure.timedOut), (URLError(.notConnectedToInternet), .unreachable)] {
            let store = makeStore()
            let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200), handler: { request in
                if request.httpMethod == "POST" { throw error }
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            await sut.voiceTapped()
            await sut.stopTapped()
            #expect(sut.lastFailure == expected)
            #expect(store.all().count == 1)
        }
    }

    @Test
    func a_busy_server_costs_a_bounded_number_of_uploads_per_retry() async {
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let store = makeStore()
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200), handler: { request in
            guard request.httpMethod == "POST" else { return Self.okResponse(request) }
            posts.withLock { $0 += 1 }
            return Self.okResponse(request, status: 503, headers: ["Retry-After": "1"])
        })
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(posts.withLock(\.self) == 3)
        await sut.retryAndCopyTapped()
        #expect(posts.withLock(\.self) == 6)
        #expect(store.all().count == 1)
    }

    @Test
    func dismissing_during_a_retry_does_not_lose_or_misremove_recordings() async throws {
        let gate = Gate()
        let store = makeStore()
        let sink = Sink()
        let status = OSAllocatedUnfairLock(initialState: 500)
        let sut = makeController(sink: sink, store: store, status: status, handler: { request in
            guard request.httpMethod == "POST" else { return Self.okResponse(request) }
            if status.withLock(\.self) == 200 { await gate.wait() }
            return Self.okResponse(request, status: status.withLock(\.self))
        })
        await sut.voiceTapped()
        await sut.stopTapped()
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sut.failedCount == 2)
        status.withLock { $0 = 200 }
        let retrying = Task { await sut.retryAndCopyTapped() }
        await waitUntil { sut.isRetrying }
        sut.dismissFailedTapped()
        #expect(store.all().count == 2)
        await gate.open()
        await retrying.value
        #expect(sink.clipboard == "hola")
        #expect(sut.failedCount == 1)
        #expect(store.all().count == 1)
        #expect(sut.failed == store.all())
    }

    @Test
    func a_failure_arriving_during_a_retry_is_not_dropped() async {
        let entered = Gate()
        let release = Gate()
        let store = makeStore()
        let posts = OSAllocatedUnfairLock(initialState: 0)
        // POST 1 (first recording) fails, POST 2 (the retry) waits for the test, POST 3 fails.
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200), handler: { request in
            guard request.httpMethod == "POST" else { return Self.okResponse(request) }
            let n = posts.withLock { count -> Int in
                count += 1
                return count
            }
            switch n {
            case 2:
                await entered.open()
                await release.wait()
                return Self.okResponse(request)
            default:
                return Self.okResponse(request, status: 500)
            }
        })
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sut.failedCount == 1)
        let retrying = Task { await sut.retryAndCopyTapped() }
        await entered.wait()
        // A new recording fails while the retry is in flight.
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sut.failedCount == 2)
        await release.open()
        await retrying.value
        #expect(sut.failedCount == 1)
        #expect(sut.failed == store.all())
    }

    @Test
    func loading_pending_skips_the_file_being_recorded() async throws {
        let store = makeStore()
        try Data("audio".utf8).write(to: store.newFile())
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200))
        await sut.voiceTapped()
        sut.loadPending()
        #expect(sut.failedCount == 1)
        #expect(sut.state == .recording)
    }

    @Test
    func a_retry_for_a_vanished_file_drops_the_entry() async throws {
        let store = makeStore()
        let file = try store.newFile()
        try Data("audio".utf8).write(to: file)
        let sut = makeController(sink: Sink(), store: store, status: .init(initialState: 200))
        sut.loadPending()
        store.delete(file)
        await sut.retryAndCopyTapped()
        #expect(sut.failedCount == 0)
    }

    @Test
    func an_empty_transcript_removes_the_audio_and_inserts_nothing() async {
        let sink = Sink()
        let store = makeStore()
        let sut = makeController(sink: sink, store: store, status: .init(initialState: 200), handler: { request in
            let body = request.httpMethod == "POST" ? Data(#"{"text":"  "}"#.utf8) : Data()
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sut.state == .idle)
        #expect(sink.inserted.isEmpty)
        #expect(store.all().isEmpty)
    }

    // MARK: Insert and clipboard safety

    @Test
    func the_text_reaches_the_clipboard_before_the_audio_is_deleted_even_when_insert_succeeds() async {
        let sink = Sink()
        let store = makeStore()
        let sut = makeController(sink: sink, store: store, status: .init(initialState: 200))
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sink.clipboard == "hola")
        #expect(sink.inserted == ["hola"])
        #expect(sut.state == .readyToSend)
        #expect(store.all().isEmpty)
    }

    @Test
    func an_insert_that_never_returns_times_out_without_losing_the_text() async {
        let store = makeStore()
        let sink = Sink()
        let never = Gate()
        let observed = OSAllocatedUnfairLock(initialState: [URL]())
        let sut = makeController(sink: sink, store: store, status: .init(initialState: 200), insert: { _ in
            // The audio must still exist while the text only lives on the clipboard.
            observed.withLock { $0 = store.all() }
            await never.wait()
            return true
        }, insertTimeout: .milliseconds(50))
        await sut.voiceTapped()
        await sut.stopTapped()
        #expect(sut.state == .idle)
        #expect(sink.clipboard == "hola")
        #expect(observed.withLock(\.self).count == 1)
        #expect(store.all().isEmpty)
        await never.open()
    }

    @Test
    func a_failed_start_is_reported() async {
        let recorder = FakeRecorder()
        recorder.startError = URLError(.cannotCreateFile)
        let sut = makeController(recorder: recorder, sink: Sink(), store: makeStore(), status: .init(initialState: 200))
        await sut.voiceTapped()
        #expect(sut.startFailed)
        recorder.startError = nil
        await sut.voiceTapped()
        #expect(!sut.startFailed)
        #expect(sut.state == .recording)
    }
}
