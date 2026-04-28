import SwiftUI
import SwiftData

struct MenuBarContent: View {
    let openMainWindow: () -> Void
    @State private var engine = RotationEngine.shared
    @State private var ollamaReachable: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isRunning ? Color.green : (engine.lastError == nil ? Color.gray : Color.red))
                    .frame(width: 8, height: 8)
                Text("paperpaper")
                    .font(.headline)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text(engine.isRunning ? "Rotation running" : "Rotation paused")
                    .font(.subheadline)
                if let next = engine.nextFireAt, engine.isRunning {
                    Text("Next at \(next.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = engine.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                // Ollama reachability — the architecture agent silently no-ops
                // when Ollama isn't running, which is the most common reason
                // for "the LLM info isn't updating." Surface it explicitly.
                HStack(spacing: 6) {
                    Circle()
                        .fill(ollamaReachable == true ? Color.green : (ollamaReachable == false ? Color.orange : Color.gray))
                        .frame(width: 6, height: 6)
                    Text(ollamaReachable == true ? "Ollama reachable"
                       : ollamaReachable == false ? "Ollama unreachable — set host in Connections"
                       : "Checking Ollama…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .task {
                    ollamaReachable = await OllamaService.shared.ping()
                }
            }

            Divider()

            Button("Rotate now", systemImage: "forward.end") {
                Task { await engine.rotateNow() }
            }
            .buttonStyle(.borderless)

            Button("Reapply wallpaper", systemImage: "arrow.uturn.down") {
                Task { await WallpaperApplier.shared.reapplyMostRecent() }
            }
            .buttonStyle(.borderless)
            .help("Re-set the macOS wallpaper from the most recent applied photo without rotating to a new one.")

            Button("Regenerate AI info", systemImage: "sparkles") {
                Task { await WallpaperApplier.shared.regenerateMostRecent() }
            }
            .buttonStyle(.borderless)
            .help("Re-run the architecture agent on the current photo. Forces a fresh Ollama call even if the photo was already enriched.")

            Button("Refresh widget", systemImage: "arrow.clockwise") {
                WallpaperApplier.shared.syncWidgetFromCurrent(forceReload: true)
                WallpaperApplier.shared.logWidgetPayloadForDiagnostics()
            }
            .buttonStyle(.borderless)
            .help("Rewrite the widget payload and force a reload. Check Console.app for `subsystem:ep.paperpaper` to inspect.")

            if engine.isRunning {
                Button("Pause", systemImage: "pause") {
                    let rule = Store.shared.rule()
                    rule.enabled = false
                    try? Store.shared.context.save()
                    engine.stop()
                }
                .buttonStyle(.borderless)
            } else {
                Button("Resume", systemImage: "play") {
                    let rule = Store.shared.rule()
                    rule.enabled = true
                    try? Store.shared.context.save()
                    engine.start()
                }
                .buttonStyle(.borderless)
            }

            Divider()

            Button("Open paperpaper…", systemImage: "macwindow") {
                openMainWindow()
            }
            .buttonStyle(.borderless)

            #if os(macOS)
            Button("Quit", systemImage: "power") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.borderless)
            #endif
        }
        .padding(14)
        .frame(width: 260)
    }
}

#Preview {
    MenuBarContent(openMainWindow: {})
}
