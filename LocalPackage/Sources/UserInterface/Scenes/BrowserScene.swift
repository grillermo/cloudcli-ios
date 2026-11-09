import Model
import SwiftUI

public struct BrowserScene: Scene {
    @Environment(\.appDependencies) private var appDependencies
    private let services = AppServices.shared

    public init() {}

    public var body: some Scene {
        WindowGroup {
            BrowserView(store: .init(appDependencies, isPresentedToolbar: false), services: services)
        }
    }
}
