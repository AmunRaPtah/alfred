import Foundation
import UserNotifications
import UIKit
import Observation

/// Authorization + APNs device-token registration (brief part 3). Registers
/// with alfredd on every launch so a reinstalled server or rotated token
/// always converges; the hex token and registered flag are cached so
/// Settings can show state without a round trip.
@Observable
@MainActor
final class PushManager {
    static let shared = PushManager()

    private static let bundleId = "org.zyco.alfred"
    private static let tokenKey = "alfred.push.deviceTokenHex"
    private static let registeredKey = "alfred.push.registered"

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var deviceTokenHex: String? {
        didSet { UserDefaults.standard.set(deviceTokenHex, forKey: Self.tokenKey) }
    }
    private(set) var isRegistered: Bool {
        didSet { UserDefaults.standard.set(isRegistered, forKey: Self.registeredKey) }
    }

    private init() {
        deviceTokenHex = UserDefaults.standard.string(forKey: Self.tokenKey)
        isRegistered = UserDefaults.standard.bool(forKey: Self.registeredKey)
    }

    /// Call at first launch and whenever Settings needs a fresh read of permission state.
    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Requests permission (first launch) and, if granted, triggers remote registration.
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            await refreshAuthorizationStatus()
        }
    }

    /// Re-registers on every launch per the brief, even if the token hasn't changed,
    /// since alfredd may have been reinstalled and lost its device list.
    func didReceiveDeviceToken(_ data: Data, config: ServerConfig) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        deviceTokenHex = hex
        Task { await register(hex, config: config) }
    }

    func registerIfPossible(config: ServerConfig) {
        guard let hex = deviceTokenHex else { return }
        Task { await register(hex, config: config) }
    }

    private func register(_ hex: String, config: ServerConfig) async {
        guard config.isConfigured else { return }
        do {
            try await APIClient(config: config).registerDevice(token: hex, env: "production", bundleId: Self.bundleId)
            isRegistered = true
        } catch {
            isRegistered = false
        }
    }
}
