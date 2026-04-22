import SwiftUI

// MARK: - User Avatar Color (deterministic, matches JS getColorForUsername)

/// Generates a consistent HSL color for a username — same algorithm as the web app.
/// The color is permanently tied to the username string.
private func avatarColor(for username: String) -> Color {
    var hash: Int = 0
    for char in username.unicodeScalars {
        hash = Int(char.value) &+ ((hash &<< 5) &- hash)
    }
    let hue = Double(abs(hash) % 360)
    let saturation = Double(60 + abs(hash) % 21) / 100.0
    let lightness = Double(45 + abs(hash >> 8) % 21) / 100.0
    // Convert HSL → SwiftUI Color
    return Color(hue: hue / 360.0, saturation: saturation, brightness: lightness + saturation * min(lightness, 1 - lightness))
}

private func avatarInitial(for username: String) -> String {
    let trimmed = username.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.first else { return "?" }
    return String(first).uppercased()
}

// MARK: - View Model

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var isDjMode = false
    @Published var useReplayGain = true
    @Published var crossfadeEnabled = true
    @Published var crossfadeDuration: Double = 8  // seconds (2–15)
    @Published var scrobbleEnabled = false

    @Published var lastfmApiKey = ""
    @Published var lastfmHasSecret = false
    @Published var scrobbleStatus: ScrobbleStatus = .idle

    private let settingsKey = "audiorr_settings"

    enum ScrobbleStatus { case idle, testing, success, error }

    func load() {
        loadJSSettings()
        loadScrobble()

        Task {
            if BackendState.shared.isAvailable {
                await loadLastFmConfig()
            }
        }
    }

    // MARK: - JS Settings bridge (audiorr_settings in localStorage)

    private func loadJSSettings() {
        // Read from UserDefaults mirror (AppDelegate syncs from JS localStorage)
        guard let json = UserDefaults.standard.string(forKey: settingsKey),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        isDjMode = dict["isDjMode"] as? Bool ?? false
        useReplayGain = dict["useReplayGain"] as? Bool ?? true
        crossfadeEnabled = dict["crossfadeEnabled"] as? Bool ?? true
        crossfadeDuration = dict["crossfadeDuration"] as? Double ?? 8
    }

    private func saveJSSettings() {
        let dict: [String: Any] = [
            "isDjMode": isDjMode,
            "useWebAudio": false,
            "useReplayGain": useReplayGain,
            "crossfadeEnabled": crossfadeEnabled,
            "crossfadeDuration": crossfadeDuration,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8)
        else { return }

        // Persist locally
        UserDefaults.standard.set(json, forKey: settingsKey)
    }

    func toggleDjMode() {
        isDjMode.toggle()
        saveJSSettings()
    }

    func toggleReplayGain() {
        useReplayGain.toggle()
        saveJSSettings()
    }

    func toggleCrossfade() {
        crossfadeEnabled.toggle()
        saveJSSettings()
    }

    func setCrossfadeDuration(_ value: Double) {
        crossfadeDuration = value
        saveJSSettings()
    }

    // MARK: - Scrobble

    private func loadScrobble() {
        scrobbleEnabled = UserDefaults.standard.bool(forKey: "scrobbleEnabled")
    }

    func toggleScrobble(_ enabled: Bool) {
        scrobbleEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "scrobbleEnabled")
        ScrobbleService.shared.setEnabled(enabled)
        scrobbleStatus = .idle
    }

    func testScrobble() {
        scrobbleStatus = .testing
        // Simulate test — matches JS behaviour
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            scrobbleStatus = .success
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            scrobbleStatus = .idle
        }
    }

    // MARK: - Last.fm (backend API)

    private func backendBase() -> String? { NavidromeService.shared.backendURL() }

    func loadLastFmConfig() async {
        guard let base = backendBase(),
              let url = URL(string: "\(base)/api/config/lastfm")
        else { return }

        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            lastfmApiKey = ""
            lastfmHasSecret = false
            return
        }

        lastfmApiKey = dict["apiKey"] as? String ?? ""
        lastfmHasSecret = dict["hasSecret"] as? Bool ?? false
    }

    func saveLastFmApiKey() async -> Bool {
        let trimmed = lastfmApiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let base = backendBase(),
              let url = URL(string: "\(base)/api/config/lastfm")
        else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["apiKey": trimmed])

        guard let (_, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return false }

        lastfmHasSecret = false
        return true
    }

    func deleteLastFmApiKey() async -> Bool {
        guard let base = backendBase(),
              let url = URL(string: "\(base)/api/config/lastfm")
        else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        guard let (_, resp) = try? await URLSession.shared.data(for: request),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return false }

        lastfmApiKey = ""
        lastfmHasSecret = false
        return true
    }

    // MARK: - Logout

    func logout() {
        NavidromeService.shared.clearCredentials()
        UserDefaults.standard.removeObject(forKey: "navidromeConfig")
        UserDefaults.standard.removeObject(forKey: "audiorr_backend_url")

        // Disconnect from hub
        ConnectService.shared.disconnect()

        // Clear playback state
        QueueManager.shared.clear()
        PersistenceService.shared.clearAll()

        // Show login screen
        (UIApplication.shared.delegate as? AppDelegate)?.showLogin()
        // TODO: migrate login to SwiftUI fullScreenCover on ContentView
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @StateObject private var vm = SettingsViewModel()
    @ObservedObject private var theme = AppTheme.shared
    @State private var showLogoutConfirm = false
    @State private var showSaveAlert = false
    @State private var showProfile = false
    @State private var alertMessage = ""
    @State private var scrollY: CGFloat = 0

    private let collapseThreshold: CGFloat = 44

    private var stickyOpacity: CGFloat {
        min(max((scrollY - collapseThreshold * 0.4) / (collapseThreshold * 0.6), 0), 1)
    }
    private var largeTitleOpacity: CGFloat {
        1 - min(max(scrollY / collapseThreshold, 0), 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                largeHeader
                settingsContent
            }
        }
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
            scrollY = y
        }
        .background(Color(.systemBackground))
        .toolbarBackground(stickyOpacity > 0.5 ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Configuración")
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
            if !username.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showProfile = true } label: {
                        ZStack {
                            Circle()
                                .fill(avatarColor(for: username))
                            Text(avatarInitial(for: username))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 28, height: 28)
                    }
                    .opacity(stickyOpacity)
                }
            }
        }
        .sheet(isPresented: $showProfile) {
            UserProfileSheet(username: username)
        }
        .preferredColorScheme(theme.colorScheme)
        .onAppear { vm.load() }
        .alert("Last.fm", isPresented: $showSaveAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog("Cerrar sesión", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) {
                vm.logout()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borrará la configuración del servidor.")
        }
    }

    // MARK: - Large header

    private var username: String {
        NavidromeService.shared.credentials?.username ?? ""
    }

    private var largeHeader: some View {
        HStack(alignment: .bottom) {
            Text("Configuración")
                .font(.system(size: 34, weight: .bold))
            Spacer()
            if !username.isEmpty {
                Button { showProfile = true } label: {
                    ZStack {
                        Circle()
                            .fill(avatarColor(for: username))
                        Text(avatarInitial(for: username))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 38, height: 38)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .padding(.top, UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 59)
        .opacity(largeTitleOpacity)
    }

    // MARK: - Settings content

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // ── Apariencia ──
            settingsSection(header: "Apariencia") {
                settingsRow {
                    Label("Modo oscuro", systemImage: "moon.fill")
                    Spacer()
                    Toggle("", isOn: $theme.isDark)
                    .labelsHidden()
                }
            }

            // ── Reproducción ──
            settingsSection(
                header: "Reproducción",
                footer: crossfadeFooter
            ) {
                if BackendState.shared.isAvailable {
                    // Backend connected → DJ Mode toggle only (crossfade is always on)
                    settingsRow {
                        Label("Modo DJ", systemImage: "dial.medium.fill")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.isDjMode },
                            set: { _ in vm.toggleDjMode() }
                        ))
                        .labelsHidden()
                    }
                } else {
                    // No backend → standard crossfade toggle + duration
                    settingsRow {
                        Label("Crossfade", systemImage: "arrow.trianglehead.swap")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.crossfadeEnabled },
                            set: { _ in vm.toggleCrossfade() }
                        ))
                        .labelsHidden()
                    }

                    if vm.crossfadeEnabled {
                        Divider().padding(.leading, 16)
                        settingsRow {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label("Duración", systemImage: "timer")
                                    Spacer()
                                    Text("\(Int(vm.crossfadeDuration))s")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Slider(value: Binding(
                                    get: { vm.crossfadeDuration },
                                    set: { vm.setCrossfadeDuration($0) }
                                ), in: 2...15, step: 1)
                                .tint(.accentColor)
                                HStack {
                                    Text("2s")
                                    Spacer()
                                    Text("15s")
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                Divider().padding(.leading, 16)
                settingsRow {
                    Label("ReplayGain", systemImage: "speaker.wave.2.fill")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { vm.useReplayGain },
                        set: { _ in vm.toggleReplayGain() }
                    ))
                    .labelsHidden()
                }
            }

            // ── Last.fm ──
            if BackendState.shared.isAvailable {
                settingsSection(
                    header: "Last.fm",
                    footer: vm.scrobbleEnabled
                        ? "Las escuchas se registraran automaticamente tras reproducir al menos el 50% o 4 minutos."
                        : nil
                ) {
                    settingsRow {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Clave de API", systemImage: "key.fill")
                                .font(.subheadline.weight(.medium))
                            TextField("Introduce tu clave de API", text: $vm.lastfmApiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.subheadline)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            HStack(spacing: 12) {
                                Button("Guardar") {
                                    Task {
                                        let ok = await vm.saveLastFmApiKey()
                                        alertMessage = ok ? "Clave guardada." : "Error al guardar."
                                        showSaveAlert = true
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button("Eliminar", role: .destructive) {
                                    Task {
                                        let ok = await vm.deleteLastFmApiKey()
                                        alertMessage = ok ? "Clave eliminada." : "Error al eliminar."
                                        showSaveAlert = true
                                    }
                                }
                                .controlSize(.small)
                            }

                            if vm.lastfmHasSecret && vm.lastfmApiKey.isEmpty {
                                Text("Hay un secreto guardado en el backend.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider().padding(.leading, 16)
                    settingsRow {
                        Label("Scrobbling", systemImage: "arrow.up.right.circle.fill")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.scrobbleEnabled },
                            set: { vm.toggleScrobble($0) }
                        ))
                        .labelsHidden()
                    }
                    if vm.scrobbleEnabled {
                        Divider().padding(.leading, 16)
                        settingsRow {
                            scrobbleStatusBadge
                            Spacer()
                            Button("Probar") { vm.testScrobble() }
                                .font(.subheadline)
                                .disabled(vm.scrobbleStatus == .testing)
                        }
                    }
                }
            }

            // ── Almacenamiento offline ──
            settingsSection(header: "Almacenamiento") {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    settingsRow {
                        Label("Gestionar almacenamiento", systemImage: "externaldrive")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // ── Servidor ──
            settingsSection(header: "Servidor") {
                if let creds = NavidromeService.shared.credentials {
                    settingsRow {
                        Text("Servidor")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(creds.serverUrl)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Divider().padding(.leading, 16)
                    settingsRow {
                        Text("Usuario")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(creds.username)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Divider().padding(.leading, 16)
                }
                settingsRow {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("Cerrar sesión", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 100)
    }

    // MARK: - Dynamic footers

    private var crossfadeFooter: String {
        if BackendState.shared.isAvailable {
            if vm.isDjMode {
                return "Modo DJ analiza las canciones para crear mezclas dinámicas inteligentes. La duración se ajusta automáticamente según el análisis. ReplayGain normaliza el volumen."
            }
            return "Las transiciones se optimizan automáticamente con el análisis del backend. Activa Modo DJ para mezclas dinámicas inteligentes. ReplayGain normaliza el volumen."
        }
        if !vm.crossfadeEnabled {
            return "Las canciones cambiarán sin transición. ReplayGain normaliza el volumen entre canciones."
        }
        return "Crossfade mezcla las canciones con una transición de \(Int(vm.crossfadeDuration))s. ReplayGain normaliza el volumen entre canciones."
    }

    // MARK: - Section / row helpers

    private func settingsSection<Content: View>(
        header: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(header.uppercased())
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content()
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Scrobble badge

    @ViewBuilder
    private var scrobbleStatusBadge: some View {
        switch vm.scrobbleStatus {
        case .idle:
            Label("Activo", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Probando...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .success:
            Label("Correcto", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Label("Error", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

// MARK: - User Profile Sheet

@MainActor
final class UserProfileViewModel: ObservableObject {
    let username: String

    @Published var period: String = "week"
    @Published var isLoading = true
    @Published var totalPlays: Int = 0
    @Published var topGenre: String?
    @Published var lastScrobble: (title: String, artist: String, playedAt: Date)?
    @Published var lastConnection: Date?
    @Published var topSongs: [(id: String, title: String, artist: String, coverArt: String?, plays: Int)] = []
    @Published var topArtists: [(artist: String, plays: Int)] = []

    init(username: String) {
        self.username = username
    }

    func load() {
        Task { await fetchAll() }
    }

    func setPeriod(_ p: String) {
        period = p
        Task { await fetchStats() }
    }

    private func fetchAll() async {
        isLoading = true
        // Fetch user info (last connection, last scrobble) and stats in parallel
        async let statsTask: () = fetchStats()
        async let userTask: () = fetchUserInfo()
        _ = await (statsTask, userTask)
        isLoading = false
    }

    private func fetchStats() async {
        guard BackendState.shared.isAvailable else { return }
        do {
            let dict = try await BackendService.shared.getUserStats(username: username, period: period)
            totalPlays = dict["total_plays"] as? Int ?? 0

            if let genres = dict["top_genres"] as? [[String: Any]], let first = genres.first {
                topGenre = first["genre"] as? String
            }

            if let songs = dict["top_songs"] as? [[String: Any]] {
                topSongs = songs.prefix(5).map { s in
                    (id: s["id"] as? String ?? "",
                     title: s["title"] as? String ?? "",
                     artist: s["artist"] as? String ?? "",
                     coverArt: s["cover_art"] as? String,
                     plays: s["plays"] as? Int ?? 0)
                }
            }

            if let artists = dict["top_artists"] as? [[String: Any]] {
                topArtists = artists.prefix(5).map { a in
                    (artist: a["artist"] as? String ?? "", plays: a["plays"] as? Int ?? 0)
                }
            }
        } catch {
            print("[UserProfile] Stats fetch failed: \(error)")
        }
    }

    private func fetchUserInfo() async {
        guard BackendState.shared.isAvailable else { return }
        do {
            let users = try await BackendService.shared.getAdminUsers()
            guard let user = users.first(where: { ($0["username"] as? String) == username }) else { return }

            if let updated = user["updatedAt"] as? String {
                lastConnection = ISO8601DateFormatter().date(from: updated)
            }

            if let scrobble = user["lastScrobble"] as? [String: Any],
               let title = scrobble["title"] as? String,
               let artist = scrobble["artist"] as? String {
                let playedAt = (scrobble["playedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
                lastScrobble = (title: title, artist: artist, playedAt: playedAt)
            }
        } catch {
            print("[UserProfile] Admin users fetch failed: \(error)")
        }
    }
}

struct UserProfileSheet: View {
    let username: String
    @StateObject private var vm: UserProfileViewModel
    @Environment(\.dismiss) private var dismiss

    init(username: String) {
        self.username = username
        _vm = StateObject(wrappedValue: UserProfileViewModel(username: username))
    }

    private var color: Color { avatarColor(for: username) }
    private var initial: String { avatarInitial(for: username) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    profileHero
                    if vm.isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else if BackendState.shared.isAvailable {
                        statsContent
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .padding(.bottom, 40)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .onAppear { vm.load() }
        }
    }

    // MARK: - Hero

    private var profileHero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                    .shadow(color: color.opacity(0.4), radius: 20, y: 8)
                Text(initial)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 100, height: 100)

            Text(username)
                .font(.title.bold())

            // Last connection + server
            VStack(spacing: 4) {
                if let date = vm.lastConnection {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("Última conexión \(date, format: .dateTime.day().month(.abbreviated))")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                let serverUrl = NavidromeService.shared.credentials?.serverUrl ?? ""
                if !serverUrl.isEmpty {
                    Text(serverUrl.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(color.opacity(0.08).ignoresSafeArea())
    }

    // MARK: - Stats

    private var statsContent: some View {
        VStack(spacing: 20) {
            // Period picker
            HStack {
                Text("Estadísticas")
                    .font(.title3.bold())
                Spacer()
                Picker("Período", selection: Binding(
                    get: { vm.period },
                    set: { vm.setPeriod($0) }
                )) {
                    Text("Semanal").tag("week")
                    Text("Mensual").tag("month")
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            // Summary cards
            HStack(spacing: 12) {
                statCard(title: "Reproducciones", value: "\(vm.totalPlays)")
                if let genre = vm.topGenre {
                    statCard(title: "Género favorito", value: genre)
                }
            }

            // Last scrobble
            if let scrobble = vm.lastScrobble {
                profileCard {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.title3)
                            .foregroundStyle(color)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Último scrobble")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(scrobble.title)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                            Text(scrobble.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(scrobble.playedAt, format: .dateTime.day().month(.abbreviated).hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }

            // Top Songs
            if !vm.topSongs.isEmpty {
                profileCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Top Canciones")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        ForEach(Array(vm.topSongs.enumerated()), id: \.offset) { index, song in
                            if index > 0 { Divider().padding(.leading, 60) }
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                if let coverArt = song.coverArt,
                                   let url = NavidromeService.shared.coverURL(id: coverArt, size: 80) {
                                    AsyncImage(url: url) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Color(.tertiarySystemFill)
                                    }
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(.tertiarySystemFill))
                                        .frame(width: 40, height: 40)
                                        .overlay {
                                            Image(systemName: "music.note")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                }

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(song.title)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(song.artist)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(song.plays)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            // Top Artists
            if !vm.topArtists.isEmpty {
                profileCard {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Top Artistas")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)

                        ForEach(Array(vm.topArtists.enumerated()), id: \.offset) { index, artist in
                            if index > 0 { Divider().padding(.leading, 60) }
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                // Artist avatar circle with initial
                                ZStack {
                                    Circle()
                                        .fill(avatarColor(for: artist.artist).opacity(0.8))
                                    Text(avatarInitial(for: artist.artist))
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 40, height: 40)

                                Text(artist.artist)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(artist.plays)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            // Empty state
            if vm.totalPlays == 0 && vm.topSongs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No hay reproducciones registradas")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
    }

    // MARK: - Helpers

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func profileCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
