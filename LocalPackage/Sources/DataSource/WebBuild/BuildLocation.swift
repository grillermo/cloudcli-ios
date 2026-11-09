import Foundation
import os

public final class BuildLocation: Sendable {
    private let directory = OSAllocatedUnfairLock<URL?>(initialState: nil)

    public init() {}

    public var current: URL? {
        get { directory.withLock(\.self) }
        set { directory.withLock { $0 = newValue } }
    }
}
