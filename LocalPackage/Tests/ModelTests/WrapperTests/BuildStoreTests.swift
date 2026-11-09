import CryptoKit
import Foundation
import os
import Testing

@testable import DataSource

struct BuildStoreTests {
    private func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func manifest(_ id: String, _ files: [String: String]) -> BuildManifest {
        BuildManifest(
            buildId: id,
            files: files.map { .init(path: $0.key, sha256: hash($0.value), size: $0.value.utf8.count) }
        )
    }

    private func makeStore(
        _ files: [String: String],
        fetched: OSAllocatedUnfairLock<[String]> = .init(initialState: [])
    ) -> BuildStore {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return BuildStore(root: root, fetch: { path in
            fetched.withLock { $0.append(path) }
            guard let body = files[path] else { throw URLError(.fileDoesNotExist) }
            return Data(body.utf8)
        })
    }

    @Test
    func prepare_then_activate_exposes_the_files() async throws {
        let store = makeStore(["index.html": "a"])
        try await store.prepare(manifest("one", ["index.html": "a"]))
        try await store.activate("one")
        let directory = try #require(await store.currentDirectory())
        #expect(try String(contentsOf: directory.appending(path: "index.html"), encoding: .utf8) == "a")
    }

    @Test
    func a_hash_mismatch_discards_the_build() async throws {
        let store = makeStore(["index.html": "corrupt"])
        await #expect(throws: BuildStore.Failure.self) {
            try await store.prepare(manifest("one", ["index.html": "a"]))
        }
        #expect(await store.isReady("one") == false)
    }

    @Test
    func unchanged_files_are_not_downloaded_again() async throws {
        let fetched = OSAllocatedUnfairLock<[String]>(initialState: [])
        let store = makeStore(["a.js": "same", "b.js": "new"], fetched: fetched)
        try await store.prepare(manifest("one", ["a.js": "same"]))
        try await store.activate("one")
        fetched.withLock { $0 = [] }
        try await store.prepare(manifest("two", ["a.js": "same", "b.js": "new"]))
        #expect(fetched.withLock(\.self) == ["b.js"])
    }

    @Test
    func rollback_returns_to_the_previous_build() async throws {
        let store = makeStore(["index.html": "a"])
        try await store.prepare(manifest("one", ["index.html": "a"]))
        try await store.activate("one")
        try await store.prepare(manifest("two", ["index.html": "a"]))
        try await store.activate("two")
        #expect(try await store.rollback() == "one")
        #expect(await store.pointer().current == "one")
    }

    @Test
    func only_current_and_previous_are_kept() async throws {
        let store = makeStore(["index.html": "a"])
        for id in ["one", "two", "three"] {
            try await store.prepare(manifest(id, ["index.html": "a"]))
            try await store.activate(id)
        }
        #expect(await store.isReady("one") == false)
        #expect(await store.isReady("two"))
        #expect(await store.isReady("three"))
    }

    @Test
    func paths_cannot_escape_the_build_folder() async throws {
        let store = makeStore(["../evil": "a"])
        await #expect(throws: BuildStore.Failure.self) {
            try await store.prepare(manifest("one", ["../evil": "a"]))
        }
    }
}
