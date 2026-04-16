import SwiftUI

// MARK: - LoginView

struct LoginView: View {
    var onSuccess: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var serverUrl = ""
    @State private var username  = ""
    @State private var password  = ""
    @State private var status: LoginStatus = .idle

    private var canSubmit: Bool {
        !serverUrl.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        status != .loading
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "music.note.house.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.tint)
                            .padding(.bottom, 4)
                        Text("Conectar a Navidrome")
                            .font(.system(size: 26, weight: .bold))
                        Text("Introduce los datos de tu servidor para acceder a tu biblioteca.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)

                    // Fields
                    VStack(spacing: 0) {
                        field(label: "URL del servidor", placeholder: "http://192.168.1.10:4533", text: $serverUrl)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Divider().padding(.leading, 16)
                        field(label: "Usuario", placeholder: "admin", text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Divider().padding(.leading, 16)
                        secureField(label: "Contraseña", placeholder: "••••••••", text: $password)
                            .textContentType(.password)
                    }
                    .background(Color(.secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // Status message
                    if case .error(let msg) = status {
                        Label(msg, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 4)
                    }
                    if case .success = status {
                        Label("Conectado correctamente", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 4)
                    }

                    // Connect button
                    Button(action: connect) {
                        Group {
                            if status == .loading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Conectar")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .background(canSubmit ? Color.accentColor : Color.secondary.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(canSubmit ? .white : .secondary)
                    .disabled(!canSubmit)
                    .animation(.easeInOut(duration: 0.2), value: canSubmit)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }

    // MARK: - Field builders

    private func field(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.horizontal, 16)
            TextField(placeholder, text: text)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private func secureField(label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
                .padding(.horizontal, 16)
            SecureField(placeholder, text: text)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    // MARK: - Connect action

    private func connect() {
        status = .loading
        let rawUrl = serverUrl.trimmingCharacters(in: .whitespaces)
                               .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let user = username.trimmingCharacters(in: .whitespaces)

        Task {
            // Convert plain password to enc:HEX token (same as navidromeApi.ts)
            let hex = password.utf8.map { String(format: "%02x", $0) }.joined()
            let token = "enc:\(hex)"

            let u = user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user
            let p = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
            let pingURLStr = "\(rawUrl)/rest/ping.view?u=\(u)&p=\(p)&v=1.16.0&c=audiorr&f=json"

            guard let url = URL(string: pingURLStr) else {
                await MainActor.run { status = .error("URL inválida") }
                return
            }

            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                struct PingOuter: Decodable { let subsonicResponse: PingInner
                    enum CodingKeys: String, CodingKey { case subsonicResponse = "subsonic-response" }
                }
                struct PingInner: Decodable { let status: String }

                let ping = try JSONDecoder().decode(PingOuter.self, from: data)
                guard ping.subsonicResponse.status == "ok" else {
                    await MainActor.run { status = .error("Credenciales incorrectas") }
                    return
                }

                let creds = NavidromeCredentials(serverUrl: rawUrl, username: user, token: token)
                NavidromeService.shared.saveCredentials(creds)
                // Bridge credentials to WKWebView localStorage so Capacitor tabs keep working
                if let data = try? JSONEncoder().encode(creds),
                   let json = String(data: data, encoding: .utf8) {
                    let escaped = json
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                    let script = "localStorage.setItem('navidromeConfig', '\(escaped)')"
                    (UIApplication.shared.delegate as? AppDelegate)?.evalJSPublic(script)
                }

                await MainActor.run {
                    status = .success
                    // Brief delay so the success state is visible before dismissing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        dismiss()
                        onSuccess?()
                    }
                }
            } catch {
                await MainActor.run {
                    status = .error("No se pudo conectar: \(error.localizedDescription)")
                }
            }
        }
    }
}

// MARK: - Login status

private enum LoginStatus: Equatable {
    case idle, loading, success, error(String)
}
