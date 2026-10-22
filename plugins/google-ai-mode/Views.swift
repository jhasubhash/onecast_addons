import AppKit
import OnecastPluginKit
import SwiftUI
import WebKit

/// The scaffold's footer height: the page stops above it, so the footer never covers Google's input.
private let footerClearance: CGFloat = 52

// MARK: - Launcher surface

struct PaletteSurface: View {
    let start: StartAction

    @State private var navigator = PluginNavigator()
    @State private var openID: UUID?
    @State private var signingIn = false
    @State private var query = ""
    @State private var selection = 0
    @State private var didStart = false
    @FocusState private var fieldFocused: Bool

    private var store: ThreadStore { .shared }
    private var registry: WebViewRegistry { .shared }

    var body: some View {
        PluginScaffold(
            navigator: navigator,
            primaryActionLabel: primaryLabel,
            commands: commands,
            commandTitle: { commandTitle },
            listKey: handleListKey,
            escape: handleEscape,
            route: route,
            footer: .standard
        ) {
            content
        }
        .task {
            guard !didStart else { return }
            didStart = true
            switch start {
            case .home: break
            case .ask(let question): ask(question)
            case .open(let id): if store.thread(id) != nil { openID = id }
            }
            if onHome { await focusField() }
        }
    }

    private var onHome: Bool { openID == nil && !signingIn }

    @ViewBuilder private var content: some View {
        if signingIn {
            SignInPane(done: finishSignIn)
        } else if let id = openID, let thread = store.thread(id) {
            ThreadPane(thread: thread, back: goHome)
        } else {
            HomePane(
                query: $query, selection: selection, rows: rows, fieldFocused: $fieldFocused,
                activate: activate)
        }
    }

    // MARK: Rows

    enum Row: Identifiable, Equatable {
        case ask(String)
        case thread(AIThread)

        var id: String {
            switch self {
            case .ask: "ask"
            case .thread(let thread): thread.id.uuidString
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var rows: [Row] {
        let needle = trimmedQuery.lowercased()
        let threads = needle.isEmpty
            ? store.listed : store.listed.filter { $0.title.lowercased().contains(needle) }
        return (needle.isEmpty ? [] : [.ask(trimmedQuery)]) + threads.map(Row.thread)
    }

    private var selectedRow: Row? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    private var selectedThread: AIThread? {
        if let id = openID { return store.thread(id) }
        if case .thread(let thread) = selectedRow { return thread }
        return nil
    }

    private func activate(_ row: Row) {
        switch row {
        case .ask(let question): ask(question)
        case .thread(let thread): openID = thread.id
        }
    }

    private func ask(_ question: String) {
        let thread = store.start(question)
        query = ""
        selection = 0
        openID = thread.id
    }

    private func goHome() {
        if let id = openID, store.thread(id)?.isBlank == true { store.delete(id) }
        openID = nil
        selection = 0
        Task { await focusField() }
    }

    private func focusField() async {
        try? await Task.sleep(for: .milliseconds(120))
        fieldFocused = true
    }

    private func finishSignIn() {
        signingIn = false
        registry.closeSignIn()
        registry.reloadAll()
        Task { await focusField() }
    }

    // MARK: Scaffold hooks

    private var primaryLabel: String {
        guard onHome else { return "" }
        return switch selectedRow {
        case .ask: "Ask Google"
        case .thread: "Open"
        case nil: ""
        }
    }

    private var commandTitle: String? {
        if signingIn { return "Google account" }
        return selectedThread?.title
    }

    private func handleListKey(_ key: PluginListKey) -> Bool {
        guard onHome else { return false }
        let count = rows.count
        switch key {
        case .down:
            guard count > 0 else { return false }
            selection = min(selection + 1, count - 1)
        case .up:
            guard count > 0 else { return false }
            selection = max(selection - 1, 0)
        case .submit:
            guard let row = selectedRow else { return false }
            activate(row)
        case .left, .right:
            return false
        @unknown default:
            return false
        }
        return true
    }

    private func handleEscape() -> Bool {
        if signingIn {
            finishSignIn()
            return true
        }
        if openID != nil {
            goHome()
            return true
        }
        guard !query.isEmpty else { return false }
        query = ""
        selection = 0
        return true
    }

    private func route() -> PluginRoute? {
        guard !signingIn, let thread = selectedThread else { return nil }
        return PluginRoute(
            payload: [RouteKey.thread: thread.id.uuidString], title: thread.title,
            subtitle: "Google AI Mode", icon: .symbol("sparkle.magnifyingglass"))
    }

    private func commands() -> [PluginCommand] {
        var rows: [PluginCommand] = []
        if let thread = selectedThread {
            if openID == nil {
                rows.append(
                    PluginCommand(
                        title: "Open Thread", icon: .symbol("bubble.left.and.text.bubble.right"),
                        action: { openID = thread.id }))
                rows.append(contentsOf: linkCommands(thread))
            } else {
                rows.append(contentsOf: conversationCommands(thread))
            }
            rows.append(PluginCommand.mainMenuSlot())
            if openID == nil {
                rows.append(
                    PluginCommand(
                        title: "Delete Thread", icon: .symbol("trash"),
                        action: {
                            store.delete(thread.id)
                            selection = 0
                        }))
            }
        }
        if openID != nil {
            rows.append(
                PluginCommand(
                    title: "Back to Threads", icon: .symbol("list.bullet"), action: { goHome() }))
        }
        if !store.listed.isEmpty, onHome {
            rows.append(
                PluginCommand(
                    title: "Delete All Threads", icon: .symbol("trash.slash"),
                    action: {
                        store.deleteAll()
                        selection = 0
                    }))
        }
        rows.append(
            PluginCommand(
                title: "Sign In to Google", subtitle: "Keeps your AI Mode history in your account",
                icon: .symbol("person.crop.circle"),
                action: {
                    openID = nil
                    signingIn = true
                }))
        rows.append(
            PluginCommand(
                title: "Sign Out and Clear Google Data", icon: .symbol("person.crop.circle.badge.xmark"),
                action: { Task { await registry.signOut() } }))
        return rows
    }
}

/// What a conversation's ⌘K offers, in the launcher and in a pop-out alike.
@MainActor
func conversationCommands(_ thread: AIThread) -> [PluginCommand] {
    guard !thread.isBlank else { return [] }
    return [
        PluginCommand(
            title: "Clear Conversation", subtitle: "Start over here with a new question",
            icon: .symbol("eraser"),
            action: { ThreadStore.shared.clear(thread.id) }),
        PluginCommand(
            title: "Reload", icon: .symbol("arrow.clockwise"),
            action: { WebViewRegistry.shared.page(for: thread).webView.reload() }),
    ] + linkCommands(thread)
}

@MainActor
func linkCommands(_ thread: AIThread) -> [PluginCommand] {
    guard let url = ThreadStore.shared.thread(thread.id)?.url else { return [] }
    return [
        PluginCommand(
            title: "Open in Browser", icon: .symbol("safari"),
            action: { NSWorkspace.shared.open(url) }),
        PluginCommand(
            title: "Copy Link", icon: .symbol("link"),
            action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }),
    ]
}

// MARK: - Home

private struct HomePane: View {
    @Binding var query: String
    let selection: Int
    let rows: [PaletteSurface.Row]
    var fieldFocused: FocusState<Bool>.Binding
    let activate: (PaletteSurface.Row) -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.5)
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Ask Google AI Mode…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused(fieldFocused)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("Ask anything")
                .font(.title3.weight(.semibold))
            Text(
                "Google's AI Mode answers here, and you can keep the conversation going.\n"
                    + "Threads stay listed so you can come back to them."
            )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 52)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        RowView(row: row, selected: index == selection)
                            .id(row.id)
                            .onTapGesture { activate(row) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .contentMargins(.bottom, 52, for: .scrollContent)
            .onChange(of: selection) {
                guard rows.indices.contains(selection) else { return }
                proxy.scrollTo(rows[selection].id)
            }
        }
    }
}

private struct RowView: View {
    let row: PaletteSurface.Row
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.10) : .clear))
    }

    private var symbol: String {
        switch row {
        case .ask: "sparkle.magnifyingglass"
        case .thread: "bubble.left.and.text.bubble.right"
        }
    }

    private var title: String {
        switch row {
        case .ask(let question): "Ask Google: \(question)"
        case .thread(let thread): thread.title
        }
    }

    private var trailing: String? {
        guard case .thread(let thread) = row else { return nil }
        return thread.updated.formatted(.relative(presentation: .named))
    }
}

// MARK: - Thread

private struct ThreadPane: View {
    let thread: AIThread
    let back: () -> Void

    private var registry: WebViewRegistry { .shared }

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeader(thread: thread, back: back)
            if registry.windowed.contains(thread.id) {
                windowedNotice
            } else if thread.isBlank {
                BlankConversation(threadID: thread.id)
                    .padding(.bottom, footerClearance)
            } else {
                PageView(page: registry.page(for: thread))
                    .padding(.bottom, footerClearance)
            }
        }
    }

    private var windowedNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("This thread is open in its own window.")
                .font(.headline)
            Text("Close that window to continue it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThreadHeader: View {
    let thread: AIThread
    var back: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let back {
                HeaderButton(symbol: "chevron.left", help: "Back to threads  ⎋", action: back)
            }
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.secondary)
            Text(thread.title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if !thread.isBlank {
                HeaderButton(symbol: "arrow.clockwise", help: "Reload") {
                    WebViewRegistry.shared.page(for: thread).webView.reload()
                }
                if let url = thread.url {
                    HeaderButton(symbol: "safari", help: "Open in Browser") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(0.09) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: - Sign in

private struct SignInPane: View {
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
                Text("Sign in to Google")
                    .font(.headline)
                Spacer()
                Button("Done", action: done)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            WebViewHost(webView: WebViewRegistry.shared.signIn().webView)
                .padding(.bottom, footerClearance)
        }
    }
}

// MARK: - Pop-out window

struct ThreadWindowView: View {
    let threadID: UUID

    private var registry: WebViewRegistry { .shared }

    var body: some View {
        Group {
            if let thread = ThreadStore.shared.thread(threadID) {
                VStack(spacing: 0) {
                    ThreadHeader(thread: thread)
                    Group {
                        if thread.isBlank {
                            BlankConversation(threadID: thread.id)
                        } else {
                            PageView(page: registry.page(for: thread))
                        }
                    }
                    // The window's own ⌘K chip floats bottom-right, over Google's input otherwise.
                    .padding(.bottom, 44)
                }
                .pluginWindowCommands {
                    ThreadStore.shared.thread(threadID).map(conversationCommands) ?? []
                }
            } else {
                Text("This thread was deleted.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { registry.setWindowed(threadID, true) }
        .onDisappear { registry.setWindowed(threadID, false) }
    }
}

/// A cleared conversation: an empty space and a field for the next question, asked in place.
private struct BlankConversation: View {
    let threadID: UUID
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Ask Google AI Mode…", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(ask)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
            .frame(maxWidth: 520)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .milliseconds(120))
            focused = true
        }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        ThreadStore.shared.ask(text, in: threadID)
    }
}

/// A thread's page, with a spinner in its place until the page has been fitted to the launcher.
private struct PageView: View {
    let page: ThreadPage

    var body: some View {
        WebViewHost(webView: page.webView)
            .overlay {
                if !page.status.styled {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
    }
}
