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

    @Published var hasBackend = false

    private let settingsKey = "audiorr_settings"

    enum ScrobbleStatus { case idle, testing, success, error }

    func load() {
        hasBackend = NavidromeService.shared.backendURL() != nil
        loadJSSettings()
        loadScrobble()

        if hasBackend {
            Task { await loadLastFmConfig() }
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
        (UIApplication.shared.delegate as? AppDelegate)?.evalJSPublic(script)
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
        (UIApplication.shared.delegate as? AppDelegate)?.evalJSPublic(script)

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

        // Clear JS side too
        let script = """
        localStorage.removeItem('navidromeConfig');
        window.location.reload();
        """
        (UIApplication.shared.delegate as? AppDelegate)?.evalJSPublic(script)
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @StateObject private var vm = SettingsViewModel()
    @ObservedObject private var theme = AppTheme.shared
    @State private var showLogoutConfirm = false
    @State private var showSaveAlert = false
    @State private var alertMessage = ""

    var body: some View {
        List {
            // ── Apariencia ──
            Section {
                HStack {
                    Label("Modo oscuro", systemImage: "moon.fill")
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { theme.isDark },
                        set: { newValue in
                            (UIApplication.shared.delegate as? AppDelegate)?.applyTheme(isDark: newValue)
                        }
                    ))
                    .labelsHidden()
                }
            } header: {
                Text("Apariencia")
            }

            // ── Reproduccion ──
            if vm.hasBackend {
                Section {
                    HStack {
                        Label("Modo DJ", systemImage: "dial.medium.fill")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.isDjMode },
                            set: { _ in vm.toggleDjMode() }
                        ))
                        .labelsHidden()
                    }

                    HStack {
                        Label("ReplayGain", systemImage: "speaker.wave.2.fill")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.useReplayGain },
                            set: { _ in vm.toggleReplayGain() }
                        ))
                        .labelsHidden()
                    }
                } header: {
                    Text("Reproduccion")
                } footer: {
                    Text("Modo DJ activa mezclas dinamicas. ReplayGain normaliza el volumen entre canciones.")
                }
            }

            // ── Last.fm ──
            if vm.hasBackend {
                Section {
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
                    .padding(.vertical, 4)

                    // Scrobbling toggle
                    HStack {
                        Label("Scrobbling", systemImage: "arrow.up.right.circle.fill")
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { vm.scrobbleEnabled },
                            set: { vm.toggleScrobble($0) }
                        ))
                        .labelsHidden()
                    }

                    if vm.scrobbleEnabled {
                        HStack {
                            scrobbleStatusBadge
                            Spacer()
                            Button("Probar") { vm.testScrobble() }
                                .font(.subheadline)
                                .disabled(vm.scrobbleStatus == .testing)
                        }
                    }
                } header: {
                    Text("Last.fm")
                } footer: {
                    if vm.scrobbleEnabled {
                        Text("Las escuchas se registraran automaticamente tras reproducir al menos el 50% o 4 minutos.")
                    }
                }
            }

            // ── Servidor ──
            Section {
                if let creds = NavidromeService.shared.credentials {
                    LabeledContent("Servidor", value: creds.serverUrl)
                        .font(.subheadline)
                    LabeledContent("Usuario", value: creds.username)
                        .font(.subheadline)
                }

                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    Label("Cerrar sesion", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } header: {
                Text("Servidor")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
        .navigationTitle("Configuracion")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
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
