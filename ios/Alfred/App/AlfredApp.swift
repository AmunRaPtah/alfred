import UIKit
import SwiftUI

@main
struct AlfredApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @State private var push = PushManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("alfred.push.requestedAuthorization") private var requestedAuthorization = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(AlfredPalette.brass)
                .onOpenURL { FileInbox.shared.receive($0) }
                .task { await onLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await onForeground() } }
                }
        }
    }

    private func onLaunch() async {
        if !requestedAuthorization {
            requestedAuthorization = true
            await push.requestAuthorization()
        } else {
            await push.refreshAuthorizationStatus()
            push.registerIfPossible(config: store.config)
            // APNs tokens can change (restore, reinstall); Apple says to ask on every launch.
            if push.authorizationStatus == .authorized { UIApplication.shared.registerForRemoteNotifications() }
        }
        await ReminderSync.sync(config: store.config)
    }

    private func onForeground() async {
        await push.refreshAuthorizationStatus()
        push.registerIfPossible(config: store.config)
        await ReminderSync.sync(config: store.config)
        await store.refresh()
    }
}
