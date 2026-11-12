import SwiftUI

/// Alfred's front door: a greeting in his own voice, then what needs the
/// owner's attention, a couple of quick actions, and a short look at what's
/// coming up. Nothing here resembles Helm's sessions list; Today is new
/// information architecture, not a renamed view.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @State private var nav = Navigator.shared
    @State private var log = NotificationLog.shared
    @State private var reminders: [Reminder] = []
    @State private var loadingReminders = false
    @State private var pendingDrafts = 0
    @State private var ruleDrawn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    greeting
                    attention
                        .alfredEntrance(delay: 0.18)
                    quickActions
                        .alfredEntrance(delay: 0.28)
                    upcoming
                        .alfredEntrance(delay: 0.38)
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(AlfredBackground())
            .refreshable { await loadAll() }
            .navigationTitle("Today")
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await loadAll() }
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .alfredEntrance(rise: 6)
            Text(daypart.greeting)
                .font(AlfredFont.greeting)
                .tracking(0.4)
                .foregroundStyle(AlfredPalette.parchment)
                .alfredEntrance(delay: 0.05, rise: 14)
            Capsule()
                .fill(AlfredPalette.brassRule)
                .frame(width: ruleDrawn ? 72 : 0, height: 1.5)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
                .onAppear {
                    withAnimation(reduceMotion ? nil : AlfredMotion.spring.delay(0.2)) { ruleDrawn = true }
                }
            Text(daypart.line)
                .font(AlfredFont.voice(17))
                .italic()
                .foregroundStyle(AlfredPalette.mist)
                .alfredEntrance(delay: 0.12, rise: 10)
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Needs attention

    private var running: [Session] {
        store.sessions.filter { $0.state == .running || $0.state == .starting }
            .sorted { $0.updatedDate > $1.updatedDate }
    }

    private var recentNotices: [NotificationEntry] {
        let dayAgo = Date().addingTimeInterval(-86400)
        return Array(log.entries.filter { $0.receivedAt > dayAgo }.prefix(2))
    }

    private var attention: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Needs your attention")
            if pendingDrafts == 0 && running.isEmpty && recentNotices.isEmpty {
                ButlerCard {
                    HStack(spacing: 14) {
                        ClocheMark(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("All is in order.")
                                .font(AlfredFont.voice(18))
                                .foregroundStyle(AlfredPalette.parchment)
                            Text("Nothing awaits you.")
                                .font(AlfredFont.caption)
                                .foregroundStyle(AlfredPalette.mist)
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    if pendingDrafts > 0 {
                        NavigationLink {
                            OutboxView()
                        } label: {
                            AttentionRow(icon: "envelope.badge", tone: AlfredPalette.caution,
                                         title: pendingDrafts == 1 ? "A draft awaits your approval" : "\(pendingDrafts) drafts await your approval",
                                         detail: "Nothing is sent until you say so")
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                    }
                    ForEach(running.prefix(2)) { s in
                        Button {
                            Haptics.tap()
                            nav.openSession(s.id)
                        } label: {
                            AttentionRow(icon: "ellipsis.bubble", tone: AlfredPalette.signal,
                                         title: "At work on \u{201C}\(s.displayTitle)\u{201D}",
                                         detail: "Updated \(RelativeTime.string(s.updatedDate))")
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(recentNotices) { entry in
                        Button {
                            Haptics.tap()
                            if let sid = entry.sessionId { nav.openSession(sid) } else { nav.selectedTab = .inbox }
                        } label: {
                            AttentionRow(icon: "bell", tone: AlfredPalette.brass,
                                         title: entry.title.isEmpty ? "A note from Alfred" : entry.title,
                                         detail: entry.body.isEmpty ? RelativeTime.string(entry.receivedAt) : entry.body)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Quick actions

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(daypart.sectionLabel)
            HStack(spacing: 10) {
                Button {
                    Haptics.tap()
                    nav.selectedTab = .askAlfred
                } label: {
                    QuickActionTile(icon: "quote.bubble", title: "Ask Alfred", subtitle: "Continue where you left off")
                }
                .buttonStyle(PressableStyle())

                Button {
                    Haptics.tap()
                    Task { _ = await store.startNewPrimary() }
                    nav.selectedTab = .askAlfred
                } label: {
                    QuickActionTile(icon: "square.and.pencil", title: "Start fresh", subtitle: "A new conversation")
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: Coming up

    @ViewBuilder
    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Coming up")
            if loadingReminders && reminders.isEmpty {
                ButlerCard {
                    HStack(spacing: 10) {
                        BrassDots(size: 6)
                        Text("Consulting the diary\u{2026}")
                            .font(AlfredFont.voice(15))
                            .italic()
                            .foregroundStyle(AlfredPalette.mist)
                    }
                }
            } else if reminders.isEmpty {
                ButlerCard {
                    Text("Nothing on the books. A rare quiet stretch.")
                        .font(AlfredFont.voice(16))
                        .foregroundStyle(AlfredPalette.mist)
                }
            } else {
                ButlerCard(padding: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        let shown = Array(reminders.prefix(4))
                        ForEach(shown) { r in
                            ReminderRow(reminder: r)
                            if r.id != shown.last?.id {
                                Rectangle()
                                    .fill(AlfredPalette.brass.opacity(0.12))
                                    .frame(height: 0.5)
                                    .padding(.leading, 72)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func loadAll() async {
        await loadDrafts()
        await loadReminders()
        await store.refresh()
    }

    private func loadReminders() async {
        guard store.config.isConfigured else { return }
        loadingReminders = true
        defer { loadingReminders = false }
        if let r = try? await store.api.reminders() {
            withAnimation(AlfredMotion.fade) {
                reminders = r.filter { $0.fireAt > Date() }.sorted { $0.fireAt < $1.fireAt }
            }
        }
    }

    private func loadDrafts() async {
        guard store.config.isConfigured else { return }
        if let items = try? await store.api.outbox(status: "pending") {
            withAnimation(AlfredMotion.fade) { pendingDrafts = items.count }
        }
    }

    // MARK: Time of day

    private var daypart: Daypart { Daypart(hour: Calendar.current.component(.hour, from: Date())) }
}

private struct Daypart {
    let greeting: String
    let line: String
    let sectionLabel: String

    init(hour: Int) {
        switch hour {
        case 0..<5:
            greeting = "Still up?"
            line = "The house is quiet. I'm here if you need me."
            sectionLabel = "In the small hours"
        case 5..<12:
            greeting = "Good morning."
            line = "The day is yours. Here is where things stand."
            sectionLabel = "This morning"
        case 12..<17:
            greeting = "Good afternoon."
            line = "All in hand. Here is what's afoot."
            sectionLabel = "This afternoon"
        case 17..<22:
            greeting = "Good evening."
            line = "Let us see what remains of the day."
            sectionLabel = "This evening"
        default:
            greeting = "Good night."
            line = "Anything before you turn in?"
            sectionLabel = "Tonight"
        }
    }
}

private struct AttentionRow: View {
    let icon: String
    let tone: Color
    let title: String
    let detail: String

    var body: some View {
        ButlerCard(padding: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(tone.opacity(0.14))
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tone)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AlfredFont.ui(15, weight: .semibold))
                        .foregroundStyle(AlfredPalette.parchment)
                        .lineLimit(2)
                    Text(detail)
                        .font(AlfredFont.caption)
                        .foregroundStyle(AlfredPalette.mist)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AlfredPalette.mist.opacity(0.7))
            }
        }
    }
}

private struct QuickActionTile: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        ButlerCard {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(AlfredPalette.brassGradient)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AlfredFont.voice(17, weight: .medium))
                        .foregroundStyle(AlfredPalette.parchment)
                    Text(subtitle)
                        .font(AlfredFont.caption)
                        .foregroundStyle(AlfredPalette.mist)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct ReminderRow: View {
    let reminder: Reminder

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 1) {
                Text(reminder.fireAt.formatted(.dateTime.day()))
                    .font(AlfredFont.voice(20, weight: .medium))
                    .foregroundStyle(AlfredPalette.parchment)
                Text(reminder.fireAt.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(AlfredFont.label)
                    .tracking(1.2)
                    .foregroundStyle(AlfredPalette.brass)
            }
            .frame(width: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title.isEmpty ? "Reminder" : reminder.title)
                    .font(AlfredFont.ui(15, weight: .medium))
                    .foregroundStyle(AlfredPalette.parchment)
                    .lineLimit(2)
                Text(reminder.fireAt.formatted(.dateTime.weekday(.wide).hour().minute()))
                    .font(AlfredFont.caption)
                    .foregroundStyle(AlfredPalette.mist)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}

/// A gentle press: a slight settle and dim, no bounce.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(AlfredMotion.quick, value: configuration.isPressed)
    }
}
