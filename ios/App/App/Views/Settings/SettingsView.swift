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
        .overlay(alignment: .top) {
            stickyTitleBar
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showProfile) {
            UserProfileSheet(username: username)
        }
        .preferredColorScheme(theme.colorScheme)
        .onAppear {
            vm.load()
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

    // MARK: - Sticky title bar (replaces toolbar to avoid touch interception)

    private var stickyTitleBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }

            Spacer()

            Text(L.settings)
                .font(.headline)
                .lineLimit(1)
                .opacity(stickyOpacity)

            Spacer()

            if !username.isEmpty && BackendState.shared.isAvailable {
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
                .opacity(stickyOpacity)
            } else {
                Color.clear.frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top ?? 59)
        .padding(.bottom, 10)
        .background(.bar.opacity(stickyOpacity))
    }

    // MARK: - Large header

    private var username: String {
        NavidromeService.shared.credentials?.username ?? ""
    }

    private var largeHeader: some View {
        HStack(alignment: .bottom) {
            Text(L.settings)
                .font(.system(size: 34, weight: .bold))
            Spacer()
            if !username.isEmpty && BackendState.shared.isAvailable {
                Button { showProfile = true } label: {
                    ZStack {
                        Circle()
                            .fill(avatarColor(for: username))
                        Text(avatarInitial(for: username))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)
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
            settingsSection(header: L.appearance) {
                settingsRow {
                    Label(L.darkMode, systemImage: "moon.fill")
                    Spacer()
                    Toggle("", isOn: $theme.isDark)
                    .labelsHidden()
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
                        Label(L.djMode, systemImage: "dial.medium.fill")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.isDjMode },
                            set: { _ in vm.toggleDjMode() }
                        ))
                        .labelsHidden()
                    }
                    Divider().padding(.leading, 16)
                }

                // Crossfade toggle (only when backend is unavailable — with backend, crossfade is always on)
                if !BackendState.shared.isAvailable {
                    settingsRow {
                        Label("Crossfade", systemImage: "arrow.triangle.swap")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.crossfadeEnabled },
                            set: { _ in vm.toggleCrossfade() }
                        ))
                        .labelsHidden()
                    }
                    if vm.crossfadeEnabled {
                        Divider().padding(.leading, 16)
                    }
                }

                // Crossfade duration slider (shown when crossfade is active)
                if BackendState.shared.isAvailable || vm.crossfadeEnabled {
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
                    Label(L.replayGain, systemImage: "speaker.wave.2.fill")
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
                        ? L.scrobbleFooter
                        : nil
                ) {
                    settingsRow {
                        Label(L.scrobbling, systemImage: "arrow.up.right.circle.fill")
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

            // ── Debug / Diagnostics (only visible in debug mode) ──
            if TransitionDiagnostics.debugModeEnabled {
                settingsSection(header: "Debug") {
                    NavigationLink {
                        TransitionDiagnosticsView()
                    } label: {
                        settingsRow {
                            Label("Transition Diagnostics", systemImage: "waveform.badge.magnifyingglass")
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

                    settingsRow {
                        Label("Backend", systemImage: "server.rack")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(BackendState.shared.isAvailable ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(BackendState.shared.isAvailable ? "Connected" : "Disconnected")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
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
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 100)
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
            List {
                // Account header
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(color.gradient)
                            Text(initial)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 60, height: 60)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(username)
                                .font(.title3.bold())
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
                    .padding(.vertical, 4)
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                }

                if vm.isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }
                } else if vm.totalPlays == 0 && vm.topSongs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            L.noActivity,
                            systemImage: "music.note.list",
                            description: Text(L.listensWillAppear)
                        )
                        .listRowBackground(Color(.systemGroupedBackground))
                    }
                } else {
                    // Period picker + summary
                    Section {
                        Picker(L.period, selection: Binding(
                            get: { vm.period },
                            set: { vm.setPeriod($0) }
                        )) {
                            Text(L.weekly).tag("week")
                            Text(L.monthly).tag("month")
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color(.systemGroupedBackground))
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.plays)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(vm.totalPlays)")
                                    .font(.title.bold())
                            }
                            Spacer()
                            if let genre = vm.topGenre {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(L.topGenre)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(genre)
                                        .font(.title3.bold())
                                        .lineLimit(1)
                                }
                            }
                        }
                        .listRowBackground(Color(.secondarySystemGroupedBackground))
                    }

                    // Last scrobble
                    if let scrobble = vm.lastScrobble {
                        Section(L.lastScrobble) {
                            HStack(spacing: 12) {
                                Image(systemName: "music.note")
                                    .font(.title3)
                                    .foregroundStyle(color)
                                    .frame(width: 24)
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
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .listRowBackground(Color(.secondarySystemGroupedBackground))
                        }
                    }

                    // Top Songs
                    if !vm.topSongs.isEmpty {
                        Section(L.topSongs) {
                            ForEach(Array(vm.topSongs.enumerated()), id: \.offset) { index, song in
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
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    } else {
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(.tertiarySystemFill))
                                            .frame(width: 44, height: 44)
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
                                    Text(L.playsCount(song.plays))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .listRowBackground(Color(.secondarySystemGroupedBackground))
                            }
                        }
                    }

                    // Top Artists
                    if !vm.topArtists.isEmpty {
                        Section(L.topArtists) {
                            ForEach(Array(vm.topArtists.enumerated()), id: \.offset) { index, artist in
                                HStack(spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20)
                                    ZStack {
                                        Circle()
                                            .fill(avatarColor(for: artist.artist))
                                        Text(avatarInitial(for: artist.artist))
                                            .font(.system(size: 15, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                    }
                                    .frame(width: 44, height: 44)

                                    Text(artist.artist)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(L.playsCount(artist.plays))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .listRowBackground(Color(.secondarySystemGroupedBackground))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
}
