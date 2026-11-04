import SwiftUI

/// alfredd has no /harnesses to enumerate (Alfred is the only one), so this
/// is simpler than Helm's version: just /health.
enum ConnectionTest {
    enum State {
        case idle
        case running
        case success(version: String)
        case failure(step: String, message: String)
    }

    static func run(_ config: ServerConfig) async -> State {
        let api = APIClient(config: config)
        do {
            let h = try await api.health()
            if h["ok"]?.bool == false { return .failure(step: "/health", message: "alfredd reported not ok.") }
            return .success(version: h["version"]?.string ?? "?")
        } catch {
            return .failure(step: "/health", message: APIClient.describe(error))
        }
    }
}

struct ConnectionTestResult: View {
    let state: ConnectionTest.State

    var body: some View {
        switch state {
        case .idle, .running:
            EmptyView()
        case .success(let version):
            Label("Connected to alfredd v\(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(AlfredPalette.signal)
                .font(AlfredFont.ui(14, weight: .medium))
                .padding(.vertical, 2)
        case .failure(let step, let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(step) failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(AlfredPalette.caution)
                    .font(AlfredFont.ui(14, weight: .medium))
                Text(message).font(AlfredFont.caption).foregroundStyle(AlfredPalette.mist)
            }
            .padding(.vertical, 2)
        }
    }
}
