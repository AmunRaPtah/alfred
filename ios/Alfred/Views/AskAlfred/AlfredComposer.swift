import SwiftUI
import UniformTypeIdentifiers

/// Alfred's own composer: a single quiet line, brass send button, attachments
/// as capsule chips above. Distinct from Helm's ComposerView in layout and
/// palette, though the upload/photo/file plumbing underneath is the same.
struct AlfredComposer: View {
    @Bindable var model: ChatModel

    @State private var showFiles = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            commandHint
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.attachments) { a in
                            ErrandChip(attachment: a) { model.removeAttachment(a) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    showFiles = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(AlfredPalette.mist)
                        .background(AlfredPalette.slate.opacity(0.7), in: Circle())
                }
                .disabled(model.isExited)
                .accessibilityLabel("Attach a file")

                TextField("", text: $model.draft, prompt: Text(placeholder).foregroundStyle(AlfredPalette.mist), axis: .vertical)
                    .font(AlfredFont.body)
                    .foregroundStyle(AlfredPalette.parchment)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .frame(minHeight: 38)
                    .background(AlfredPalette.slate.opacity(0.7), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(AlfredPalette.brass.opacity(0.2)))
                    .disabled(model.isExited)

                actionButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(AlfredPalette.midnight.opacity(0.9))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    guard let f = PickedFile.load(url) else { model.banner = "Couldn't read \(url.lastPathComponent)."; continue }
                    Task { await model.upload(data: f.data, filename: f.filename, mimeType: f.mimeType) }
                }
            case .failure(let e):
                model.banner = e.localizedDescription
            }
        }
    }

    private var placeholder: String {
        model.isExited ? "This conversation has ended" : model.isRunning ? "Add to the queue\u{2026}" : "Tell Alfred what you need"
    }

    @ViewBuilder
    private var commandHint: some View {
        let d = model.draft
        if d.hasPrefix("/"), !d.contains(" "), !matches.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(matches, id: \.self) { c in
                        Button {
                            model.draft = "/\(c) "
                            Haptics.tap()
                        } label: {
                            Text("/\(c)")
                                .font(.caption.monospaced())
                                .foregroundStyle(AlfredPalette.parchment)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AlfredPalette.slate.opacity(0.8), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var matches: [String] {
        let q = model.draft.dropFirst().lowercased()
        let starts = model.commands.filter { $0.lowercased().hasPrefix(q) }
        let contains = q.isEmpty ? [] : model.commands.filter { !$0.lowercased().hasPrefix(q) && $0.lowercased().contains(q) }
        return Array((starts + contains).prefix(40))
    }

    @ViewBuilder
    private var actionButton: some View {
        HStack(spacing: 6) {
            if model.isRunning { stopButton }
            sendButton
        }
    }

    private var stopButton: some View {
        Button {
            Task { await model.interrupt() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .bold))
                .frame(width: 34, height: 34)
                .background(AlfredPalette.caution, in: Circle())
                .foregroundStyle(AlfredPalette.parchment)
        }
        .accessibilityLabel("Stop")
        .transition(.scale.combined(with: .opacity))
    }

    private var sendButton: some View {
        Button {
            Task { await model.send() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 34, height: 34)
                .background(model.canSend ? AlfredPalette.brass : AlfredPalette.slate.opacity(0.7), in: Circle())
                .foregroundStyle(model.canSend ? AlfredPalette.midnight : AlfredPalette.mist)
        }
        .disabled(!model.canSend)
        .accessibilityLabel(model.isRunning ? "Add to queue" : "Send")
    }
}

struct ErrandChip: View {
    let attachment: Attachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if attachment.isUploading {
                ProgressView().tint(AlfredPalette.brass).controlSize(.mini)
            } else if attachment.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AlfredPalette.caution)
            } else {
                Image(systemName: PickedFile.icon(for: attachment.filename)).foregroundStyle(AlfredPalette.brass)
            }
            Text(attachment.error ?? attachment.filename)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(AlfredPalette.mist)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attachment")
        }
        .font(AlfredFont.caption)
        .foregroundStyle(AlfredPalette.parchment)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AlfredPalette.slate.opacity(0.8), in: Capsule())
    }
}
