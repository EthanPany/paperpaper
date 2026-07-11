import SwiftUI
import SwiftData
import AppKit
import CoreImage

struct NowView: View {
    @Query(sort: \Photo.lastSeenAt, order: .reverse) private var seenPhotos: [Photo]
    // Subscribing to the Enrichment entity is the only way to make this view
    // re-render when an inverse-relationship Enrichment is inserted/updated
    // for an already-loaded Photo. Without it, the @Query above only fires
    // when Photo rows themselves change — adding an Enrichment with photo=…
    // doesn't bump the Photo, so PhotoMetadataCard would keep reading stale
    // (un-enriched) `photo.enrichment?.buildingName`.
    @Query private var enrichmentSubscription: [Enrichment]
    // Drives the first-run checklist's "rotation on" step — querying the rule
    // (rather than reading Store.shared.rule() once) makes the checkmark flip
    // live the moment rotation is enabled from anywhere.
    @Query private var rules: [RotationRule]
    @State private var engine = RotationEngine.shared
    @State private var applier = WallpaperApplier.shared
    /// Luminance (0..1) of the wallpaper region directly behind the metadata
    /// card. Computed off-main from the cached local image whenever `current`
    /// changes. Drives the card's light/dark glass + text colors.
    @State private var cardBackdropLuminance: Double = 0.2
    /// Pre-decoded wallpaper for the background, loaded off-main in the
    /// `.task(id:)` below. Decoding a multi-MB JPEG with `NSImage(contentsOf:)`
    /// directly in `body` ran file I/O + decode on the main actor on every
    /// render — a visible hitch on each rotation.
    @State private var backgroundImage: NSImage?
    @State private var backgroundImageID: String?

    private var current: Photo? {
        seenPhotos.first(where: { $0.lastSeenAt != nil })
    }

    private var isDarkBackdrop: Bool { cardBackdropLuminance < 0.5 }

    /// Whether an Unsplash Access Key is stored. Read live so the checklist's
    /// first step checks off as soon as the user saves a key in Connections
    /// and returns to this tab.
    private var hasUnsplashKey: Bool {
        (KeychainService.shared.get(.unsplashAccessKey)?.isEmpty == false)
    }

    /// Turn on automatic rotation from the checklist without a trip to the
    /// Schedule tab — flips the persisted rule and starts the engine, exactly
    /// what the Schedule toggle and menu-bar Resume do.
    private func enableRotation() {
        let rule = Store.shared.rule()
        rule.enabled = true
        try? Store.shared.context.save()
        engine.start()
    }

    var body: some View {
        ZStack {
            background
                // .id forces SwiftUI to treat each photo's background as a
                // distinct view, which makes .transition fire when `current`
                // changes. Without this the AsyncImage just swaps its inner
                // image with no animation.
                .id(current?.unsplashID ?? "placeholder")
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.45), value: current?.unsplashID)
            .frame(minWidth: 720, minHeight: 480)
            .ignoresSafeArea(edges: .top)
            // .overlay strictly clips its contents to the receiver's bounds,
            // so the card can never extend past the window even if the user
            // shrinks horizontally. GeometryReader gives us the real on-
            // screen container width so we can cap the card at min(560,
            // available - paddings) — guarantees no overflow.
            .overlay(alignment: .bottomLeading) {
                if let photo = current {
                    GeometryReader { geo in
                        let cardWidth = min(560, max(0, geo.size.width - 64))
                        PhotoMetadataCard(photo: photo, isDarkBackdrop: isDarkBackdrop)
                            .frame(width: cardWidth, alignment: .leading)
                            .padding(.leading, 32)
                            .padding(.bottom, 56)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
            }
            .task(id: current?.unsplashID) {
                await loadBackgroundImage()
                await updateBackdropLuminance()
            }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await WallpaperApplier.shared.reapplyMostRecent() }
                } label: {
                    Image(systemName: "arrow.uturn.down")
                }
                .help("Reapply current wallpaper — re-set the macOS desktop image without rotating to a new one")
                .disabled(current == nil)

                Button {
                    Task { await engine.rotateNow() }
                } label: {
                    Image(systemName: "forward.end")
                }
                .help("Rotate now")

                Button {
                    Task { await WallpaperApplier.shared.regenerateMostRecent() }
                } label: {
                    if applier.isEnriching {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .tint(.secondary)
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .foregroundStyle(applier.isEnriching ? .secondary : .primary)
                .help(applier.isEnriching ? "Generating AI info…" : "Regenerate AI info — re-run the architecture agent on the current photo")
                .disabled(current == nil || applier.isEnriching)

                if let photo = current {
                    Button {
                        Store.shared.toggleFavorite(photo)
                    } label: {
                        Image(systemName: photo.favoritedAt == nil ? "heart" : "heart.fill")
                    }
                    .help(photo.favoritedAt == nil ? "Favorite" : "Unfavorite")
                }
            }
        }
    }

    /// Sample the wallpaper's bottom-left region (where the metadata card
    /// sits) and update `cardBackdropLuminance`. Runs off-main on a low-
    /// priority detached task — only the published @State write is on main.
    private func updateBackdropLuminance() async {
        guard let photo = current else { return }
        let local = ImageCache.shared.fileURL(for: photo.unsplashID)
        guard FileManager.default.fileExists(atPath: local.path) else {
            // Local cache miss (rare — happens for photos applied before
            // ImageCache was wired). Bail and let the next rotation sample.
            return
        }
        // Card sits at bottom-leading with ~32pt padding-left and 56pt padding-
        // bottom; its width caps at 560pt of a typical 1100pt window. So in
        // image-space we want roughly the bottom-left quarter — this rect is
        // a generous bound that always overlaps the card region.
        let region = CGRect(x: 0.02, y: 0.62, width: 0.40, height: 0.36)
        let lum = await BackdropLuminanceSampler.sample(imageURL: local, normalizedRegion: region)
        cardBackdropLuminance = lum
    }

    /// Decode the current photo's cached file off-main and publish it for the
    /// background. Prefer the local cache copy — by the time the user sees
    /// this view we've already downloaded the bytes for the rotation, so
    /// hitting Unsplash again on every photo change is wasted network. The
    /// AsyncImage fallback in `background` covers cache misses (first launch,
    /// user-evicted, mirrored-from-iCloud-but-not-yet-downloaded).
    private func loadBackgroundImage() async {
        guard let photo = current else {
            backgroundImage = nil
            backgroundImageID = nil
            return
        }
        guard backgroundImageID != photo.unsplashID else { return }
        let cachedURL = ImageCache.shared.fileURL(for: photo.unsplashID)
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard FileManager.default.fileExists(atPath: cachedURL.path) else { return nil }
            return NSImage(contentsOf: cachedURL)
        }.value
        backgroundImage = image
        backgroundImageID = image != nil ? photo.unsplashID : nil
    }

    @ViewBuilder
    private var background: some View {
        if let photo = current {
            if let nsImage = backgroundImage, backgroundImageID == photo.unsplashID {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .ignoresSafeArea()
            } else if ImageCache.shared.exists(photo.unsplashID) {
                // Cached file is being decoded off-main — show the gradient for
                // a frame or two rather than kicking off a redundant download.
                PlaceholderGradient().ignoresSafeArea()
            } else if let url = photo.regularURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        PlaceholderGradient()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()
            } else {
                PlaceholderGradient().ignoresSafeArea()
            }
        } else {
            PlaceholderGradient()
                .ignoresSafeArea()
                .overlay {
                    OnboardingChecklist(
                        hasUnsplashKey: hasUnsplashKey,
                        rotationOn: rules.first?.enabled ?? false,
                        onEnableRotation: enableRotation,
                        onRotateNow: { Task { await engine.rotateNow() } }
                    )
                }
        }
    }
}

private struct PhotoMetadataCard: View {
    let photo: Photo
    /// True when the wallpaper region behind the card is dark (avg luminance
    /// < 0.5). NowView samples the cached image once per rotation and pipes
    /// the result through. Drives BOTH the glass tint and the text colors —
    /// macOS 26 `.glassEffect(.regular)`'s auto-adapt isn't reliable enough
    /// over photo backgrounds (the renderer biases toward window chrome,
    /// not the immediate underlying pixels), so we steer it explicitly.
    let isDarkBackdrop: Bool

    // Higher-contrast palette for both backdrops. On bright wallpapers (the
    // common failure case) body text was getting lost over busy facades —
    // body is now near-black, and the glass tint below is bumped from 0.26
    // to 0.45 so the card actually reads as a card, not a light wash.
    private var primaryTextColor: Color { isDarkBackdrop ? .white : Color(white: 0.04) }
    private var secondaryTextColor: Color { isDarkBackdrop ? .white.opacity(0.92) : Color(white: 0.10) }
    private var tertiaryTextColor: Color { isDarkBackdrop ? .white.opacity(0.82) : Color(white: 0.22) }
    /// Soft halo behind text — same colour as the glass tint, kept low-radius.
    /// Heavy white shadows on dark text were producing fringes; keep this small.
    private var textShadowColor: Color { isDarkBackdrop ? .black.opacity(0.55) : .white.opacity(0.55) }

    /// Prefer the medium blurb (richer 2-3 sentence intro) when the agent
    /// produced one; fall back to oneSentence so old enrichments and partial
    /// commits still render something.
    private var blurbText: String? {
        let medium = photo.enrichment?.blurbMedium?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let medium, !medium.isEmpty { return medium }
        let one = photo.enrichment?.oneSentence?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let one, !one.isEmpty { return one }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(primaryTextColor)
                    .shadow(color: textShadowColor, radius: 3, x: 0, y: 1)
                    .lineLimit(2)
                    // contentTransition.numericText animates each glyph as the
                    // text changes — so when enrichment lands and the title
                    // flips from "New York, USA" → "One World Trade Center"
                    // the change rolls in instead of cutting.
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.35), value: title)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(secondaryTextColor)
                        .shadow(color: textShadowColor, radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.35), value: subtitle)
                }
            }

            if let blurb = blurbText {
                Text(blurb)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(secondaryTextColor)
                    .shadow(color: textShadowColor, radius: 4, x: 0, y: 0)
                    .lineLimit(5)
                    .frame(maxWidth: 520, alignment: .leading)
                    .id(blurb)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                    .animation(.easeInOut(duration: 0.4), value: blurb)
            }

            if let metaLine, !metaLine.isEmpty {
                Text(metaLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(tertiaryTextColor)
                    .shadow(color: textShadowColor, radius: 2, x: 0, y: 1)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Label(photo.authorName.isEmpty ? "Unknown" : photo.authorName, systemImage: "camera")
                if let url = photo.authorProfileURL {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(tertiaryTextColor)
            .shadow(color: textShadowColor, radius: 2, x: 0, y: 1)
        }
        .padding(18)
        // The outer container in NowView already caps width via GeometryReader.
        // Use .infinity here so the glass background fills the cap exactly.
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isDarkBackdrop ? 0.28 : 0.55),
                            .white.opacity(isDarkBackdrop ? 0.10 : 0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(isDarkBackdrop ? 0.16 : 0.24),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .allowsHitTesting(false)
        }
        .glassEffect(
            .regular.tint(isDarkBackdrop ? .black.opacity(0.38) : .white.opacity(0.48)),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 4)
        .animation(.easeInOut(duration: 0.35), value: isDarkBackdrop)
    }

    private var title: String {
        photo.bestPlaceTitle
    }

    private var subtitle: String {
        photo.bestPlaceSubtitle
    }

    private var metaLine: String? {
        guard let exif = photo.exif else { return nil }
        var bits: [String] = []
        if !exif.cameraLine.isEmpty { bits.append(exif.cameraLine) }
        if !exif.shotLine.isEmpty { bits.append(exif.shotLine) }
        let line = bits.joined(separator: "  ·  ")
        return line.isEmpty ? nil : line
    }
}

/// Off-main image sampler — averages a normalized rect of pixels and returns
/// Rec. 709 luminance (0..1). Driven by `NowView.updateBackdropLuminance`.
/// Implementation note: we intentionally render through a 1×1 CGContext
/// rather than `CIAreaAverage` — the former is ~10× faster on small inputs
/// because there's no CIContext spin-up, and the result is identical for
/// our purpose (one number, not a filter pipeline).
enum BackdropLuminanceSampler {
    static func sample(imageURL: URL, normalizedRegion: CGRect) async -> Double {
        await Task.detached(priority: .utility) {
            guard let nsImage = NSImage(contentsOf: imageURL),
                  let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return 0.2 }

            let w = CGFloat(cg.width)
            let h = CGFloat(cg.height)
            let crop = CGRect(
                x: max(0, normalizedRegion.minX * w),
                y: max(0, normalizedRegion.minY * h),
                width: min(w, normalizedRegion.width * w),
                height: min(h, normalizedRegion.height * h)
            )
            guard let cropped = cg.cropping(to: crop) else { return 0.2 }

            var pixel: [UInt8] = [0, 0, 0, 0]
            let space = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            guard let ctx = CGContext(
                data: &pixel,
                width: 1, height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: space,
                bitmapInfo: bitmapInfo
            ) else { return 0.2 }
            ctx.interpolationQuality = .medium
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))

            let r = Double(pixel[0]) / 255.0
            let g = Double(pixel[1]) / 255.0
            let b = Double(pixel[2]) / 255.0
            // Rec. 709 luma. Heavier weight on green matches human perception
            // of brightness — using a flat (R+G+B)/3 makes deep-red and deep-
            // green areas read the same, which would mis-classify warm sunset
            // wallpapers as "lighter than they look."
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }.value
    }
}

/// First-run guide shown over the placeholder gradient until the first photo
/// is applied. Replaces the old static "go to Connections, then Discover"
/// text — which sent users bouncing between two Settings tabs — with a live
/// three-step checklist whose rows check off as each prerequisite is met and
/// whose buttons deep-link or act directly.
private struct OnboardingChecklist: View {
    let hasUnsplashKey: Bool
    let rotationOn: Bool
    let onEnableRotation: () -> Void
    let onRotateNow: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 46, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Welcome to paperpaper")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Three quick steps to your first wallpaper.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
            }

            VStack(alignment: .leading, spacing: 12) {
                ChecklistRow(
                    step: 1,
                    done: hasUnsplashKey,
                    title: "Add your Unsplash Access Key",
                    subtitle: "Free, takes a minute — paste it in Connections.",
                    actionLabel: "Open Connections",
                    actionEnabled: true,
                    action: {
                        MainWindowState.shared.settingsSection = .connections
                        MainWindowState.shared.mode = .settings
                    }
                )
                ChecklistRow(
                    step: 2,
                    done: rotationOn,
                    title: "Turn on automatic rotation",
                    subtitle: "A fresh photo for your location, on your schedule.",
                    actionLabel: "Enable",
                    actionEnabled: hasUnsplashKey,
                    action: onEnableRotation
                )
                ChecklistRow(
                    step: 3,
                    done: false,
                    title: "Load your first photo now",
                    subtitle: "Optional — or just wait for the next rotation.",
                    actionLabel: "Rotate now",
                    actionEnabled: hasUnsplashKey,
                    action: onRotateNow
                )
            }
            .frame(maxWidth: 420)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.black.opacity(0.28))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
            )
        }
        .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 2)
        .padding(40)
    }
}

private struct ChecklistRow: View {
    let step: Int
    let done: Bool
    let title: String
    let subtitle: String
    let actionLabel: String
    let actionEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(step).circle")
                .font(.system(size: 22))
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.white.opacity(0.7)))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .strikethrough(done, color: .white.opacity(0.6))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 8)

            if !done {
                Button(actionLabel, action: action)
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
                    .disabled(!actionEnabled)
            }
        }
        .opacity(done ? 0.7 : 1)
    }
}

struct PlaceholderGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.07, blue: 0.12),
                Color(red: 0.14, green: 0.16, blue: 0.22),
                Color(red: 0.30, green: 0.22, blue: 0.18),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    NowView()
        .modelContainer(Store.shared.container)
        .frame(width: 1100, height: 720)
}
