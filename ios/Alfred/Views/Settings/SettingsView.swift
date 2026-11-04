import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
    var isOnboarding = false

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var revealToken = false
    @State private var test = ConnectionTest.State.idle
    @State private var loaded = false
    @State private var certName: String? = ClientIdentity.installedName
    @State private var showImporter = false
    @State private var inbox = CertInbox.shared
    @State private var p12Password = ""
    @State private var certError: String?

    private var draft: ServerConfig { ServerConfig(urlString: url, token: token.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        Form {
            if isOnboarding {
                Section {
                    OnboardingHeader()
                }
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("http://10.66.66.1:3341", text: $url)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                HStack {
                    Group {
                        if revealToken {
                            TextField("Bearer token", text: $token)
                        } else {
                            SecureField("Bearer token", text: $token)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if token.isEmpty {
                        Button("Paste") {
                            if let s = UIPasteboard.general.string { token = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Over WireGuard: http://10.66.66.1:3341. Off WireGuard, use the https route plus the client certificate below. The token lives in the iOS Keychain, never on disk in plain text.")
            }

            Section {
                if let certName {
                    LabeledContent("Installed", value: certName)
                    Button("Remove certificate", role: .destructive) {
                        ClientIdentity.remove()
                        self.certName = nil
                    }
                } else if inbox.pending != nil {
                    SecureField("Certificate password", text: $p12Password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Import") { importPending() }
                        .disabled(p12Password.isEmpty)
                    Button("Cancel", role: .cancel) {
                        inbox.pending = nil
                        p12Password = ""
                    }
                } else {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import .p12 certificate", systemImage: "lock.shield")
                    }
                    Button {
                        certError = nil
                        if let text = UIPasteboard.general.string, let data = CertInbox.decodePasted(text) {
                            p12Password = ""
                            inbox.pending = data
                        } else {
                            certError = "Clipboard does not hold a base64 certificate."
                        }
                    } label: {
                        Label("Paste certificate text", systemImage: "doc.on.clipboard")
                    }
                }
                if let certError {
                    Text(certError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Client certificate")
            } footer: {
                Text("Required for the public https route, which rejects any device without it before alfredd is reached. Not needed over WireGuard.")
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if case .running = test { ProgressView() }
                    }
                }
                .disabled(draft.baseURL == nil || isTesting)
                ConnectionTestResult(state: test)
            }

            Section {
                Button(isOnboarding ? "Connect" : "Save") { save() }
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
                    .disabled(!draft.isConfigured)
            }

            if !isOnboarding {
                NotificationsSection()
                VoiceSection()
                Section {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    LabeledContent("Protocol", value: "v1")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AlfredBackground())
        .navigationTitle(isOnboarding ? "Welcome" : "Settings")
        .navigationBarTitleDisplayMode(isOnboarding ? .large : .inline)
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pkcs12, .data]) { result in
            certError = nil
            switch result {
            case .success(let fileURL):
                let scoped = fileURL.startAccessingSecurityScopedResource()
                defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: fileURL) {
                    p12Password = ""
                    inbox.pending = data
                } else {
                    certError = "Could not read that file."
                }
            case .failure(let error):
                certError = error.localizedDescription
            }
        }
        .onAppear {
            certName = ClientIdentity.installedName
            guard !loaded else { return }
            loaded = true
            url = store.config.urlString.isEmpty ? ServerConfig.defaultURL : store.config.urlString
            token = store.config.token
        }
    }

    private var isTesting: Bool { if case .running = test { return true }; return false }

    private func runTest() async {
        test = .running
        test = await ConnectionTest.run(draft)
        if case .success = test { Haptics.success() } else { Haptics.warning() }
    }

    private func importPending() {
        guard let data = inbox.pending else { return }
        inbox.pending = nil
        do {
            certName = try ClientIdentity.importP12(data, password: p12Password)
            certError = nil
            Haptics.success()
        } catch {
            certError = error.localizedDescription
            Haptics.warning()
        }
        p12Password = ""
    }

    private func save() {
        store.updateConfig(draft)
        Haptics.success()
        Task { await store.refresh() }
        if !isOnboarding { dismiss() }
    }
}

private struct OnboardingHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "suit.club.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(AlfredPalette.brass)
                .padding(.top, 8)
            Text("Alfred")
                .font(AlfredFont.voice(26, weight: .semibold))
            Text("Your own conversation with the harness running on your server. Enter the alfredd URL and token. Off WireGuard, use the https URL and import your client certificate.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Permission state, device-token-registered state, and alfredd's own push
/// configuration (brief part 5), plus a button to send a test push.
private struct NotificationsSection: View {
    @Environment(AppStore.self) private var store
    @State private var push = PushManager.shared
    @State private var status: PushStatus?
    @State private var statusError: String?
    @State private var sending = false
    @State private var sendResult: String?

    var body: some View {
        Section("Notifications") {
            LabeledContent("Permission", value: permissionLabel)
            LabeledContent("This device", value: push.isRegistered ? "Registered" : "Not registered")
            if let status {
                LabeledContent("alfredd push", value: status.configured ? "Configured" : "Not configured")
                LabeledContent("Devices registered", value: "\(status.devices)")
            } else if let statusError {
                Text(statusError).font(.footnote).foregroundStyle(.red)
            } else {
                ProgressView()
            }
            if push.authorizationStatus == .denied {
                Text("Notifications are off for Alfred in Settings > Notifications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if push.authorizationStatus == .notDetermined {
                Button("Enable notifications") { Task { await push.requestAuthorization() } }
            }
            Button {
                Task { await sendTestPush() }
            } label: {
                HStack {
                    Text("Send test push")
                    Spacer()
                    if sending { ProgressView() }
                }
            }
            .disabled(sending || !store.config.isConfigured)
            if let sendResult {
                Text(sendResult).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task {
            await push.refreshAuthorizationStatus()
            await loadStatus()
        }
    }

    private var permissionLabel: String {
        switch push.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked"
        @unknown default: return "Unknown"
        }
    }

    private func loadStatus() async {
        guard store.config.isConfigured else { return }
        do { status = try await store.api.pushStatus() }
        catch { statusError = APIClient.describe(error) }
    }

    private func sendTestPush() async {
        sending = true
        defer { sending = false }
        do {
            let r = try await store.api.sendPush(title: "Alfred", body: "This is a test notification.")
            sendResult = r.configured ? "Sent to \(r.sent) device(s)." : "alfredd has no push key configured."
        } catch {
            sendResult = APIClient.describe(error)
        }
    }
}

/// Voice mode preferences: synthesizer voice, speaking rate, and whether
/// listening resumes automatically once Alfred finishes speaking.
private struct VoiceSection: View {
    @State private var settings = VoiceSettings.shared
    @State private var voices = VoiceSettings.availableVoices()

    var body: some View {
        Section {
            Picker("Voice", selection: $settings.voiceIdentifier) {
                ForEach(voices, id: \.identifier) { v in
                    Text(voiceLabel(v)).tag(Optional(v.identifier))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Speaking rate")
                Slider(value: $settings.rate, in: 0.3...0.6)
            }
            Toggle("Resume listening automatically", isOn: $settings.autoListen)
        } header: {
            Text("Voice")
        } footer: {
            Text("Enhanced and premium voices, where installed, are listed first.")
        }
    }

    private func voiceLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .enhanced: return "\(v.name) (Enhanced)"
        case .premium: return "\(v.name) (Premium)"
        default: return v.name
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
