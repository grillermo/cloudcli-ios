import Foundation

public enum AppScheme {
    public static let scheme = "cloudcli"
    public static let host = "app"
    public static let root = URL(string: "cloudcli://app/")!
    public static let server = URL(string: "https://claude.chiq.me")!
    public static let bridgeName = "cloudcliBridge"
}
