import SwiftUI

/// Alfred's front door: a greeting in his own voice, a couple of quick
/// actions, and a short look at what's coming up. Nothing here resembles
/// Helm's sessions list; Today is new information architecture, not a
/// renamed view.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @State private var nav = Navigator.shared
    @State private var reminders: [Reminder] = []
    @State private var loadingReminders = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    greeting
                    quickActions
                    upcoming
                }
                .padding(20)
            }
            .background(AlfredBackground())
            .navigationTitle("Today")
            .navigationBarTitleDisplayMode(.large)
        }
        .task { await loadReminders() }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(timeOfDayGreeting)
                .font(AlfredFont.title)
                .foregroundStyle(AlfredPalette.parchment)
            Text("At your service.")
                .font(AlfredFont.voice(16))
                .foregroundStyle(AlfredPalette.mist)
        }
    }

    private var timeOfDayGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<5: return "Still up"
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    private var quickActions: some View {
        VStack(spacing: 10) {
            Button {
                Haptics.tap()
                nav.selectedTab = .askAlfred
            } label: {
                QuickActionRow(icon: "quote.bubble", title: "Ask Alfred", subtitle: "Continue your conversation")
            }
            .buttonStyle(.plain)

            Button {
                Haptics.tap()
                Task { _ = await store.startNewPrimary() }
                nav.selectedTab = .askAlfred
            } label: {
                QuickActionRow(icon: "square.and.pencil", title: "Start fresh", subtitle: "Begin a new conversation")
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coming up")
                .font(AlfredFont.heading)
                .foregroundStyle(AlfredPalette.parchment)
            if loadingReminders && reminders.isEmpty {
                ProgressView().tint(AlfredPalette.brass)
            } else if reminders.isEmpty {
                ButlerCard { ButlerEmptyState(text: "Nothing on the books.") }
            } else {
                ButlerCard {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(reminders.prefix(3)) { r in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bell")
                                    .foregroundStyle(AlfredPalette.brass)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title.isEmpty ? "Reminder" : r.title)
                                        .font(AlfredFont.ui(14, weight: .medium))
                                        .foregroundStyle(AlfredPalette.parchment)
                                    Text(r.fireAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                        .font(AlfredFont.caption)
                                        .foregroundStyle(AlfredPalette.mist)
                                }
                            }
                            if r.id != reminders.prefix(3).last?.id {
                                Divider().overlay(AlfredPalette.brass.opacity(0.15))
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadReminders() async {
        guard store.config.isConfigured else { return }
        loadingReminders = true
        defer { loadingReminders = false }
        if let r = try? await store.api.reminders() {
            reminders = r.filter { $0.fireAt > Date() }.sorted { $0.fireAt < $1.fireAt }
        }
    }
}

private struct QuickActionRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        ButlerCard {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(AlfredPalette.brass)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AlfredFont.ui(16, weight: .semibold)).foregroundStyle(AlfredPalette.parchment)
                    Text(subtitle).font(AlfredFont.caption).foregroundStyle(AlfredPalette.mist)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(AlfredPalette.mist)
            }
        }
    }
}
