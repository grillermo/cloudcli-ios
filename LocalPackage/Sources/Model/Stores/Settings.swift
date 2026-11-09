import Foundation
import DataSource
import Observation
import UIKit

@MainActor @Observable public final class Settings: Identifiable, Composable {
    private let uiApplicationClient: UIApplicationClient
    private let wkWebsiteDataStoreClient: WKWebsiteDataStoreClient
    private let userDefaultsRepository: UserDefaultsRepository
    private let logService: LogService

    public let id: UUID
    public var path: [Path]
    public var version: String
    public let developer = "Takuto Nakamura"
    public let action: (Action) async -> Void

    public init(
        _ appDependencies: AppDependencies,
        id: UUID,
        path: [Path] = [],
        version: String? = nil,
        action: @escaping (Action) async -> Void
    ) {
        self.uiApplicationClient = appDependencies.uiApplicationClient
        self.wkWebsiteDataStoreClient = appDependencies.wkWebsiteDataStoreClient
        self.userDefaultsRepository = .init(appDependencies.userDefaultsClient)
        self.logService = .init(appDependencies)
        self.id = id
        self.path = path
        self.version = version ?? Bundle.main.bundleVersion
        self.action = action
    }

    public func reduce(_ action: Action) async {
        switch action {
        case let .task(screenName):
            logService.notice(.screenView(name: screenName))

        case .crearCacheButtonTapped:
            let dataTypes = wkWebsiteDataStoreClient.allWebsiteDataTypes()
            let records = await wkWebsiteDataStoreClient.dataRecords(dataTypes)
            await wkWebsiteDataStoreClient.removeData(dataTypes, records)

        case .openRepositoryButtonTapped:
            guard let url = URL(string: "https://github.com/Kyome22/Telescopure") else { return }
            _ = await uiApplicationClient.open(url)

        case let .licensesButtonTapped(appDependencies):
            path.append(.licenses(.init(appDependencies)))

        case .doneButtonTapped:
            break
        }
    }

    public enum Action: Sendable {
        case task(String)
        case crearCacheButtonTapped
        case openRepositoryButtonTapped
        case licensesButtonTapped(AppDependencies)
        case doneButtonTapped
    }

    public enum Path: Hashable {
        case licenses(Licenses)

        public static func ==(lhs: Path, rhs: Path) -> Bool {
            lhs.id == rhs.id
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        var id: Int {
            switch self {
            case let .licenses(value):
                Int(bitPattern: ObjectIdentifier(value))
            }
        }
    }
}
