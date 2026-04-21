import SwiftUI
import SwiftData

struct MenuBarContent: View {
    let openMainWindow: () -> Void
    @State private var engine = RotationEngine.shared

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
            }

            Divider()

            Button("Rotate now", systemImage: "forward.end") {
                Task { await engine.rotateNow() }
            }
            .buttonStyle(.borderless)

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
