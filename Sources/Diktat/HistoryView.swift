import AppKit
import SwiftUI

private struct HistoryDay: Identifiable {
    let date: Date
    let entries: [HistoryEntry]
    var id: Date { date }
}

struct HistoryView: View {
    @ObservedObject var history: SessionHistory
    @ObservedObject var controller: SessionController
    @State private var selection: UUID?
    @State private var query = ""

    private var visible: [HistoryEntry] {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return history.entries }
        return history.entries.filter { entry in
            if entry.text.localizedCaseInsensitiveContains(words) { return true }
            if entry.original?.localizedCaseInsensitiveContains(words) == true { return true }
            if case .file(let name) = entry.source { return name.localizedCaseInsensitiveContains(words) }
            return false
        }
    }

    private var days: [HistoryDay] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { HistoryDay(date: $0, entries: grouped[$0] ?? []) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 300)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 440)
        .onAppear { selection = selection ?? history.entries.first?.id }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Søk i tekst", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Tøm søket")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            .padding(10)
            List(selection: $selection) {
                ForEach(days) { day in
                    Section(HistoryFormat.day(day.date)) {
                        ForEach(day.entries) { entry in
                            HistoryRow(entry: entry).tag(entry.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay { emptyList }
            Divider()
            HStack {
                Text(history.entries.count == 1 ? "1 økt" : "\(history.entries.count) økter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { NSWorkspace.shared.open(SessionHistory.directory) } label: {
                    Label("Vis mappen", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Vis mappen der øktene lagres")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var emptyList: some View {
        if history.entries.isEmpty {
            ContentUnavailableView("Ingen økter ennå", systemImage: "waveform",
                                   description: Text("Diktater og transkriberte lydfiler havner her."))
        } else if visible.isEmpty {
            ContentUnavailableView("Ingen treff", systemImage: "magnifyingglass",
                                   description: Text("Ingen økter inneholder «\(query)»."))
        }
    }

    @ViewBuilder private var detail: some View {
        if let entry = history.entries.first(where: { $0.id == selection }) {
            HistoryDetail(entry: entry, history: history, controller: controller) { delete(entry) }
        } else {
            ContentUnavailableView("Velg en økt", systemImage: "text.alignleft")
        }
    }

    private func delete(_ entry: HistoryEntry) {
        let list = visible
        if let index = list.firstIndex(of: entry) {
            let after = list.dropFirst(index + 1).first
            selection = (after ?? list.prefix(index).last)?.id
        }
        history.delete(entry.id)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(HistoryFormat.time(entry.startedAt))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let seconds = entry.seconds {
                    Text(HistoryFormat.duration(seconds)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let badge = HistoryFormat.badge(entry) {
                    Image(systemName: badge.symbol)
                        .font(.caption)
                        .foregroundStyle(badge.tint)
                        .help(badge.label)
                        .accessibilityLabel(badge.label)
                }
            }
            Text(preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        if !entry.text.isEmpty { return entry.text }
        if entry.status == .active { return "Lytter …" }
        return "Ingen tekst"
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    let history: SessionHistory
    @ObservedObject var controller: SessionController
    let onDelete: () -> Void
    @State private var confirmingDelete = false
    @State private var copied = false
    @State private var showOriginal = false

    private var audio: URL? { history.audioURL(for: entry) }
    private var shownText: String {
        if showOriginal, let original = entry.original { return original }
        return entry.text
    }
    private var canTranscribe: Bool { audio != nil && !controller.isBusy && entry.status != .active }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(HistoryFormat.title(entry.startedAt)).font(.title3.weight(.semibold))
                    Text(details).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                actions
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)
            if entry.original != nil {
                Picker("Tekst", selection: $showOriginal) {
                    Text("Ryddet").tag(false)
                    Text("Slik den ble diktert").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
            if let badge = HistoryFormat.badge(entry), let notice = HistoryFormat.notice(entry) {
                HStack(spacing: 10) {
                    Image(systemName: badge.symbol).foregroundStyle(badge.tint)
                    Text(notice).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if entry.status != .done, entry.status != .discarded, audio != nil {
                        Button("Transkriber lydopptaket") { controller.transcribe(entry) }
                            .disabled(!canTranscribe)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(badge.tint.opacity(0.12)))
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            }
            Divider()
            ScrollView {
                Text(shownText.isEmpty ? "Ingen tekst." : shownText)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundStyle(shownText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .confirmationDialog("Slette økten?", isPresented: $confirmingDelete) {
            Button("Slett", role: .destructive) { onDelete() }
        } message: {
            Text("Teksten og lydopptaket slettes fra denne Mac-en.")
        }
        .onChange(of: entry.id) {
            copied = false
            showOriginal = false
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            Button { copy() } label: { Label("Kopier teksten", systemImage: copied ? "checkmark" : "doc.on.doc") }
                .disabled(shownText.isEmpty)
                .help("Kopier teksten")
            if audio != nil {
                Button { controller.transcribe(entry) } label: {
                    Label("Transkriber lydopptaket på nytt", systemImage: "arrow.clockwise")
                }
                .disabled(!canTranscribe)
                .help("Transkriber lydopptaket på nytt som en ny økt")
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([history.folder(for: entry.id)]) } label: {
                Label("Vis i Finder", systemImage: "folder")
            }
            .help("Vis tekst og lyd i Finder")
            Button { confirmingDelete = true } label: { Label("Slett økten", systemImage: "trash") }
                .disabled(entry.status == .active)
                .help("Slett økten")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 14))
    }

    private var details: String {
        var parts: [String] = []
        if let seconds = entry.seconds { parts.append(HistoryFormat.duration(seconds)) }
        switch entry.source {
        case .microphone: break
        case .file(let name): parts.append("Lydfil: \(name)")
        case .retranscription(let id):
            if let original = history.entries.first(where: { $0.id == id }) {
                parts.append("Ny transkripsjon av opptaket fra \(HistoryFormat.title(original.startedAt).lowercased())")
            } else {
                parts.append("Ny transkripsjon av et slettet opptak")
            }
        }
        parts.append(entry.engine)
        parts.append(HistoryFormat.language(entry.locale))
        if let microphone = entry.microphone { parts.append(microphone) }
        return parts.joined(separator: " · ")
    }

    private func copy() {
        guard TextDelivery.copy(shownText) else { return }
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private enum HistoryFormat {
    private static let norwegian = Locale(identifier: "nb_NO")

    struct Badge {
        let symbol: String
        let tint: Color
        let label: String
    }

    static func badge(_ entry: HistoryEntry) -> Badge? {
        switch entry.status {
        case .active: return Badge(symbol: "record.circle", tint: .red, label: "Pågår")
        case .interrupted: return Badge(symbol: "exclamationmark.triangle.fill", tint: .orange, label: "Mikrofonen falt ut")
        case .failed: return Badge(symbol: "xmark.octagon.fill", tint: .red, label: "Feilet")
        case .discarded: return Badge(symbol: "trash", tint: .secondary, label: "Forkastet")
        case .unfinished: return Badge(symbol: "exclamationmark.arrow.circlepath", tint: .orange, label: "Ikke fullført")
        case .done: break
        }
        switch entry.source {
        case .microphone: return nil
        case .file: return Badge(symbol: "doc.text", tint: .secondary, label: "Lydfil")
        case .retranscription: return Badge(symbol: "arrow.clockwise", tint: .secondary, label: "Ny transkripsjon")
        }
    }

    static func notice(_ entry: HistoryEntry) -> String? {
        switch entry.status {
        case .done: return nil
        case .active: return "Økten pågår. Teksten lagres underveis."
        case .interrupted: return (entry.note ?? "Mikrofonen falt ut.") + " Teksten ble kopiert, ikke limt inn."
        case .failed: return entry.note ?? "Økten feilet."
        case .discarded: return "Forkastet. Teksten ble ikke kopiert."
        case .unfinished:
            let note = entry.note ?? "Økten ble ikke fullført."
            return note + " Teksten er lagret fram til da, og lydopptaket kan transkriberes på nytt."
        }
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "I dag" }
        if calendar.isDateInYesterday(date) { return "I går" }
        let style: Date.FormatStyle
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            style = .dateTime.weekday(.wide).day().month(.wide)
        } else {
            style = .dateTime.day().month(.wide).year()
        }
        let text = date.formatted(style.locale(norwegian))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(norwegian))
    }

    static func title(_ date: Date) -> String {
        "\(day(date)) kl. \(time(date))"
    }

    static func duration(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        if hours > 0 { return "\(hours) t \(minutes) min" }
        if minutes > 0 && rest > 0 { return "\(minutes) min \(rest) s" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(rest) s"
    }

    static func language(_ locale: String) -> String {
        locale == "nb-NO" ? "Norsk bokmål" : "English"
    }
}
