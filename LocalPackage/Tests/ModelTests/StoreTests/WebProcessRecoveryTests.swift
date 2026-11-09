import Foundation
import Testing

@testable import Model

struct WebProcessRecoveryTests {
    @Test
    func reloads_up_to_the_retry_limit_then_stops() {
        var sut = WebProcessRecovery()
        let url = URL(string: "cloudcli://app/")!
        for _ in 0 ..< WebProcessRecovery.maxRetries {
            #expect(sut.didTerminate(currentURL: url) == .reload)
        }
        #expect(sut.didTerminate(currentURL: url) == .none)
    }

    @Test
    func a_finished_navigation_resets_the_retries() {
        var sut = WebProcessRecovery()
        let url = URL(string: "cloudcli://app/")!
        for _ in 0 ..< WebProcessRecovery.maxRetries {
            _ = sut.didTerminate(currentURL: url)
        }
        sut.didFinish(url: url)
        #expect(sut.didTerminate(currentURL: url) == .reload)
    }

    @Test
    func loads_the_last_known_url_when_the_web_view_lost_its_url() {
        var sut = WebProcessRecovery()
        let url = URL(string: "cloudcli://app/session/abc")!
        sut.didFinish(url: url)
        #expect(sut.didTerminate(currentURL: nil) == .load(url))
    }

    @Test
    func does_nothing_without_any_known_url() {
        var sut = WebProcessRecovery()
        #expect(sut.didTerminate(currentURL: nil) == .none)
    }
}
