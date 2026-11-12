import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Alfred's own composer: a single quiet line, brass send button, attachments
/// as capsule chips above. Distinct from Helm's ComposerView in layout and
/// palette, though the upload/photo/file plumbing underneath is the same.
struct AlfredComposer: View {
    @Bindable var model: ChatModel
    var onVoice: () -> Void = {}

    @State private var showFiles = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
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
                Menu {
                    Button { showPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                    Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(AlfredPalette.mist)
                        .background(AlfredPalette.surface.opacity(0.8), in: Circle())
                        .overlay(Circle().strokeBorder(AlfredPalette.hairline, lineWidth: 0.75))
                }
                .disabled(model.isExited)
                .accessibilityLabel("Attach")

                TextField("", text: $model.draft, prompt: Text(placeholder).foregroundStyle(AlfredPalette.mist), axis: .vertical)
                    .font(AlfredFont.body)
                    .foregroundStyle(AlfredPalette.parchment)
                    .lineLimit(1...8)
                    // A leading "/" is a command: keep the keyboard from
                    // turning /context into /Context or "correcting" it.
                    .textInputAutocapitalization(model.draft.hasPrefix("/") ? .never : .sentences)
                    .autocorrectionDisabled(model.draft.hasPrefix("/"))
                    .focused($focused)
                    .tint(AlfredPalette.brass)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .frame(minHeight: 38)
                    .background(AlfredPalette.night.opacity(0.85), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(AlfredPalette.brass.opacity(focused ? 0.45 : 0.16), lineWidth: focused ? 1 : 0.75)
                    )
                    .animation(AlfredMotion.fade, value: focused)
                    .disabled(model.isExited)

                actionButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(AlfredPalette.midnight.opacity(0.62))
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(AlfredPalette.hairline).frame(height: 0.5)
        }
        .environment(\.colorScheme, .dark)
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 4, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for item in items { Task { await upload(item) } }
        }
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
                                .background(AlfredPalette.surface.opacity(0.9), in: Capsule())
                                .overlay(Capsule().strokeBorder(AlfredPalette.hairline, lineWidth: 0.75))
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
            ZStack {
                if model.canSend {
                    sendButton
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    voiceButton
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
        }
        .animation(AlfredMotion.spring, value: model.canSend)
        .animation(AlfredMotion.spring, value: model.isRunning)
    }

    private var voiceButton: some View {
        Button {
            Haptics.tap()
            onVoice()
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(AlfredPalette.brass)
                .background(AlfredPalette.surface.opacity(0.8), in: Circle())
                .overlay(Circle().strokeBorder(AlfredPalette.hairline, lineWidth: 0.75))
        }
        .disabled(model.isExited)
        .accessibilityLabel("Voice conversation")
    }

    private var stopButton: some View {
        Button {
            Task { await model.interrupt() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 36, height: 36)
                .background(AlfredPalette.caution.opacity(0.9), in: Circle())
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
                .frame(width: 36, height: 36)
                .foregroundStyle(AlfredPalette.midnight)
                .background(AlfredPalette.brassGradient, in: Circle())
                .shadow(color: AlfredPalette.brass.opacity(0.35), radius: 8, x: 0, y: 2)
        }
        .disabled(!model.canSend)
        .accessibilityLabel(model.isRunning ? "Add to queue" : "Send")
    }

    private func upload(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            model.banner = "Couldn't load that photo."
            return
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        if let jpeg = ImageEncoding.jpeg(from: data) {
            await model.upload(data: jpeg, filename: "photo-\(stamp).jpg", mimeType: "image/jpeg")
        } else {
            await model.upload(data: data, filename: "file-\(stamp)", mimeType: "application/octet-stream")
        }
    }
}

enum ImageEncoding {
    /// Re-encode (HEIC etc.) as JPEG, capped at 2048px on the long side.
    static func jpeg(from data: Data, maxSide: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.85)
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
        .background(AlfredPalette.surface.opacity(0.9), in: Capsule())
        .overlay(Capsule().strokeBorder(AlfredPalette.hairline, lineWidth: 0.75))
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }
}
