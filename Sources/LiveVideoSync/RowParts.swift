import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Общие части экранов сет-листа и плейлиста Extras — одна копия, чтобы правка не забывалась во второй

/// Верх экрана: баннеры, превью, Now Playing
struct ShowTop: View {
    @ObservedObject var show: Show

    var body: some View {
        Banners(show: show)
            .padding(.horizontal, 24)
            .padding(.top, 12)
        HStack(alignment: .top, spacing: 24) {
            PreviewPanel(show: show)
                .frame(maxWidth: 620)
            NowPlayingPanel(show: show)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

/// Файлы, перетащенные в список (onInsert)
func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for p in providers {
        if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
    }
    return urls
}

/// Название строки; Return или Rename — поле ввода (меняется только отображаемое имя, файл — нет)
struct InlineRename: View {
    let id: UUID
    let name: String
    let color: Color
    @Binding var renaming: UUID?
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        if renaming == id {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .frame(maxWidth: 360)
                .onAppear {
                    draft = name
                    editing = true
                }
                .onSubmit(finish)
                .onExitCommand { renaming = nil }
                .onChange(of: editing) { _, focused in if !focused { finish() } }
        } else {
            Text(name)
                .lineLimit(1)
                .foregroundStyle(color)
        }
    }

    private func finish() {
        guard renaming == id else { return }
        commit(draft)
        renaming = nil
    }
}

/// «•••» у строки: видно только при наведении
struct RowMenuButton<Content: View>: View {
    let visible: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .opacity(visible ? 1 : 0)
        .frame(width: 24)
    }
}

/// Наведение на строку; окно стало неактивным — сбросить (иначе «•••» залипает)
struct RowHover: ViewModifier {
    @Binding var hovering: Bool
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onChange(of: activeState) { _, state in if state != .key { hovering = false } }
    }
}
