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
        try await store.confirm("one")
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
            try await store.confirm(id)
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

    @Test
    func malicious_build_ids_throw_and_touch_nothing_outside_builds() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sentinelName = "sentinel-\(UUID().uuidString)"
        let sentinel = root.deletingLastPathComponent().appending(path: sentinelName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        let store = BuildStore(root: root, fetch: { _ in Data("a".utf8) })
        for id in ["../../\(sentinelName)", "a/b", "", ".", "..", "a\\b", "x.partial", ".partial"] {
            await #expect(throws: BuildStore.Failure.self) {
                try await store.prepare(manifest(id, ["index.html": "a"]))
            }
            await #expect(throws: BuildStore.Failure.self) {
                try await store.activate(id)
            }
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test
    func rollback_rejects_a_tampered_pointer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"current":"one","previous":"../x"}"#.utf8).write(to: root.appending(path: "current.json"))
        let store = BuildStore(root: root, fetch: { _ in Data() })
        await #expect(throws: BuildStore.Failure.self) { _ = try await store.rollback() }
    }

    @Test
    func rollback_without_a_previous_build_returns_nil() async throws {
        let store = makeStore(["index.html": "a"])
        #expect(try await store.rollback() == nil)
        try await store.prepare(manifest("one", ["index.html": "a"]))
        try await store.activate("one")
        #expect(try await store.rollback() == nil)
    }

    @Test
    func unsafe_file_paths_are_rejected() async throws {
        for path in ["", ".", "a/./b", "a\\b", "a\u{0}b", "/abs", "a/../b"] {
            let store = makeStore([path: "a"])
            await #expect(throws: BuildStore.Failure.self) {
                try await store.prepare(manifest("one", [path: "a"]))
            }
        }
    }

    @Test
    func prune_keeps_in_flight_partials_and_init_cleans_stale_ones() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let partial = root.appending(path: "builds/two.partial", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let fetch: BuildStore.Fetch = { _ in Data("a".utf8) }
        let store = BuildStore(root: root, fetch: fetch)
        // init removed the stale partial; recreate it as if a prepare were in flight.
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        try await store.prepare(manifest("one", ["index.html": "a"]))
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try await store.activate("one")
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    @Test
    func concurrent_prepares_of_the_same_id_leave_one_intact_build() async throws {
        let fetched = OSAllocatedUnfairLock<[String]>(initialState: [])
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = BuildStore(root: root, fetch: { path in
            fetched.withLock { $0.append(path) }
            try await Task.sleep(for: .milliseconds(200))
            return Data("a".utf8)
        })
        let m = manifest("one", ["index.html": "a", "b.js": "a"])
        async let first: Void = store.prepare(m)
        async let second: Void = store.prepare(m)
        _ = try await (first, second)
        #expect(await store.isReady("one"))
        try await store.activate("one")
        let directory = try #require(await store.currentDirectory())
        #expect(try String(contentsOf: directory.appending(path: "b.js"), encoding: .utf8) == "a")
        #expect(fetched.withLock(\.self).count == 2)
    }

    @Test
    func preparing_the_current_build_again_keeps_it_usable() async throws {
        let store = makeStore(["index.html": "a"])
        try await store.prepare(manifest("one", ["index.html": "a"]))
        try await store.activate("one")
        try await store.prepare(manifest("one", ["index.html": "a"]))
        let directory = try #require(await store.currentDirectory())
        #expect(try String(contentsOf: directory.appending(path: "index.html"), encoding: .utf8) == "a")
    }

    @Test
    func a_failed_prepare_clears_in_flight_so_a_retry_succeeds() async throws {
        let healthy = OSAllocatedUnfairLock<Bool>(initialState: false)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = BuildStore(root: root, fetch: { _ in
            try await Task.sleep(for: .milliseconds(100))
            guard healthy.withLock(\.self) else { throw URLError(.notConnectedToInternet) }
            return Data("a".utf8)
        })
        let m = manifest("one", ["index.html": "a"])
        async let first: Void = store.prepare(m)
        async let second: Void = store.prepare(m)
        var failures = 0
        do { try await first } catch { failures += 1 }
        do { try await second } catch { failures += 1 }
        #expect(failures == 2)
        #expect(await store.isReady("one") == false)
        healthy.withLock { $0 = true }
        try await store.prepare(m)
        #expect(await store.isReady("one"))
    }

    @Test
    func rollback_skips_builds_that_never_confirmed() async throws {
        let store = makeStore(["index.html": "a"])
        try await store.prepare(manifest("one", ["index.html": "a"]))
        try await store.activate("one")
        try await store.confirm("one")
        for id in ["two", "three"] {
            try await store.prepare(manifest(id, ["index.html": "a"]))
            try await store.activate(id)
        }
        #expect(await store.pointer().previous == "one")
        #expect(try await store.rollback() == "one")
        #expect(await store.pointer().current == "one")
    }

    @Test
    func confirm_only_accepts_the_current_build() async throws {
        let store = makeStore(["index.html": "a"])
        try await store.prepare(manifest("one", ["index.html": "a"]))
        try await store.prepare(manifest("two", ["index.html": "a"]))
        try await store.activate("one")
        await #expect(throws: BuildStore.Failure.self) { try await store.confirm("two") }
        try await store.confirm("one")
        #expect(await store.pointer().confirmed == "one")
    }

    @Test
    func prune_keeps_the_confirmed_build() async throws {
        let store = makeStore(["index.html": "a"])
        try await store.prepare(manifest("one", ["index.html": "a"]))
        try await store.activate("one")
        try await store.confirm("one")
        for id in ["two", "three", "four"] {
            try await store.prepare(manifest(id, ["index.html": "a"]))
            try await store.activate(id)
        }
        #expect(await store.isReady("one"))
        #expect(await store.isReady("four"))
        #expect(await store.isReady("two") == false)
    }

    @Test
    func a_pointer_file_without_confirmed_still_decodes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"current":"one","previous":"zero"}"#.utf8).write(to: root.appending(path: "current.json"))
        let store = BuildStore(root: root, fetch: { _ in Data() })
        let pointer = await store.pointer()
        #expect(pointer.current == "one")
        #expect(pointer.previous == "zero")
        #expect(pointer.confirmed == nil)
    }
}
