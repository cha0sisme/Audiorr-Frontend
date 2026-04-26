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
    @Published var isDjMode = true
    @Published var useReplayGain = true
    @Published var crossfadeEnabled = false
    @Published var crossfadeDuration: Double = 8  // seconds (2–15)
    @Published var scrobbleEnabled = false

    @Published var scrobbleStatus: ScrobbleStatus = .idle

    private let settingsKey = "audiorr_settings"

    enum ScrobbleStatus { case idle, testing, success, error }

    func load() {
        loadJSSettings()
        loadScrobble()
        // Clear any leftover backend URL override when not in debug mode
        if !TransitionDiagnostics.debugModeEnabled {
            NavidromeService.shared.setBackendOverride(nil)
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
        // DJ mode requires crossfade — enable it if turning DJ mode on
        if isDjMode { crossfadeEnabled = true }
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
    @ObservedObject private var localization = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showLogoutConfirm = false
    @State private var showSaveAlert = false
    @State private var showProfile = false
    @State private var alertMessage = ""
    @State private var backendURLOverride: String = ""

    var body: some View {
        ScrollView {
            settingsContent
        }
        .background(Color(.systemBackground))
        .navigationTitle(L.settings)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if !username.isEmpty && BackendState.shared.isAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showProfile = true } label: {
                        ZStack {
                            Circle()
                                .fill(avatarColor(for: username))
                            Text(avatarInitial(for: username))
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 30, height: 30)
                    }
                }
            }
        }
        .sheet(isPresented: $showProfile) {
            UserProfileSheet(username: username)
        }
        .preferredColorScheme(theme.colorScheme)
        .onAppear {
            vm.load()
            if UserDefaults.standard.object(forKey: "audiorr_diagnostics_enabled") != nil {
                TransitionDiagnostics.debugModeEnabled = UserDefaults.standard.bool(forKey: "audiorr_diagnostics_enabled")
            }
            if TransitionDiagnostics.debugModeEnabled {
                backendURLOverride = UserDefaults.standard.string(forKey: "audiorr_backend_url") ?? ""
            }
        }
        .alert("Last.fm", isPresented: $showSaveAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog(L.logout, isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button(L.logout, role: .destructive) {
                vm.logout()
            }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.logoutConfirm)
        }
    }

    // MARK: - Helpers

    private var username: String {
        NavidromeService.shared.credentials?.username ?? ""
    }

    // MARK: - Settings content

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // ── Apariencia ──
            settingsSection(header: L.appearance) {
                settingsRow {
                    Label(L.appearance, systemImage: "circle.lefthalf.filled")
                    Spacer()
                    Picker("", selection: $theme.mode) {
                        Text(L.systemMode).tag(AppTheme.Mode.system)
                        Text(L.lightMode).tag(AppTheme.Mode.light)
                        Text(L.darkModeShort).tag(AppTheme.Mode.dark)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
            }

            // ── Reproducción ──
            settingsSection(
                header: L.playback,
                footer: crossfadeFooter
            ) {
                // DJ Mode toggle (only when backend is available)
                if BackendState.shared.isAvailable {
                    settingsRow {
                        Toggle(isOn: Binding(
                            get: { vm.isDjMode },
                            set: { _ in vm.toggleDjMode() }
                        )) {
                            Label(L.djMode, systemImage: "dial.medium.fill")
                        }
                    }
                    Divider().padding(.leading, 16)
                }

                // Crossfade toggle (only when backend is unavailable — with backend, crossfade is always on)
                if !BackendState.shared.isAvailable {
                    settingsRow {
                        Toggle(isOn: Binding(
                            get: { vm.crossfadeEnabled },
                            set: { _ in vm.toggleCrossfade() }
                        )) {
                            Label("Crossfade", systemImage: "arrow.triangle.swap")
                        }
                    }
                    if vm.crossfadeEnabled {
                        Divider().padding(.leading, 16)
                    }
                }

                // Crossfade duration slider (only without backend + crossfade enabled)
                if !BackendState.shared.isAvailable && vm.crossfadeEnabled {
                    settingsRow {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(L.duration, systemImage: "timer")
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

                Divider().padding(.leading, 16)
                settingsRow {
                    Toggle(isOn: Binding(
                        get: { vm.useReplayGain },
                        set: { _ in vm.toggleReplayGain() }
                    )) {
                        Label(L.replayGain, systemImage: "speaker.wave.2.fill")
                    }
                }
            }

            // ── Last.fm ──
            if BackendState.shared.isAvailable {
                settingsSection(
                    header: "Last.fm",
                    footer: vm.scrobbleEnabled
                        ? L.scrobbleFooter
                        : nil
                ) {
                    settingsRow {
                        Toggle(isOn: Binding(
                            get: { vm.scrobbleEnabled },
                            set: { vm.toggleScrobble($0) }
                        )) {
                            Label(L.scrobbling, systemImage: "arrow.up.right.circle.fill")
                        }
                    }
                    if vm.scrobbleEnabled {
                        Divider().padding(.leading, 16)
                        settingsRow {
                            scrobbleStatusBadge
                            Spacer()
                            Button(L.test) { vm.testScrobble() }
                                .font(.subheadline)
                                .disabled(vm.scrobbleStatus == .testing)
                        }
                    }
                }
            }

            // ── Idioma ──
            settingsSection(header: L.language) {
                settingsRow {
                    Picker(L.language, selection: $localization.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                }
            }

            // ── Almacenamiento offline ──
            settingsSection(header: L.storage) {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    settingsRow {
                        Label(L.manageStorage, systemImage: "externaldrive")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // ── Transition Diagnostics ──
            if BackendState.shared.isAvailable && TransitionDiagnostics.debugModeEnabled {
                settingsSection(header: "Diagnostics") {
                    settingsRow {
                        Toggle(isOn: Binding(
                            get: { TransitionDiagnostics.debugModeEnabled },
                            set: { newValue in
                                TransitionDiagnostics.debugModeEnabled = newValue
                                UserDefaults.standard.set(newValue, forKey: "audiorr_diagnostics_enabled")
                            }
                        )) {
                            Label("Transition Diagnostics", systemImage: "waveform.badge.magnifyingglass")
                                .font(.subheadline)
                        }
                        .tint(.cyan)
                    }

                    if TransitionDiagnostics.debugModeEnabled {
                        Divider().padding(.leading, 16)

                        NavigationLink {
                            TransitionDiagnosticsView()
                        } label: {
                            settingsRow {
                                Label("View Diagnostics", systemImage: "chart.bar.doc.horizontal")
                                Spacer()
                                if NowPlayingState.shared.isCrossfading {
                                    Text("ACTIVE")
                                        .font(.caption.bold())
                                        .foregroundStyle(.cyan)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Divider().padding(.leading, 16)

                        // Backend URL override (debug only)
                        settingsRow {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Backend URL")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("Auto (\(NavidromeService.shared.backendURL() ?? "N/A"))",
                                          text: $backendURLOverride)
                                    .font(.subheadline)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        NavidromeService.shared.setBackendOverride(
                                            backendURLOverride.isEmpty ? nil : backendURLOverride
                                        )
                                    }

                                HStack(spacing: 10) {
                                    Button("Apply") {
                                        NavidromeService.shared.setBackendOverride(
                                            backendURLOverride.isEmpty ? nil : backendURLOverride
                                        )
                                    }
                                    .font(.caption.bold())
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)

                                    if NavidromeService.shared.hasBackendOverride {
                                        Button("Reset to Auto") {
                                            backendURLOverride = ""
                                            NavidromeService.shared.setBackendOverride(nil)
                                        }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(.orange)
                                    }

                                    Spacer()
                                }
                            }
                        }

                        Divider().padding(.leading, 16)

                        settingsRow {
                            Button {
                                BackendState.shared.invalidateAndRecheck()
                            } label: {
                                Label("Retry Connection", systemImage: "arrow.clockwise")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }

            // ── Servidor ──
            settingsSection(header: L.server) {
                if let creds = NavidromeService.shared.credentials {
                    settingsRow {
                        Text(L.server)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(creds.serverUrl)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    Divider().padding(.leading, 16)
                    settingsRow {
                        Text(L.user)
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
                        Label(L.logout, systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            // ── Credits ──
            creditsFooter
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 100)
    }

    // MARK: - Credits footer

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var creditsFooter: some View {
        VStack(spacing: 6) {
            Image("AudiorrTabIcon")
                .resizable()
                .scaledToFit()
                .frame(height: 28)
                .opacity(0.4)

            Text("Audiorr v\(appVersion)")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Link(destination: URL(string: "https://github.com/cha0sisme")!) {
                Text("cha0sisme")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    // MARK: - Dynamic footers

    private var crossfadeFooter: String {
        if BackendState.shared.isAvailable {
            if vm.isDjMode {
                return L.crossfadeFooterDjOn()
            }
            return L.crossfadeFooterBackend()
        }
        return L.crossfadeFooterOn(Int(vm.crossfadeDuration))
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
            Label(L.active, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(L.testing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .success:
            Label(L.correct, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Label(L.error, systemImage: "xmark.circle.fill")
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
    @Published var topArtists: [(artist: String, plays: Int, image: UIImage?)] = []

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
                    (artist: a["artist"] as? String ?? "", plays: a["plays"] as? Int ?? 0, image: nil)
                }
                // Resolve artist avatars in background
                await resolveArtistAvatars()
            }
        } catch {
            print("[UserProfile] Stats fetch failed: \(error)")
        }
    }

    private func resolveArtistAvatars() async {
        let api = NavidromeService.shared
        guard BackendState.shared.isAvailable else { return }
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            for (i, artist) in topArtists.enumerated() {
                group.addTask {
                    guard let url = await api.artistImageURL(name: artist.artist),
                          let (data, _) = try? await URLSession.shared.data(from: url),
                          let img = UIImage(data: data) else { return (i, nil) }
                    return (i, img)
                }
            }
            for await (index, image) in group {
                if index < topArtists.count, let img = image {
                    topArtists[index].image = img
                }
            }
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
                    // ── Hero header ──
                    profileHeader
                        .padding(.top, 24)
                        .padding(.bottom, 20)

                    if vm.isLoading {
                        ProgressView()
                            .padding(.top, 60)
                    } else if vm.totalPlays == 0 && vm.topSongs.isEmpty {
                        ContentUnavailableView(
                            L.noActivity,
                            systemImage: "music.note.list",
                            description: Text(L.listensWillAppear)
                        )
                        .padding(.top, 40)
                    } else {
                        // ── Period picker ──
                        Picker(L.period, selection: Binding(
                            get: { vm.period },
                            set: { vm.setPeriod($0) }
                        )) {
                            Text(L.weekly).tag("week")
                            Text(L.monthly).tag("month")
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)

                        // ── Stat cards ──
                        statsRow
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)

                        // ── Last scrobble ──
                        if let scrobble = vm.lastScrobble {
                            lastScrobbleRow(scrobble)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 24)
                        }

                        // ── Top Songs ──
                        if !vm.topSongs.isEmpty {
                            sectionHeader(L.topSongs)
                            VStack(spacing: 0) {
                                ForEach(Array(vm.topSongs.enumerated()), id: \.offset) { index, song in
                                    topSongRow(index: index, song: song)
                                    if index < vm.topSongs.count - 1 {
                                        Divider().padding(.leading, 78)
                                    }
                                }
                            }
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 24)
                        }

                        // ── Top Artists ──
                        if !vm.topArtists.isEmpty {
                            sectionHeader(L.topArtists)
                            VStack(spacing: 0) {
                                ForEach(Array(vm.topArtists.enumerated()), id: \.offset) { index, artist in
                                    topArtistRow(index: index, artist: artist)
                                    if index < vm.topArtists.count - 1 {
                                        Divider().padding(.leading, 78)
                                    }
                                }
                            }
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.horizontal, 16)
                            .padding(.bottom, 40)
                        }
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(L.profile)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.close) { dismiss() }
                }
            }
            .onAppear { vm.load() }
        }
    }

    // MARK: - Hero header

    private var profileHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(color.gradient)
                    .shadow(color: color.opacity(0.4), radius: 12, y: 6)
                Text(initial)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 80, height: 80)

            VStack(spacing: 4) {
                Text(username)
                    .font(.title2.bold())

                if let date = vm.lastConnection {
                    Text("Activo \(date, format: .relative(presentation: .named))")
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
    }

    // MARK: - Stats row (Apple Fitness style)

    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard(
                label: L.plays,
                value: "\(vm.totalPlays)",
                icon: "play.circle.fill",
                tint: .pink
            )
            if let genre = vm.topGenre {
                statCard(
                    label: L.topGenre,
                    value: genre,
                    icon: "guitars.fill",
                    tint: .purple
                )
            }
        }
    }

    private func statCard(label: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Last scrobble

    private func lastScrobbleRow(_ scrobble: (title: String, artist: String, playedAt: Date)) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.body.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(scrobble.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(scrobble.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(scrobble.playedAt, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.title3.bold())
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Top song row

    private func topSongRow(index: Int, song: (id: String, title: String, artist: String, coverArt: String?, plays: Int)) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            if let coverArt = song.coverArt,
               let url = NavidromeService.shared.coverURL(id: coverArt, size: 80) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(.tertiarySystemFill)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(L.playsCount(song.plays))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Top artist row (real avatars)

    private func topArtistRow(index: Int, artist: (artist: String, plays: Int, image: UIImage?)) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            if let img = artist.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle()
                        .fill(avatarColor(for: artist.artist).opacity(0.25))
                    Text(avatarInitial(for: artist.artist))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(avatarColor(for: artist.artist))
                }
                .frame(width: 44, height: 44)
            }

            Text(artist.artist)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Text(L.playsCount(artist.plays))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
