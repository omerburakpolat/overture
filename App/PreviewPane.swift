import SwiftUI
import WebKit
import OvertureDesign
import OvertureKit

/// The embedded preview (spec 02 §9): the card's dev server runs in ITS
/// worktree (so you test the branch's code), pointed at by a WKWebView.
struct PreviewTab: View {
    @Environment(AppState.self) private var appState
    let card: Card
    let store: BoardStore
    @State private var handle: DevServerManager.ServerHandle?
    @State private var starting = false
    @State private var failure: String?
    @State private var console: [String] = []
    @State private var showConsole = false
    @State private var reloadToken = 0

    private var serverKey: UUID {
        // Worktree cards get their own server; single-dir shares per project.
        card.worktreePath != nil ? card.id : store.project.id
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showConsole {
                consoleStrip
            }
        }
        .background(DS.Color.Surface.sunken)
        .task(id: card.id) {
            handle = await appState.devServers.handle(for: serverKey)
        }
        .onDisappear {
            // Linger policy: server keeps running briefly for tab switches;
            // stopped explicitly or at quit.
        }
    }

    @ViewBuilder private var content: some View {
        if let handle {
            WebView(url: handle.url, reloadToken: reloadToken)
        } else if starting {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Starting \(store.project.devServerCommand ?? "dev server")…")
            }
        } else if store.project.devServerCommand == nil {
            ContentUnavailableView {
                Label("No dev server configured", systemImage: DS.Icon.preview)
            } description: {
                Text("Set the run command in Project Settings — use {port} "
                     + "where the port goes, e.g. npm run dev -- --port {port}")
            }
        } else {
            ContentUnavailableView {
                Label("Preview this card's code", systemImage: DS.Icon.preview)
            } description: {
                if let failure {
                    Text(failure)
                } else if card.worktreePath != nil {
                    Text("Runs the dev server inside this card's worktree.")
                } else {
                    Text("Runs the project's dev server.")
                }
            } actions: {
                Button("Start server") { startServer() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: DS.Space.s300) {
            if let handle {
                Circle().fill(DS.Status.success.dot)
                    .frame(width: DS.Layout.statusDot,
                           height: DS.Layout.statusDot)
                    .accessibilityLabel("Server running")
                Text(handle.url.absoluteString)
                    .font(DS.TypeStyle.code)
                    .foregroundStyle(DS.Color.Text.secondary)
                    .textSelection(.enabled)
                Button {
                    reloadToken += 1
                } label: {
                    Image(systemName: DS.Icon.reload)
                }
                .buttonStyle(.plain)
                .help("Reload")
                .accessibilityLabel("Reload")
                Button {
                    NSWorkspace.shared.open(handle.url)
                } label: {
                    Image(systemName: DS.Icon.openInBrowser)
                }
                .buttonStyle(.plain)
                .help("Open in browser")
                .accessibilityLabel("Open in browser")
                Spacer()
                Button("Stop") {
                    Task {
                        await appState.devServers.stop(key: serverKey)
                        self.handle = nil
                    }
                }
                .help("Stop the dev server")
            } else {
                Text(card.worktreePath != nil
                     ? "Serving from this card's worktree"
                     : "Serving from the project directory")
                    .font(DS.TypeStyle.cardMeta)
                    .foregroundStyle(DS.Color.Text.tertiary)
                Spacer()
            }
            Button {
                showConsole.toggle()
                if showConsole { refreshConsole() }
            } label: {
                Image(systemName: DS.Icon.terminal)
            }
            .buttonStyle(.plain)
            .help("Server console")
            .accessibilityLabel("Server console")
            .accessibilityAddTraits(showConsole ? .isSelected : [])
        }
        .padding(DS.Space.s300)
        .background(DS.Color.Surface.raised)
    }

    private var consoleStrip: some View {
        ScrollView {
            Text(console.joined(separator: "\n"))
                .font(DS.TypeStyle.code)
                .foregroundStyle(DS.Color.Text.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.s200)
        }
        .frame(height: DS.Layout.consoleHeight)
        .background(DS.Color.Surface.canvas)
        .task {
            while showConsole, !Task.isCancelled {
                refreshConsole()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func startServer() {
        guard let template = store.project.devServerCommand else { return }
        starting = true
        failure = nil
        let directory = URL(fileURLWithPath:
            card.worktreePath ?? store.project.path)
        let basePort = store.project.devServerPort ?? 3000
        Task {
            defer { starting = false }
            do {
                handle = try await appState.devServers.start(
                    key: serverKey, commandTemplate: template,
                    basePort: basePort, directory: directory)
            } catch let error as DevServerManager.ServerError {
                if case .neverBecameReady(let tail) = error {
                    failure = "Server never became ready. Last output:\n"
                        + tail.suffix(5).joined(separator: "\n")
                } else {
                    failure = "\(error)"
                }
            } catch {
                failure = "\(error)"
            }
        }
    }

    private func refreshConsole() {
        Task {
            console = await appState.devServers.consoleTail(key: serverKey)
        }
    }
}

/// Non-persistent WKWebView (fresh data store per pane, inspectable).
struct WebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isInspectable = true
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastURL != url {
            context.coordinator.lastURL = url
            view.load(URLRequest(url: url))
        } else if context.coordinator.lastReload != reloadToken {
            context.coordinator.lastReload = reloadToken
            view.reload()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(lastURL: url)
    }

    final class Coordinator {
        var lastURL: URL
        var lastReload = 0
        init(lastURL: URL) { self.lastURL = lastURL }
    }
}
