import SwiftUI

struct DiscoverView: View {
    @AppStorage("agent.enabled") private var agentEnabled: Bool = false
    @State private var query: String = "architecture"
    @State private var agentPrompt: String = ""
    @State private var agentLocation: String = ""
    @State private var results: [UnsplashPhoto] = []
    @State private var isLoading: Bool = false
    @State private var error: String?
    @State private var selected: UnsplashPhoto?
    @State private var agentSteps: [String] = []
    @State private var agentParagraph: String?

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search Unsplash", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button {
                    Task { await search() }
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(.glassProminent)
                .tint(.accentColor)
                .disabled(query.isEmpty)
                Button {
                    Task { await shuffle() }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.glass)
            }
            .padding()

            if agentEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("Smart search (prompt)", text: $agentPrompt)
                            .textFieldStyle(.roundedBorder)
                        TextField("Location (optional)", text: $agentLocation)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                        Button {
                            Task { await smartSearch() }
                        } label: {
                            Label("Run", systemImage: "sparkles")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.purple)
                        .disabled(agentPrompt.isEmpty)
                    }
                    if !agentSteps.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(0..<agentSteps.count, id: \.self) { i in
                                Text(agentSteps[i])
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if let para = agentParagraph {
                        Text(para)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            if isLoading && results.isEmpty {
                ContentUnavailableView {
                    Label("Searching Unsplash…", systemImage: "sparkles")
                } description: {
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView(
                    "Try a search",
                    systemImage: "magnifyingglass",
                    description: Text("Results from Unsplash will appear here. Set your key in Connections first.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(results) { photo in
                            DiscoverTile(photo: photo) {
                                selected = photo
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $selected) { photo in
            DiscoverDetail(photo: photo)
        }
    }

    private func search() async {
        isLoading = true
        error = nil
        do {
            let result = try await UnsplashService.shared.search(query: query, page: 1, perPage: 24)
            results = result.results
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results = []
        }
        isLoading = false
    }

    private func shuffle() async {
        isLoading = true
        error = nil
        do {
            results = try await UnsplashService.shared.randomArchitecture(count: 24)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results = []
        }
        isLoading = false
    }

    private func smartSearch() async {
        isLoading = true
        error = nil
        agentSteps = []
        agentParagraph = nil
        do {
            let out = try await SearchAgent.shared.run(
                SearchAgent.Request(
                    prompt: agentPrompt,
                    location: agentLocation.isEmpty ? nil : agentLocation,
                    includeWebResearch: UserDefaults.standard.bool(forKey: "ollama.webSearch"),
                    includeParagraph: true
                )
            )
            results = [out.photo]
            agentSteps = out.broadeningSteps
            agentParagraph = out.paragraph
            selected = out.photo
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            results = []
        }
        isLoading = false
    }
}

private struct DiscoverTile: View {
    let photo: UnsplashPhoto
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: photo.urls.small) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        Color.gray.opacity(0.2)
                    case .empty:
                        Color.gray.opacity(0.1)
                            .overlay(ProgressView())
                    @unknown default:
                        Color.gray.opacity(0.1)
                    }
                }
                .aspectRatio(CGFloat(photo.width) / CGFloat(photo.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(photo.description ?? photo.alt_description ?? "Untitled")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(photo.user.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DiscoverDetail: View {
    let photo: UnsplashPhoto
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying: Bool = false
    @State private var applyError: String?

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    PhotoHero(photo: photo)
                        .padding(.horizontal, 40)
                        .padding(.top, 72)

                    VStack(alignment: .leading, spacing: 24) {
                        TitleBlock(photo: photo)
                        Divider().opacity(0.4)
                        MetadataBlock(photo: photo)
                        if let tags = photo.tags, !tags.isEmpty {
                            Divider().opacity(0.4)
                            TagBlock(tags: tags.map(\.title))
                        }
                        if let err = applyError {
                            Label(err, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 40)
                }
                .frame(maxWidth: .infinity)
            }

            VStack {
                HStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            Task { await apply() }
                        } label: {
                            Label(isApplying ? "Setting…" : "Set as wallpaper", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.glassProminent)
                        .tint(.accentColor)
                        .disabled(isApplying)
                        .keyboardShortcut(.defaultAction)

                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(18)
                }
                Spacer()
            }
        }
        .frame(minWidth: 860, minHeight: 720)
    }

    private func apply() async {
        isApplying = true
        applyError = nil
        do {
            _ = try await WallpaperApplier.shared.apply(unsplash: photo)
            dismiss()
        } catch {
            applyError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isApplying = false
    }
}

private struct PhotoHero: View {
    let photo: UnsplashPhoto

    var body: some View {
        AsyncImage(url: photo.urls.regular) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFit()
            case .failure:
                Color.gray.opacity(0.1)
            case .empty:
                Color.gray.opacity(0.1).overlay(ProgressView())
            @unknown default:
                Color.gray.opacity(0.1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 560)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 8)
    }
}

private struct TitleBlock: View {
    let photo: UnsplashPhoto

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(.largeTitle, design: .serif).weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(.callout, design: .default))
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        photo.description ?? photo.alt_description ?? photo.location?.name ?? "Untitled"
    }

    private var subtitle: String {
        let parts = [photo.location?.city, photo.location?.country].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}

private struct MetadataBlock: View {
    let photo: UnsplashPhoto

    var body: some View {
        VStack(spacing: 0) {
            MetadataRow(label: "Photographer", value: photo.user.name, link: photo.user.links?.html)
            MetadataRow(label: "Username", value: "@\(photo.user.username)", link: photo.user.links?.html, mono: true)
            if let exif = photo.exif {
                if let make = exif.make, let model = exif.model {
                    MetadataRow(label: "Camera", value: "\(make) \(model)")
                } else if let model = exif.model {
                    MetadataRow(label: "Camera", value: model)
                }
                if let name = exif.name, !name.isEmpty {
                    MetadataRow(label: "Lens", value: name)
                }
                MetadataRow(label: "Exposure", value: exposureLine(exif), mono: true)
                if let iso = exif.iso {
                    MetadataRow(label: "ISO", value: "\(iso)", mono: true)
                }
            }
            MetadataRow(label: "Dimensions", value: "\(photo.width) × \(photo.height)", mono: true)
            if let color = photo.color {
                MetadataRow(label: "Color", value: color.uppercased(), mono: true)
            }
            if let lat = photo.location?.position?.latitude, let lon = photo.location?.position?.longitude {
                MetadataRow(label: "GPS", value: String(format: "%.4f, %.4f", lat, lon), mono: true)
            }
            MetadataRow(label: "ID", value: photo.id, mono: true)
            MetadataRow(label: "License", value: "Unsplash")
        }
    }

    private func exposureLine(_ exif: UnsplashPhoto.Exif) -> String? {
        var bits: [String] = []
        if let f = exif.focal_length { bits.append("\(f)mm") }
        if let a = exif.aperture { bits.append("f/\(a)") }
        if let s = exif.exposure_time { bits.append("\(s)s") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String?
    var link: URL? = nil
    var mono: Bool = false

    var body: some View {
        if let value, !value.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Group {
                    if let link {
                        Link(destination: link) {
                            HStack(spacing: 4) {
                                Text(value)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2)
                            }
                        }
                    } else {
                        Text(value)
                    }
                }
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }
}

private struct TagBlock: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(tags.prefix(24), id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth {
                currentY += rowHeight + spacing
                currentX = 0
                rowHeight = 0
            }
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, currentX)
        }
        return CGSize(width: min(maxWidth, maxX), height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX {
                currentY += rowHeight + spacing
                currentX = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    DiscoverView()
        .frame(width: 900, height: 600)
}
