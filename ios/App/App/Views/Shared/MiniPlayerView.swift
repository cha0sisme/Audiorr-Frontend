import SwiftUI

/// Mini player nativo para `.tabViewBottomAccessory`.
/// Replica el layout del mini-player UIKit anterior (artwork 42×42, 3 botones, progress bar).
/// El styling Liquid Glass lo aplica automáticamente el TabView accessory.
struct MiniPlayerView: View {
    private var state = NowPlayingState.shared

    var body: some View {
        if state.isVisible {
            activePlayer
        } else {
            idlePlaceholder
        }
    }

    // MARK: - Active Player

    private var activePlayer: some View {
        VStack(spacing: 0) {
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                    Rectangle()
                        .fill(Color.primary.opacity(0.30))
                        .frame(width: geo.size.width * progressFraction)
                }
            }
            .frame(height: 2.5)

            // Content
            HStack(spacing: 10) {
                // Artwork
                artworkImage
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(state.artist)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let subtitle = state.subtitle, !subtitle.isEmpty {
                        if subtitle.hasPrefix("AutoMix") {
                            WaveText(subtitle, font: .system(size: 10, weight: .semibold), color: .cyan)
                                .lineLimit(1)
                                .transition(.opacity)
                        } else {
                            Text(subtitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                                .lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Controls
                HStack(spacing: 2) {
                    controlButton("backward.fill", size: 20) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        PlayerService.shared.previous()
                    }
                    controlButton(state.isPlaying ? "pause.fill" : "play.fill", size: 23) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        PlayerService.shared.togglePlayPause()
                    }
                    controlButton("forward.fill", size: 20) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        PlayerService.shared.next()
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 67.5) // 70 total - 2.5 progress
        }
        .contentShape(Rectangle())
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            NowPlayingState.shared.viewerIsOpen = true
        }
        .animation(Anim.small, value: state.subtitle)
    }

    // MARK: - Idle Placeholder

    private var idlePlaceholder: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                Image(systemName: "music.note")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 42, height: 42)

            Text("Sin reproducción")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 70)
    }

    // MARK: - Helpers

    private var progressFraction: CGFloat {
        state.duration > 0 ? CGFloat(state.progress / state.duration) : 0
    }

    private var artworkImage: some View {
        MiniPlayerArtwork(coverArt: state.coverArt, artworkUrl: state.artworkUrl)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cached mini player artwork

/// Uses AlbumCoverCache so the artwork survives tab switches without flashing.
private struct MiniPlayerArtwork: View {
    let coverArt: String
    let artworkUrl: String?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color(.secondarySystemFill))
                    Image(systemName: "music.note")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if image == nil, !coverArt.isEmpty {
                image = AlbumCoverCache.shared.image(for: coverArt)
            }
        }
        .task(id: coverArt) {
            // Already cached — show instantly
            if let cached = AlbumCoverCache.shared.image(for: coverArt) {
                image = cached
                return
            }
            // Download and cache
            guard let urlStr = artworkUrl, let url = URL(string: urlStr),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            AlbumCoverCache.shared.setImage(img, for: coverArt)
            image = img
        }
    }
}
