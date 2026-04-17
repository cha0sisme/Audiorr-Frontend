import SwiftUI

// MARK: - View Model

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var isDjMode = false
    @Published var useReplayGain = true
    @Published var scrobbleEnabled = false

    @Published var lastfmApiKey = ""
    @Published var lastfmHasSecret = false
    @Published var scrobbleStatus: ScrobbleStatus = .idle

    @Published var isBackendAvailable = false

    private let settingsKey = "audiorr_settings"

    enum ScrobbleStatus { case idle, testing, success, error }

    func load() {
        loadJSSettings()
        loadScrobble()

        Task {
            isBackendAvailable = await NavidromeService.shared.checkBackendAvailable()
            if isBackendAvailable {
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
    }

    private func saveJSSettings() {
        let dict: [String: Any] = [
            "isDjMode": isDjMode,
            "useWebAudio": false,
            "useReplayGain": useReplayGain,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8)
        else { return }

        // Persist locally
        UserDefaults.standard.set(json, forKey: settingsKey)

        // Bridge to JS localStorage so React picks it up
        let escaped = json.replacingOccurrences(of: "'", with: "\\'")
        let script = "localStorage.setItem('\(settingsKey)', '\(escaped)')"
        JSBridge.shared.eval(script)
    }

    func toggleDjMode() {
        isDjMode.toggle()
        saveJSSettings()
    }

    func toggleReplayGain() {
        useReplayGain.toggle()
        saveJSSettings()
    }

    // MARK: - Scrobble

    private func loadScrobble() {
        scrobbleEnabled = UserDefaults.standard.bool(forKey: "scrobbleEnabled")
    }

    func toggleScrobble(_ enabled: Bool) {
        scrobbleEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "scrobbleEnabled")

        let script = "localStorage.setItem('scrobbleEnabled', '\(enabled ? "true" : "false")')"
        JSBridge.shared.eval(script)

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

        // Clear JS side
        let script = "localStorage.removeItem('navidromeConfig')"
        JSBridge.shared.eval(script)

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
                Text("Configuracion")
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(stickyOpacity)
            }
        }
        .preferredColorScheme(theme.colorScheme)
        .onAppear { vm.load() }
        .alert("Last.fm", isPresented: $showSaveAlert) {
            Button("OK") {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog("Cerrar sesion", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Cerrar sesion", role: .destructive) {
                vm.logout()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se borrara la configuracion del servidor.")
        }
    }

    // MARK: - Large header

    private var largeHeader: some View {
        HStack(alignment: .bottom) {
            Text("Configuracion")
                .font(.system(size: 34, weight: .bold))
            Spacer()
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
                    Toggle("", isOn: Binding(
                        get: { theme.isDark },
                        set: { newValue in
                            AppTheme.shared.isDark = newValue
                            UserDefaults.standard.set(newValue, forKey: "audiorr_isDark")
                            JSBridge.shared.eval("document.documentElement.classList.toggle('dark', \(newValue))")
                        }
                    ))
                    .labelsHidden()
                }
            }

            // ── Reproduccion ──
            if vm.isBackendAvailable {
                settingsSection(
                    header: "Reproduccion",
                    footer: "Modo DJ activa mezclas dinamicas. ReplayGain normaliza el volumen entre canciones."
                ) {
                    settingsRow {
                        Label("Modo DJ", systemImage: "dial.medium.fill")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.isDjMode },
                            set: { _ in vm.toggleDjMode() }
                        ))
                        .labelsHidden()
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
            }

            // ── Last.fm ──
            if vm.isBackendAvailable {
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
                        Label("Cerrar sesion", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 100)
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
