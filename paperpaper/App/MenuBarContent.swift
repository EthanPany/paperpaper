import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct MenuBarContent: View {
    let openMainWindow: () -> Void
    @State private var engine = RotationEngine.shared
    @State private var applier = WallpaperApplier.shared
    @State private var ollamaReachable: Bool? = nil
    /// Tick when the widget payload file changes — the popover redraws so
    /// the preview thumbnail and title reflect the most recent rotation.
    @State private var paintTick: Int = 0

    private var currentPayload: WidgetPayload? { WidgetPayload.read() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isRunning ? Color.green : (engine.lastError == nil ? Color.gray : Color.red))
                    .frame(width: 8, height: 8)
                Text("paperpaper")
                    .font(.headline)
                Spacer()
            }

            // Wallpaper preview thumbnail with title + location overlaid at
            // the bottom — mirrors the in-app NowView card so the popover
            // reads at a glance.
            WallpaperPreview(payload: currentPayload)
                .id(paintTick)

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
            .onAppear { paintTick &+= 1 }

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

            Button {
                Task { await WallpaperApplier.shared.regenerateMostRecent() }
            } label: {
                HStack(spacing: 6) {
                    if applier.isEnriching {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .tint(.secondary)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(applier.isEnriching ? "Generating AI info…" : "Regenerate AI info")
                        .foregroundStyle(applier.isEnriching ? .secondary : .primary)
                }
            }
            .buttonStyle(.borderless)
            .disabled(applier.isEnriching)
            .help("Re-run the architecture agent on the current photo. Forces a fresh Ollama call even if the photo was already enriched.")

            Button("Refresh widget", systemImage: "arrow.clockwise") {
                WallpaperApplier.shared.syncWidgetFromCurrent(forceReload: true)
                WallpaperApplier.shared.logWidgetPayloadForDiagnostics()
            }
            .buttonStyle(.borderless)
            .help("Rewrite the widget payload and force a reload. Check Console.app for `subsystem:me.ethanpan.paperpaper` to inspect.")

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
        .frame(width: 300)
    }
}

/// Compact image preview at the top of the menu bar popover. Falls back to a
/// neutral placeholder when no wallpaper has been applied yet so the layout
/// doesn't pop on first launch.
private struct WallpaperPreview: View {
    let payload: WidgetPayload?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let payload, let image = loadImage(payload) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.18, green: 0.20, blue: 0.28),
                        Color(red: 0.30, green: 0.24, blue: 0.20),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "photo")
                        .font(.system(size: 28, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            // Bottom gradient + title text — only render when we have a real
            // payload (otherwise there's nothing to label).
            if let payload {
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(payload.bestTitle)
                        .font(.system(.callout, design: .serif).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let footer = payload.bestFooter, !footer.isEmpty {
                        Text(footer)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func loadImage(_ payload: WidgetPayload) -> Image? {
        #if os(macOS)
        guard let url = payload.resolvedImageURL(),
              FileManager.default.fileExists(atPath: url.path),
              let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }
}

#Preview {
    MenuBarContent(openMainWindow: {})
}
