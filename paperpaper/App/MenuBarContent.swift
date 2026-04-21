import SwiftUI

struct MenuBarContent: View {
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.gray)
                    .frame(width: 8, height: 8)
                Text("paperpaper")
                    .font(.headline)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("No wallpaper set")
                    .font(.subheadline)
                Text("Rotation paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Next", systemImage: "forward.end") {}
                .buttonStyle(.borderless)
            Button("Previous", systemImage: "backward.end") {}
                .buttonStyle(.borderless)
            Button("Pause", systemImage: "pause") {}
                .buttonStyle(.borderless)

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
