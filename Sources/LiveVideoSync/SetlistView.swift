import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Открытый сет: превью и Now Playing сверху, сет-лист снизу
struct SetlistDetail: View {
    @ObservedObject var show: Show
    @ObservedObject var ui: UIState
    let setlistID: UUID
    let search: String

    var body: some View {
        if let setlist = show.setlist(setlistID) {
            VStack(alignment: .leading, spacing: 0) {
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
                SetlistHeader(show: show, setlist: setlist)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                // Список сжимается и прокручивается — иначе он распирает окно и верх уезжает за край
                TrackList(show: show, setlist: setlist, search: search)
                    .frame(minHeight: 120, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct SetlistHeader: View {
    @ObservedObject var show: Show
    let setlist: Setlist

    var body: some View {
        let isActive = setlist.id == show.settings.activeSetlist
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(setlist.name)
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                if isActive {
                    Text("Active")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .help("This setlist plays when Logic sends timecode and marker notes")
                } else {
                    Button("Make Active") { show.makeActive(setlist.id) }
                        .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
            Text(subtitle(isActive: isActive))
                .foregroundStyle(.secondary)
            if !isActive, let active = show.settings.active {
                Text("\(active.name) is playing now. Make Active switches the show to this setlist.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// «12 songs · 52 min · Show Videos»
    private func subtitle(isActive: Bool) -> String {
        let count = setlist.items.count
        var parts = ["\(count) \(count == 1 ? "song" : "songs")"]
        let total = show.totalDuration(setlist)
        if total > 0 { parts.append("\(Int((total / 60).rounded())) min") }
        let folders = Set(setlist.items.map { $0.url.deletingLastPathComponent().lastPathComponent })
        if folders.count == 1, let folder = folders.first { parts.append(folder) }
        if !isActive { parts.append("not active") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Список песен

private struct TrackList: View {
    @ObservedObject var show: Show
    let setlist: Setlist
    let search: String
    @State private var selection = Set<UUID>()
    @State private var renaming: UUID?
    @State private var trimming: SetlistItem?
    @State private var missing: SetlistItem?
    @State private var problem: (item: SetlistItem, text: String)?

    private var isActive: Bool { setlist.id == show.settings.activeSetlist }
    private var filtered: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private var rows: [(number: Int, item: SetlistItem)] {
        let all = setlist.items.enumerated().map { ($0.offset + 1, $0.element) }
        guard filtered else { return all }
        return all.filter { $0.1.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if setlist.items.isEmpty {
                ContentUnavailableView {
                    Label("No Songs", systemImage: "film.stack")
                } description: {
                    Text("Drag song videos here. The order is the order of marker notes:\nsong 1 = \(Show.noteName(show.settings.markerBaseNote)), song 2 = \(Show.noteName(show.settings.markerBaseNote + 1)) …")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .dropDestination(for: URL.self) { urls, _ in
                    show.addFiles(urls, to: setlist.id)
                    return true
                }
            } else {
                list
            }
        }
        .alert("The original file could not be found", isPresented: Binding(get: { missing != nil }, set: { if !$0 { missing = nil } })) {
            Button("Locate…") { if let m = missing { show.replaceFile(m.id, in: setlist.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let m = missing, let n = setlist.items.firstIndex(of: m) {
                Text("“\(m.url.lastPathComponent)” was moved, renamed or deleted. Locate it to keep song \(n + 1) in the setlist.")
            }
        }
        .alert("File problem", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("Replace File…") { if let p = problem { show.replaceFile(p.item.id, in: setlist.id) } }
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem?.text ?? "")
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(rows, id: \.item.id) { row in
                TrackRow(show: show, setlist: setlist, item: row.item, number: row.number,
                         isActiveSet: isActive, renaming: $renaming, trimming: $trimming,
                         onProblem: { item, info in
                             if info.missing { missing = item } else if let text = info.problem { problem = (item, text) }
                         })
                .tag(row.item.id)
            }
            .onMove(perform: filtered ? nil : { from, to in show.moveItems(in: setlist.id, from: from, to: to) })
            .onInsert(of: [.fileURL]) { index, providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for p in providers {
                        if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                           let u = URL(dataRepresentation: url, relativeTo: nil) { urls.append(u) }
                    }
                    show.addFiles(urls, to: setlist.id, at: index)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first, let item = setlist.items.first(where: { $0.id == id }) {
                ItemMenu(show: show, setlist: setlist, item: item, renaming: $renaming, trimming: $trimming)
            } else if !ids.isEmpty {
                Button("Remove from Setlist", role: .destructive) { show.removeItems(ids, from: setlist.id) }
            }
        } primaryAction: { ids in
            // Двойной щелчок — ручной запуск (аварийный режим), только в активном сете
            guard isActive, ids.count == 1, let item = setlist.items.first(where: { $0.id == ids.first }) else { return }
            show.playManually(item)
        }
        .onKeyPress(.return) {
            guard renaming == nil, selection.count == 1 else { return .ignored }
            renaming = selection.first
            return .handled
        }
        .onDeleteCommand {
            show.removeItems(selection, from: setlist.id)
            selection = []
        }
        .sheet(item: $trimming) { item in
            if let info = show.info(item), info.duration > 0,
               let n = setlist.items.firstIndex(where: { $0.id == item.id }) {
                TrimView(item: item, number: n + 1, fullDuration: info.duration) { start, end in
                    show.setTrim(item.id, in: setlist.id, start: start, end: end)
                }
            }
        }
    }
}

/// Меню «•••» и правый щелчок — одно и то же
private struct ItemMenu: View {
    @ObservedObject var show: Show
    let setlist: Setlist
    let item: SetlistItem
    @Binding var renaming: UUID?
    @Binding var trimming: SetlistItem?

    var body: some View {
        Button("Rename") { renaming = item.id }
        Button("Trim…") { trimming = item }
            .disabled(show.info(item).map { !$0.playable || $0.isImage } ?? true)
        Menu("Move to Position") {
            ForEach(Array(setlist.items.indices), id: \.self) { i in
                let label = "\(i + 1) · \(Show.noteName(show.settings.markerBaseNote + i))"
                if setlist.items[i].id == item.id {
                    Button { } label: { Label(label, systemImage: "checkmark") }
                } else {
                    Button(label) { show.moveItem(item.id, in: setlist.id, toPosition: i + 1) }
                }
            }
        }
        Divider()
        Button("Replace File…") { show.replaceFile(item.id, in: setlist.id) }
        Button("Reset Marker") { show.resetMarker(item.id, in: setlist.id) }
            .disabled(item.marker == nil)
        Button("Show in Finder") { show.showInFinder(item) }
            .disabled(show.info(item)?.missing == true)
        Divider()
        Button("Remove from Setlist", role: .destructive) { show.removeItems([item.id], from: setlist.id) }
    }
}

private struct TrackRow: View {
    @ObservedObject var show: Show
    let setlist: Setlist
    let item: SetlistItem
    let number: Int
    let isActiveSet: Bool
    @Binding var renaming: UUID?
    @Binding var trimming: SetlistItem?
    let onProblem: (SetlistItem, MediaInfo) -> Void

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var info: MediaInfo? { show.info(item) }
    private var isPlaying: Bool { isActiveSet && show.nowPlaying.itemID == item.id }
    private var onAir: Bool { isPlaying && show.settings.live }

    var body: some View {
        HStack(spacing: 8) {
            problemIcon
                .frame(width: 18)
            leading
                .frame(width: 28, alignment: .trailing)
            title
            Spacer(minLength: 12)
            markerBadge
                .frame(width: 52, alignment: .leading)
            Text(show.duration(item).map(Show.minutes) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            menuButton
                .frame(width: 24)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var problemIcon: some View {
        if let info, info.problem != nil {
            Button { onProblem(item, info) } label: {
                Image(systemName: "exclamationmark.triangle")
                    .fontWeight(.light)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(info.problem ?? "")
        }
    }

    /// Номер; у играющей — плёнка; при наведении в активном сете — ▶
    @ViewBuilder
    private var leading: some View {
        if isPlaying {
            FilmIcon(running: show.settings.live)
                .foregroundStyle(onAir ? .red : .secondary)
        } else if hovering, isActiveSet, info?.playable == true {
            Button { show.playManually(item) } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .help("Play now (manual) — plays to the end, then the logo")
        } else {
            Text("\(number)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var title: some View {
        if renaming == item.id {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($editing)
                .frame(maxWidth: 360)
                .onAppear {
                    draft = item.displayName
                    editing = true
                }
                .onSubmit { commit() }
                .onExitCommand { renaming = nil }
                .onChange(of: editing) { _, focused in if !focused { commit() } }
        } else {
            Text(item.displayName)
                .lineLimit(1)
                .foregroundStyle(onAir ? .red : info?.missing == true ? .secondary : .primary)
        }
    }

    private func commit() {
        guard renaming == item.id else { return }
        show.renameItem(item.id, in: setlist.id, to: draft)
        renaming = nil
    }

    /// Нота-метка: отдельная колонка, все плашки ровно друг под другом
    private var markerBadge: some View {
        let learned = item.marker != nil
        return Text(Show.noteName(show.settings.markerBaseNote + number - 1))
            .font(.caption2.weight(.medium).monospacedDigit())
            .foregroundStyle(learned ? .secondary : .tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary.opacity(learned ? 1 : 0.5)))
            .help(learned
                  ? "Marker note. Learned: the song starts at \(Timecode(realSeconds: item.marker!, rate: show.director.clock.rate).text) in Logic."
                  : "Marker note. Not learned yet — play this song from its start in Logic once.")
    }

    @ViewBuilder
    private var menuButton: some View {
        Menu {
            ItemMenu(show: show, setlist: setlist, item: item, renaming: $renaming, trimming: $trimming)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .opacity(hovering ? 1 : 0)
    }
}

/// Значок плёнки, по которому бегут кадры (играющая песня)
private struct FilmIcon: View {
    let running: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !running)) { context in
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let frame = CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
                ctx.stroke(Path(roundedRect: frame, cornerRadius: 2), with: .foreground, lineWidth: 1.2)
                // Перфорация сверху и снизу бежит влево
                let step: CGFloat = 4
                let t = running ? context.date.timeIntervalSinceReferenceDate : 0
                let shift = CGFloat((t * 12).truncatingRemainder(dividingBy: Double(step)))
                var x = 2 - shift
                while x < w - 2 {
                    if x > 1.5 {
                        ctx.fill(Path(CGRect(x: x, y: 2, width: 2, height: 2)), with: .foreground)
                        ctx.fill(Path(CGRect(x: x, y: h - 4, width: 2, height: 2)), with: .foreground)
                    }
                    x += step
                }
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 1, y: 5)); p.addLine(to: CGPoint(x: w - 1, y: 5))
                    p.move(to: CGPoint(x: 1, y: h - 5)); p.addLine(to: CGPoint(x: w - 1, y: h - 5))
                }, with: .foreground, lineWidth: 0.8)
            }
        }
        .frame(width: 22, height: 15)
    }
}
