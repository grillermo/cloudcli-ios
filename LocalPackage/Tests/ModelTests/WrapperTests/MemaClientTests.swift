import Foundation
import os
import Testing

@testable import DataSource

struct MemaClientTests {
    private let credentials = MemaCredentials(baseURL: URL(string: "https://mema.example")!, token: "t")

    private func response(_ url: URL, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    private func audioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    @Test
    func uploads_m4a_with_the_token_and_returns_trimmed_text() async throws {
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        let client = MemaClient(send: { [self] request in
            if request.httpMethod == "POST" { captured.withLock { $0 = request } }
            let data = request.httpMethod == "POST" ? Data(#"{"text":" hola "}"#.utf8) : Data()
            return (data, response(request.url!, 200))
        }, busyDelay: .zero)

        #expect(try await client.transcribe(file: audioFile(), credentials: credentials) == "hola")

        let request = try #require(captured.withLock { $0 })
        #expect(request.url?.absoluteString == "https://mema.example/v1/transcribe")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("filename=\"audio.m4a\""))
        #expect(body.contains("Content-Type: audio/mp4"))
        #expect(body.contains("name=\"cleanup_mode\""))
    }

    @Test
    func multipart_body_is_well_formed_and_the_token_stays_in_the_header() async throws {
        let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        let secret = "fake-secret-token"
        let creds = MemaCredentials(baseURL: URL(string: "https://mema.example/")!, token: secret)
        let client = MemaClient(send: { [self] request in
            if request.httpMethod == "POST" { captured.withLock { $0 = request } }
            let data = request.httpMethod == "POST" ? Data(#"{"text":"x"}"#.utf8) : Data()
            return (data, response(request.url!, 200))
        }, busyDelay: .zero)
        _ = try await client.transcribe(file: audioFile(), credentials: creds)

        let request = try #require(captured.withLock { $0 })
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.hasPrefix("--\(boundary)\r\n"))
        #expect(body.hasSuffix("\r\n--\(boundary)--\r\n"))
        #expect(body.contains("\r\n\r\naudio\r\n--\(boundary)--"))
        #expect(!body.contains(secret))
        #expect(request.url?.absoluteString.contains(secret) == false)
        #expect(request.url?.absoluteString == "https://mema.example/v1/transcribe")
        #expect(request.timeoutInterval == 60)
    }

    @Test
    func probes_with_a_short_timeout_and_no_token() async throws {
        let probe = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        let client = MemaClient(send: { [self] request in
            if request.httpMethod == "HEAD" { probe.withLock { $0 = request } }
            let data = request.httpMethod == "POST" ? Data(#"{"text":"x"}"#.utf8) : Data()
            return (data, response(request.url!, 200))
        }, busyDelay: .zero)
        _ = try await client.transcribe(file: audioFile(), credentials: credentials)
        let request = try #require(probe.withLock { $0 })
        #expect(request.timeoutInterval == 3)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func retries_a_busy_server_twice_then_fails() async throws {
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let client = MemaClient(send: { [self] request in
            if request.httpMethod == "POST" { posts.withLock { $0 += 1 } }
            let status = request.httpMethod == "POST" ? 503 : 200
            return (Data(), response(request.url!, status, headers: ["Retry-After": "1"]))
        }, busyDelay: .zero)

        await #expect(throws: MemaClient.Failure.busy) {
            try await client.transcribe(file: audioFile(), credentials: credentials)
        }
        #expect(posts.withLock(\.self) == 3)
    }

    @Test
    func a_busy_server_that_recovers_returns_the_text() async throws {
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let client = MemaClient(send: { [self] request in
            guard request.httpMethod == "POST" else { return (Data(), response(request.url!, 200)) }
            let count = posts.withLock { $0 += 1; return $0 }
            if count < 2 { return (Data(), response(request.url!, 503, headers: ["Retry-After": "1"])) }
            return (Data(#"{"text":"ok"}"#.utf8), response(request.url!, 200))
        }, busyDelay: .zero)
        #expect(try await client.transcribe(file: audioFile(), credentials: credentials) == "ok")
        #expect(posts.withLock(\.self) == 2)
    }

    @Test
    func a_503_without_retry_after_is_a_plain_status() async throws {
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let client = MemaClient(send: { [self] request in
            if request.httpMethod == "POST" { posts.withLock { $0 += 1 } }
            return (Data(), response(request.url!, request.httpMethod == "POST" ? 503 : 200))
        }, busyDelay: .zero)
        await #expect(throws: MemaClient.Failure.status(503)) {
            try await client.transcribe(file: audioFile(), credentials: credentials)
        }
        #expect(posts.withLock(\.self) == 1)
    }

    @Test
    func busy_retries_back_off() async throws {
        let client = MemaClient(send: { [self] request in
            let status = request.httpMethod == "POST" ? 503 : 200
            return (Data(), response(request.url!, status, headers: ["Retry-After": "1"]))
        }, busyDelay: .milliseconds(100))
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = try? await client.transcribe(file: audioFile(), credentials: credentials)
        }
        // 100ms + 200ms between the three attempts.
        #expect(elapsed >= .milliseconds(290))
    }

    @Test
    func cancelling_during_the_busy_wait_stops_retrying() async throws {
        let posts = OSAllocatedUnfairLock(initialState: 0)
        let client = MemaClient(send: { [self] request in
            if request.httpMethod == "POST" { posts.withLock { $0 += 1 } }
            let status = request.httpMethod == "POST" ? 503 : 200
            return (Data(), response(request.url!, status, headers: ["Retry-After": "1"]))
        }, busyDelay: .seconds(30))
        let file = try audioFile()
        let task = Task { try await client.transcribe(file: file, credentials: credentials) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(posts.withLock(\.self) == 1)
    }

    @Test
    func cancellation_is_not_reported_as_unreachable() async throws {
        let client = MemaClient(send: { _ in throw URLError(.cancelled) }, busyDelay: .zero)
        await #expect(throws: CancellationError.self) {
            try await client.transcribe(file: audioFile(), credentials: credentials)
        }
    }

    @Test
    func an_absent_server_is_unreachable() async throws {
        let client = MemaClient(send: { _ in throw URLError(.cannotConnectToHost) }, busyDelay: .zero)
        await #expect(throws: MemaClient.Failure.unreachable) {
            try await client.transcribe(file: audioFile(), credentials: credentials)
        }
    }

    @Test
    func a_failed_upload_is_unreachable_and_a_timeout_is_its_own_failure() async throws {
        let dropped = MemaClient(send: { [self] request in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (Data(), response(request.url!, 200))
        }, busyDelay: .zero)
        await #expect(throws: MemaClient.Failure.unreachable) {
            try await dropped.transcribe(file: audioFile(), credentials: credentials)
        }
        let slow = MemaClient(send: { [self] request in
            if request.httpMethod == "POST" { throw URLError(.timedOut) }
            return (Data(), response(request.url!, 200))
        }, busyDelay: .zero)
        await #expect(throws: MemaClient.Failure.timedOut) {
            try await slow.transcribe(file: audioFile(), credentials: credentials)
        }
    }

    @Test
    func other_statuses_are_reported() async throws {
        let client = MemaClient(send: { [self] request in
            (Data(), response(request.url!, request.httpMethod == "POST" ? 401 : 200))
        }, busyDelay: .zero)
        await #expect(throws: MemaClient.Failure.status(401)) {
            try await client.transcribe(file: audioFile(), credentials: credentials)
        }
    }

    @Test
    func a_garbled_success_body_is_an_invalid_response() async throws {
        let client = MemaClient(send: { [self] request in
            (Data("<html>".utf8), response(request.url!, 200))
        }, busyDelay: .zero)
        await #expect(throws: MemaClient.Failure.invalidResponse) {
            try await client.transcribe(file: audioFile(), credentials: credentials)
        }
    }

    @Test
    func a_missing_audio_file_fails_without_touching_the_network() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let client = MemaClient(send: { [self] request in
            calls.withLock { $0 += 1 }
            return (Data(), response(request.url!, 200))
        }, busyDelay: .zero)
        let missing = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        await #expect(throws: (any Error).self) {
            try await client.transcribe(file: missing, credentials: credentials)
        }
        #expect(calls.withLock(\.self) == 0)
    }

    @Test
    func failures_never_carry_the_token() {
        let creds = MemaCredentials(baseURL: URL(string: "https://mema.example")!, token: "fake-secret-token")
        for failure in [MemaClient.Failure.unreachable, .busy, .timedOut, .status(401), .invalidResponse] {
            #expect(!String(describing: failure).contains(creds.token))
        }
    }
}
