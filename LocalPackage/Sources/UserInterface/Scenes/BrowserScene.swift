import Model
import SwiftUI

public struct BrowserScene: Scene {
    @Environment(\.appDependencies) private var appDependencies
    @State private var services = AppServices.live()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            BrowserView(store: .init(appDependencies, isPresentedToolbar: false), services: services)
        }
    }
}
