import DataSource
import Model
import SwiftUI
import WebUI

struct BrowserView: View {
    @Environment(\.browserToolbarLayout) private var browserToolbarLayout
    @StateObject var store: Browser
    let services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    // A notification tapped with the app closed arrives before any build has
    // loaded, and the first load of the root would otherwise replace it.
    @State private var pendingOpenURL: URL?

    private var ignoredContainerSafeAreaEdges: Edge.Set {
        if !store.isPresentedToolbar {
            .all
        } else if browserToolbarLayout == .verticalBar {
            .bottom
        } else {
            []
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            WebViewReader { proxy in
                NavigationStack {
                    VStack(spacing: 0) {
                        if store.isPresentedToolbar {
                            Header(store: store)
                                .transition(.move(edge: .top))
                                .environment(\.isLoading, proxy.isLoading)
                                .environment(\.estimatedProgress, proxy.estimatedProgress)
                        }
                        WebView(configuration: services.webViewConfiguration)
                            .navigationDelegate(store.navigationDelegate)
                            .uiDelegate(store.uiDelegate)
                            .refreshable()
                            .allowsBackForwardNavigationGestures(true)
                            .allowsOpaqueDrawing(proxy.url != nil)
                            .allowsInspectable(true)
                            .pageScaleFactor(store.pageScale.value)
                            .overlay {
                                if services.updater.needsFirstDownload {
                                    FirstDownloadView(isChecking: services.updater.isChecking) {
                                        Task { await services.updater.check() }
                                    }
                                } else if proxy.url == nil {
                                    LogoView()
                                }
                            }
                        if store.isPresentedToolbar, !browserToolbarLayout.usesSystemToolbar {
                            Footer(store: store)
                                .transition(.move(edge: .bottom))
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .ignoresSafeArea(.container, edges: ignoredContainerSafeAreaEdges)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .toolbarVisibility(.hidden, for: .navigationBar)
                    .toolbar {
                        if browserToolbarLayout.usesSystemToolbar {
                            ToolbarItemGroup(placement: .bottomBar) {
                                if store.isPresentedToolbar {
                                    BrowserNavigationButtons(store: store)
                                    Spacer()
                                    BrowserActionButtons(store: store)
                                } else {
                                    Spacer()
                                    ShowToolbarButton(store: store)
                                }
                            }
                        }
                    }
                    .environment(\.canGoBack, proxy.canGoBack)
                    .environment(\.canGoForward, proxy.canGoForward)
                }
                .task {
                    await store.send(.task(
                        String(describing: Self.self),
                        .init(getResourceURL: { Bundle.module.url(forResource: $0, withExtension: $1) }),
                        proxy
                    ))
                    services.dictation.loadPending()
                    await services.updater.launch()
                }
                .onChange(of: proxy.url) { _, newValue in
                    Task {
                        await store.send(.onChangeURL(newValue))
                    }
                }
                .onChange(of: services.updater.loadNonce) { _, _ in
                    proxy.load(request: URLRequest(url: AppScheme.root))
                    if let url = pendingOpenURL {
                        pendingOpenURL = nil
                        Task { await store.send(.onOpenURL(url)) }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        // A recording must not be lost when the app leaves the screen.
                        Task { await services.dictation.interrupted() }
                    } else if phase == .active {
                        Task { await services.updater.check() }
                    }
                }
                .onChange(of: proxy.title) { _, newValue in
                    Task {
                        await store.send(.onChangeTitle(newValue))
                    }
                }
            }
            if !store.isPresentedToolbar, !browserToolbarLayout.usesSystemToolbar {
                FloatingShowToolbarButton(store: store)
                    .padding(20)
                    .transition(.move(edge: .bottom))
            }
        }
        .ignoresSafeArea(.container, edges: store.isPresentedToolbar || browserToolbarLayout.usesSystemToolbar ? [] : .all)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay {
            WrapperOverlay(services: services, isToolbarVisible: store.isPresentedToolbar)
        }
        .sheet(item: $store.settings) { store in
            SettingsView(store: store)
        }
        .webDialog(
            isPresented: $store.isPresentedWebDialog,
            presenting: store.webDialog,
            promptInput: $store.promptInput,
            okButtonTapped: { await store.send(.dialogOKButtonTapped) },
            cancelButtonTapped: { await store.send(.dialogCancelButtonTapped) },
            onChangeIsPresented: { await store.send(.onChangeIsPresentedWebDialog($0)) }
        )
        .externalAppConfirmationDialog(
            isPresented: $store.isPresentedConfirmationDialog,
            presenting: store.customSchemeURL,
            okButtonTapped: { await store.send(.confirmButtonTapped($0)) }
        )
        .alert(
            Text("failedToOpenExternalApp", bundle: .module),
            isPresented: $store.isPresentedAlert,
            actions: {}
        )
        .onOpenURL { url in
            // Credentials links are confirmed with the user and never reach the web view.
            if services.memaLinks.handle(url) { return }
            if services.updater.loadNonce == 0 {
                pendingOpenURL = url
                return
            }
            Task {
                await store.send(.onOpenURL(url))
            }
        }
        .alert(
            services.memaLinks.confirmationTitle,
            isPresented: Bindable(services.memaLinks).isPresentedConfirmation
        ) {
            Button("Cancel", role: .cancel) { services.memaLinks.cancel() }
            Button("Save") { services.memaLinks.confirm() }
        } message: {
            Text(services.memaLinks.confirmationMessage)
        }
        .alert(
            "Dictation link",
            isPresented: Bindable(services.memaLinks).isPresentedError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(services.memaLinks.errorMessage ?? "")
        }
        .animation(.easeIn(duration: 0.2), value: store.isPresentedToolbar)
    }
}

extension Browser: ObservableObject {}
extension BrowserNavigation: ObservableObject {}
extension BrowserUI: ObservableObject {}

#Preview(traits: .landscapeRight) {
    BrowserView(store: .init(.testDependencies()), services: AppServices(webViewProxyClient: .testValue))
}
