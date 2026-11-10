import DataSource
import Foundation
import Observation
import UIKit
import WebKit

@MainActor
private final class ScriptBridge: NSObject, WKScriptMessageHandler {
    private let onReady: @MainActor (String?) -> Void

    init(onReady: @escaping @MainActor (String?) -> Void) {
        self.onReady = onReady
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        // A page that reports which build it is lets the updater ignore a late signal from a page
        // that outlived a switch. Pages that do not report one are matched to the active build.
        guard let ready = NativeBridgeSupport.parseReady(
            body: message.body,
            isMainFrame: message.frameInfo.isMainFrame,
            scheme: origin.protocol,
            host: origin.host
        ) else { return }
        onReady(ready.buildID)
    }
}

@MainActor @Observable public final class AppServices {
    public let updater: BuildUpdater
    public let dictation: DictationController
    public let credentials = MemaCredentialStore()
    public let memaLinks: MemaLinkImport
    public let webViewConfiguration: WKWebViewConfiguration

    /// One instance per process: it owns the build store, the recorder and the web view configuration.
    public static let shared = AppServices(webViewProxyClient: AppDependencies.shared.webViewProxyClient)

    public init(webViewProxyClient: WebViewProxyClient) {
        let support = URL.applicationSupportDirectory
        let location = BuildLocation()
        let store = BuildStore(root: support.appending(path: "WebBuilds")) { path in
            var request = URLRequest(url: AppScheme.server.appending(path: path))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            return try await URLSession.shared.data(for: request).0
        }
        let updater = BuildUpdater(store: store, location: location, fetchManifest: { try await BuildManifest.fetch() })
        self.updater = updater

        let credentialStore = credentials
        memaLinks = MemaLinkImport(save: { credentialStore.save($0) })
        dictation = DictationController(
            recorder: DictationRecorder(),
            store: PendingRecordingStore(root: support.appending(path: "Recordings")),
            client: .live,
            credentials: { credentialStore.load() },
            insert: { text in
                // Only the app's own page may receive dictated text; anything else falls back to the clipboard.
                guard NativeBridgeSupport.isAppPage(await webViewProxyClient.url()),
                      let script = NativeBridgeSupport.insertScript(for: text) else { return false }
                return await webViewProxyClient.evaluateJavaScript(script)
            },
            send: {
                guard NativeBridgeSupport.isAppPage(await webViewProxyClient.url()) else { return }
                _ = await webViewProxyClient.evaluateJavaScript(
                    "window.__nativeDictation ? window.__nativeDictation.send() : false"
                )
            },
            copy: { UIPasteboard.general.string = $0 }
        )

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsInlinePredictions = true
        configuration.applicationNameForUserAgent = "Safari/604.1"
        configuration.setURLSchemeHandler(AppSchemeHandler(location: location), forURLScheme: AppScheme.scheme)
        configuration.userContentController.addUserScript(WKUserScript(
            source: ServerOriginShim.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController.add(
            ScriptBridge(onReady: { buildID in updater.pageReady(buildID: buildID) }),
            name: AppScheme.bridgeName
        )
        webViewConfiguration = configuration
    }
}
