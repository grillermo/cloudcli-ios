import CryptoKit
import Foundation

public actor BuildStore {
    public typealias Fetch = @Sendable (String) async throws -> Data

    public enum Failure: Error, Equatable {
        case hashMismatch(String)
        case unsafePath(String)
        case notReady(String)
    }

    public struct Pointer: Codable, Equatable, Sendable {
        public var current: String?
        public var previous: String?
    }

    private static let manifestName = ".manifest.json"
    private let root: URL
    private let fetch: Fetch
    private let files = FileManager.default

    public init(root: URL, fetch: @escaping Fetch) {
        self.root = root
        self.fetch = fetch
    }

    private var builds: URL { root.appending(path: "builds", directoryHint: .isDirectory) }
    private var pointerFile: URL { root.appending(path: "current.json") }
    private func folder(_ id: String) -> URL { builds.appending(path: id, directoryHint: .isDirectory) }

    public func pointer() -> Pointer {
        guard let data = try? Data(contentsOf: pointerFile),
              let value = try? JSONDecoder().decode(Pointer.self, from: data) else {
            return Pointer()
        }
        return value
    }

    /// A build's manifest is written last, so its presence means the build is complete.
    public func isReady(_ id: String) -> Bool {
        files.fileExists(atPath: folder(id).appending(path: Self.manifestName).path)
    }

    public func currentDirectory() -> URL? {
        guard let id = pointer().current, isReady(id) else { return nil }
        return folder(id)
    }

    public func prepare(_ manifest: BuildManifest) async throws {
        guard !isReady(manifest.buildId) else { return }
        let partial = builds.appending(path: "\(manifest.buildId).partial", directoryHint: .isDirectory)
        try? files.removeItem(at: partial)
        try files.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            let known = currentFiles()
            for file in manifest.files {
                guard Self.isSafe(file.path) else { throw Failure.unsafePath(file.path) }
                let destination = partial.appending(path: file.path)
                try files.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data: Data
                if let existing = known[file.path], existing.sha256 == file.sha256 {
                    data = try Data(contentsOf: existing.url)
                } else {
                    data = try await fetch(file.path)
                }
                guard Self.sha256(data) == file.sha256 else { throw Failure.hashMismatch(file.path) }
                try data.write(to: destination)
            }
            try JSONEncoder().encode(manifest).write(to: partial.appending(path: Self.manifestName))
            try? files.removeItem(at: folder(manifest.buildId))
            try files.moveItem(at: partial, to: folder(manifest.buildId))
        } catch {
            try? files.removeItem(at: partial)
            throw error
        }
    }

    public func activate(_ id: String) throws {
        guard isReady(id) else { throw Failure.notReady(id) }
        let old = pointer()
        try write(Pointer(current: id, previous: old.current == id ? old.previous : old.current))
        prune()
    }

    /// Returns the build now current, or nil when there is nothing to return to.
    public func rollback() throws -> String? {
        let old = pointer()
        guard let previous = old.previous, isReady(previous) else { return nil }
        try write(Pointer(current: previous, previous: nil))
        return previous
    }

    private func write(_ value: Pointer) throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: pointerFile, options: .atomic)
    }

    private func prune() {
        let value = pointer()
        let keep = Set([value.current, value.previous].compactMap(\.self))
        for name in (try? files.contentsOfDirectory(atPath: builds.path)) ?? [] where !keep.contains(name) {
            try? files.removeItem(at: builds.appending(path: name))
        }
    }

    private func currentFiles() -> [String: (sha256: String, url: URL)] {
        guard let directory = currentDirectory(),
              let data = try? Data(contentsOf: directory.appending(path: Self.manifestName)),
              let manifest = try? JSONDecoder().decode(BuildManifest.self, from: data) else {
            return [:]
        }
        var result: [String: (sha256: String, url: URL)] = [:]
        for file in manifest.files {
            result[file.path] = (file.sha256, directory.appending(path: file.path))
        }
        return result
    }

    private static func isSafe(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
