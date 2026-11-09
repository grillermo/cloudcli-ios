import Foundation

public struct MemaClient: Sendable {
    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public enum Failure: Error, Equatable {
        case unreachable
        case busy
        case timedOut
        case status(Int)
        case invalidResponse
    }

    private struct Transcript: Decodable {
        let text: String
    }

    private static let maxBusyRetries = 2
    private let send: Send
    private let busyDelay: Duration

    public init(send: @escaping Send, busyDelay: Duration = .seconds(2)) {
        self.send = send
        self.busyDelay = busyDelay
    }

    public static let live = MemaClient(send: { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    })

    public func transcribe(file: URL, credentials: MemaCredentials) async throws -> String {
        // Read the audio first: a missing file must not cost a network round trip.
        let request = try Self.uploadRequest(file: file, credentials: credentials)
        try await probe(credentials.baseURL)

        var retries = 0
        while true {
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await send(request)
            } catch {
                try Self.rethrowCancellation(error)
                throw (error as? URLError)?.code == .timedOut ? Failure.timedOut : Failure.unreachable
            }
            switch response.statusCode {
            case 200:
                guard let transcript = try? JSONDecoder().decode(Transcript.self, from: data) else {
                    throw Failure.invalidResponse
                }
                return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            case 503 where response.value(forHTTPHeaderField: "Retry-After") != nil:
                guard retries < Self.maxBusyRetries else { throw Failure.busy }
                // Bounded exponential backoff; Task.sleep throws when cancelled.
                try await Task.sleep(for: busyDelay * (1 << retries))
                retries += 1
            default:
                throw Failure.status(response.statusCode)
            }
        }
    }

    /// URLSession has no connect timeout, so a short request tells an absent
    /// server apart from a slow transcription. Any HTTP response means it is there.
    private func probe(_ baseURL: URL) async throws {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 3
        do {
            _ = try await send(request)
        } catch {
            try Self.rethrowCancellation(error)
            throw Failure.unreachable
        }
    }

    private static func rethrowCancellation(_ error: any Error) throws {
        if error is CancellationError || (error as? URLError)?.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        }
    }

    private static func uploadRequest(file: URL, credentials: MemaCredentials) throws -> URLRequest {
        let boundary = "cloudcli-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"cleanup_mode\"\r\n\r\nraw\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: credentials.baseURL.appending(path: "v1/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
}
