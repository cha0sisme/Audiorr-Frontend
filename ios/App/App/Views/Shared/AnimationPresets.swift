import SwiftUI

// MARK: - Centralized animation presets (Apple Music-style consistency)

/// Standard animation presets for the entire app.
/// Use these instead of inline spring/easing values to maintain visual consistency.
enum Anim {
    // MARK: Springs

    /// Fast dismissals, button state changes, small UI reactions (0.35s)
    static let quick = Animation.spring(response: 0.35, dampingFraction: 0.88)

    /// Entrance animations, moderate transitions (0.45s)
    static let moderate = Animation.spring(response: 0.45, dampingFraction: 0.88)

    /// Large-scale transitions like viewer open/close (0.5s)
    static let expand = Animation.spring(response: 0.5, dampingFraction: 0.92)

    /// Interactive drag feedback (0.35s, slightly less damped for responsiveness)
    static let interactive = Animation.interactiveSpring(response: 0.35, dampingFraction: 0.86)

    /// Playback state (play/pause artwork scale) — bouncy, expressive (0.55s)
    static let playback = Animation.spring(response: 0.55, dampingFraction: 0.72)

    // MARK: Easing

    /// Micro-interactions: icon toggles, label reveals (0.15s)
    static let micro = Animation.easeInOut(duration: 0.15)

    /// Small state changes: button feedback, visibility toggles (0.2s)
    static let small = Animation.easeInOut(duration: 0.2)

    /// Content state changes: section toggles, lyrics scroll (0.3s)
    static let content = Animation.easeInOut(duration: 0.3)

    /// Accent/color transitions: background fades, palette shifts (0.4s)
    static let color = Animation.easeInOut(duration: 0.4)
}

// MARK: - Hero → content fade (Apple Music-style)

extension LinearGradient {
    /// Multi-stop fade for hero backgrounds (AlbumDetailView, ArtistDetailView,
    /// PlaylistDetailView). Replaces the 2-stop `[.clear, pageBg]` gradient,
    /// which left a visible seam around the 50% line because linear opacity
    /// interpolation makes the transition's midpoint the point of fastest
    /// cromatic change.
    ///
    /// The opacity of `pageBg` follows a smoothstep curve `3t² − 2t³` (cubic
    /// ease-in-out), sampled at 11 stops. The slow tails at top (≤10 %) and
    /// bottom (≥90 %) dissolve the gradient's edges into the hero and into
    /// the page body respectively, leaving no perceptible line. Apply with
    /// `.frame(height:)` of ~50 – 60 % of the hero height; shorter frames will
    /// compress the curve and re-introduce a visible seam.
    ///
    /// The hero behind shows through wherever opacity is below 1, so this
    /// works identically over a blurred cover, a solid palette colour, or any
    /// other background — no separate "solid" overload is needed.
    static func heroFade(to pageBg: Color) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: pageBg.opacity(0.000), location: 0.00),
                .init(color: pageBg.opacity(0.028), location: 0.10),
                .init(color: pageBg.opacity(0.104), location: 0.20),
                .init(color: pageBg.opacity(0.216), location: 0.30),
                .init(color: pageBg.opacity(0.352), location: 0.40),
                .init(color: pageBg.opacity(0.500), location: 0.50),
                .init(color: pageBg.opacity(0.648), location: 0.60),
                .init(color: pageBg.opacity(0.784), location: 0.70),
                .init(color: pageBg.opacity(0.896), location: 0.80),
                .init(color: pageBg.opacity(0.972), location: 0.90),
                .init(color: pageBg.opacity(1.000), location: 1.00),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Expandable bio (Apple Music-style "MÁS" / "OCULTAR")

/// Bio block that mirrors the Apple Music collapsed/expanded biography pattern.
///
/// Collapsed: 2 lines + the word "MÁS" inline at the trailing edge of the second
/// line. A short horizontal gradient fades the truncated text behind "MÁS" into
/// `pageBg` so the boundary doesn't look like a hard overlap. Tap anywhere on the
/// block to expand.
///
/// Expanded: full text + "OCULTAR" button at the trailing edge below.
///
/// Used by AlbumDetailView (`albumNotes`) and ArtistDetailView (`biography`).
/// The `pageBg` parameter is required because the gradient mask only works if it
/// matches the page background colour of the host view; otherwise the seam reappears.
struct ExpandableBio: View {
    let text: String
    let pageBg: Color
    var textColor: Color = .secondary
    /// Título del sheet que se abre al pulsar "MÁS". Apple Music usa el
    /// nombre del álbum o del artista; el caller lo pasa explícitamente.
    var sheetTitle: String = ""

    @State private var showSheet: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(textColor)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .overlay(alignment: .bottomTrailing) {
                // Trailing inline "MÁS" con fade horizontal amplio (~110pt)
                // que se desvanece suavemente sobre las últimas palabras de
                // la segunda línea. 7 stops smoothstep (3t²−2t³) para que el
                // degradado opacity 0 → pageBg sea perceptualmente lineal
                // sin bandas, mismo patrón que el hero-fade.
                HStack(spacing: 0) {
                    LinearGradient(
                        stops: Self.maslFadeStops(pageBg: pageBg),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 110, height: 22)
                    Text("MÁS")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.leading, 2)
                        .frame(height: 22, alignment: .bottom)
                        .background(pageBg)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                showSheet = true
            }
            .sheet(isPresented: $showSheet) {
                BioSheetView(title: sheetTitle, text: text)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
            }
    }

    /// Stops smoothstep `3t²−2t³` para el fade horizontal del MÁS. 7 stops dan
    /// un degradado perceptualmente lineal opacity 0 → pageBg sin bandas,
    /// cubriendo los ~110pt antes del label. Mismo patrón que el hero-fade.
    private static func maslFadeStops(pageBg: Color) -> [Gradient.Stop] {
        let ts: [Double] = [0.0, 0.15, 0.30, 0.50, 0.70, 0.85, 1.0]
        return ts.map { t in
            let smooth = t * t * (3 - 2 * t)
            return Gradient.Stop(color: pageBg.opacity(smooth), location: t)
        }
    }
}

/// Sheet de bio a pantalla completa. Apple Music abre la biografía del
/// álbum / artista en un sheet propio en vez de expandir inline.
/// Título centrado con el nombre del álbum o del artista, botón de
/// cerrar arriba a la derecha, cuerpo de texto scrollable.
private struct BioSheetView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if text.isEmpty {
                    // Fallback cuando la bio resulta vacía tras limpiar HTML.
                    VStack(spacing: 8) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("Sin información disponible")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    Text(text)
                        .font(.system(size: 17))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 40)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Botón cerrar estilo iOS 26 nativo: `xmark.circle.fill` con
                // rendering hierarchical (dos tonos automáticos del color de
                // foregroundStyle). Es el patrón que Apple usa en sus sheets
                // del sistema (Photos, Music, Mail).
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(L.close)
                }
            }
        }
    }
}
