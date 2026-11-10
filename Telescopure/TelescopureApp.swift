/*
 TelescopureApp.swift
 Telescopure

 Created by Takuto Nakamura on 2023/10/19.
*/

import Model
import SwiftUI
import UIKit
import UserInterface

@main
struct TelescopureApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        BrowserScene()
    }
}

/// Registers the "Install Latest" Home Screen quick action (only present in
/// builds made by ./deploy) and routes scene events to `AppQuickActionSceneDelegate`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.shortcutItems = AppQuickAction.available(infoDictionary: Bundle.main.infoDictionary).map {
            UIApplicationShortcutItem(
                type: $0.rawValue,
                localizedTitle: "Install Latest",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.app")
            )
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role
        )
        if connectingSceneSession.role == .windowApplication {
            configuration.delegateClass = AppQuickActionSceneDelegate.self
        }
        return configuration
    }
}
