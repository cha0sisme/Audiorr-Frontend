import SwiftUI

// MARK: - Modelo

/// Un usuario escuchando algo ahora mismo, tras el filtrado de presencia.
/// `id == username` → identidad ESTABLE para el `ForEach`/`.transition`: cuando
/// alguien cambia de canción su tarjeta NO se re-monta (solo su contenido).
struct Listener: Identifiable, Equatable {
    let username: String
    let title: String
    let artist: String
    let coverArt: String?
    var id: String { username }
}

/// Wrapper Identifiable para presentar el perfil público vía `.sheet(item:)`.
struct ListenerProfileID: Identifiable, Equatable {
    let username: String
    var id: String { username }
}

// MARK: - Servicio de presencia (poll de getNowPlaying + filtrado)

/// Sondea `getNowPlaying.view` cada 30 s y publica los `listeners` filtrados.
/// Filtrado idéntico a web/Android (no improvisar): excluir al propio usuario,
/// descartar reports > 10 min, exigir canción, dedup por persona, y orden
/// ALFABÉTICO por username — NO por recencia, para que las tarjetas no bailen en
/// cada refetch. El poll no corre en background (iOS suspende el Task; además se
/// para en `.onDisappear` del Home).
@MainActor
@Observable
final class LiveListenersService {
    static let shared = LiveListenersService()

    private(set) var listeners: [Listener] = []

    private let api = NavidromeService.shared
    private var pollTask: Task<Void, Never>?
    private let pollIntervalNs: UInt64 = 30_000_000_000 // 30 s

    private init() {}

    /// Arranca el poll (al aparecer el Home). Idempotente.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: self?.pollIntervalNs ?? 30_000_000_000)
            }
        }
    }

    /// Detiene el poll.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh() async {
        let entries = await api.getNowPlaying()
        let me = api.credentials?.username.lowercased()

        var seen = Set<String>()
        var result: [Listener] = []
        for e in entries {
            guard let username = e.username, !username.isEmpty else { continue }
            if let me, username.lowercased() == me { continue }          // 1. excluir self
            if let mins = e.minutesAgo, mins > 10 { continue }            // 2. solo en vivo (≤10 min)
            guard let title = e.title, !title.isEmpty else { continue }   // 3. sin canción → fuera
            if seen.contains(username) { continue }                       // 4. dedup por persona
            seen.insert(username)
            result.append(Listener(
                username: username,
                title: title,
                artist: e.artist ?? "",
                coverArt: e.coverArt ?? e.albumId
            ))
        }
        // 5. orden alfabético estable (no recencia)
        result.sort { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }

        // Asignar solo si cambió → el poll en vacío NO dispara ninguna animación.
        if result != listeners { listeners = result }
    }
}

// MARK: - Fila "Escuchando ahora" del Home

/// Carrusel horizontal de listeners. Preparado para que el chip Rewind entre
/// como PRIMER hijo del HStack (otra sesión); hoy solo tarjetas de listener.
/// La animación de entrada/salida de la sección y el reflow del Home los
/// controla `HomeView` con `.animation(_:value:)`; aquí van las transiciones
/// por tarjeta.
struct ListenersRow: View {
    let listeners: [Listener]
    let onTap: (String) -> Void   // username

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 10) {
                // [chip Rewind] entrará aquí, antes del ForEach (sesión futura).
                ForEach(listeners) { listener in
                    ListenerCard(listener: listener)
                        .onTapGesture { onTap(listener.username) }
                        .transition(reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .scale(scale: 0.85).combined(with: .opacity),
                                removal: .opacity))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 4)
    }
}

// MARK: - Tarjeta de listener (220×64, "fila cero" de la familia Reanudar)

private struct ListenerCard: View {
    let listener: Listener

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Canción · Artista" (solo canción si no hay artista).
    private var subtitle: String {
        listener.artist.isEmpty ? listener.title : "\(listener.title) · \(listener.artist)"
    }

    var body: some View {
        HStack(spacing: 10) {
            avatarWithCover

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // EQ "sonando ahora" — junto al nombre (su referente es la
                    // canción, no la persona). Congelado bajo Reduce Motion.
                    NowPlayingIndicator(
                        isPlaying: !reduceMotion,
                        color: .accentColor,
                        barWidth: 2, height: 10, spacing: 1.5
                    )
                    Text(listener.username)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Cambia de canción sin re-montar: crossfade del subtítulo.
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.25), value: subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 220, height: 64)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(listener.username), escuchando \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }

    /// Avatar (fondo pleno + inicial blanca, MISMO color que el perfil del
    /// usuario) con la cover solapada en la esquina inferior-derecha.
    private var avatarWithCover: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(avatarColor(for: listener.username))
                .frame(width: 40, height: 40)
                .overlay(
                    Text(avatarInitial(for: listener.username))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                )

            CachedCoverView(coverArt: listener.coverArt, size: 22, cornerRadius: 6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(.secondarySystemGroupedBackground), lineWidth: 1.5)
                )
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.3), value: listener.coverArt)
                // 2pt: la cover MONTA sobre la esquina del avatar (la solapa de
                // verdad), no flota despegada. El borde de 1.5 hace el recorte limpio.
                .offset(x: 2, y: 2)
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - Avatar determinista

/// Mismo algoritmo que `SettingsView.avatarColor`/`avatarInitial` (contrato
/// cross-platform con `getColorForUsername` de la web): el color de un listener
/// en la fila DEBE coincidir con el que ese usuario ve en su propio perfil.
/// Replicado aquí (no compartido) porque la función de Settings es `private` a
/// su archivo; el algoritmo es determinista y estable.
private func avatarColor(for username: String) -> Color {
    var hash: Int = 0
    for char in username.unicodeScalars {
        hash = Int(char.value) &+ ((hash &<< 5) &- hash)
    }
    let hue = Double(abs(hash) % 360)
    let saturation = Double(60 + abs(hash) % 21) / 100.0
    let lightness = Double(45 + abs(hash >> 8) % 21) / 100.0
    return Color(hue: hue / 360.0, saturation: saturation,
                 brightness: lightness + saturation * min(lightness, 1 - lightness))
}

private func avatarInitial(for username: String) -> String {
    let trimmed = username.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first else { return "?" }
    return String(first).uppercased()
}
