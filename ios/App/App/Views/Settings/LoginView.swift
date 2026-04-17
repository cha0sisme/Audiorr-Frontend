import SwiftUI

// MARK: - LoginView (Apple Music style)

struct LoginView: View {
    var onSuccess: (() -> Void)?

    @State private var serverUrl = ""
    @State private var username  = ""
    @State private var password  = ""
    @State private var status: LoginStatus = .idle
    @State private var dismissPhase = false
    @FocusState private var focusedField: Field?

    private enum Field { case server, user, password }

    private var canSubmit: Bool {
        !serverUrl.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        status != .loading
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: max(geo.size.height * 0.08, 40))

                    // App icon
                    Image("AppIcon-512@2x")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
                        .padding(.bottom, 24)

                    // Title + monochrome logo
                    HStack(spacing: 10) {
                        Image("AudiorrTabIcon")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .foregroundStyle(.primary)

                        Text("Audiorr")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                    }
                    .padding(.bottom, 6)

                    Text("Conecta con tu servidor Navidrome\npara acceder a tu biblioteca de musica.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 36)

                    // Fields
                    VStack(spacing: 0) {
                        loginField(
                            icon: "globe",
                            label: "URL del servidor",
                            placeholder: "http://192.168.1.10:4533",
                            text: $serverUrl,
                            field: .server,
                            isSecure: false
                        )
                        divider
                        loginField(
                            icon: "person",
                            label: "Usuario",
                            placeholder: "admin",
                            text: $username,
                            field: .user,
                            isSecure: false
                        )
                        divider
                        loginField(
                            icon: "lock",
                            label: "Contraseña",
                            placeholder: "••••••••",
                            text: $password,
                            field: .password,
                            isSecure: true
                        )
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)

                    // Error / Success
                    if case .error(let msg) = status {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .padding(.top, 14)
                            .padding(.horizontal, 24)
                    }
                    if case .success = status {
                        Label("Conectado", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .padding(.top, 14)
                    }

                    // Connect button
                    Button(action: connect) {
                        Group {
                            if status == .loading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Iniciar sesión")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    }
                    .background(
                        canSubmit
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(Color.secondary.opacity(0.25))
                    )
                    .foregroundStyle(canSubmit ? .white : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(!canSubmit)
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .animation(.easeInOut(duration: 0.2), value: canSubmit)

                    Spacer(minLength: 40)
                }
                .frame(minHeight: geo.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemGroupedBackground))
        .opacity(dismissPhase ? 0 : 1)
        .scaleEffect(dismissPhase ? 1.05 : 1)
        .animation(.easeInOut(duration: 0.4), value: dismissPhase)
        .onSubmit {
            switch focusedField {
            case .server:   focusedField = .user
            case .user:     focusedField = .password
            case .password: if canSubmit { connect() }
            case nil:       break
            }
        }
    }

    // MARK: - Field builder

    private var divider: some View {
        Divider().padding(.leading, 52)
    }

    @ViewBuilder
    private func loginField(icon: String, label: String, placeholder: String,
                            text: Binding<String>, field: Field, isSecure: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                if !text.wrappedValue.isEmpty {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Group {
                    if isSecure {
                        SecureField(placeholder, text: text)
                            .textContentType(.password)
                            .keyboardType(.default)
                    } else if field == .server {
                        TextField(placeholder, text: text)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                    } else {
                        TextField(placeholder, text: text)
                            .textContentType(.username)
                            .keyboardType(.default)
                    }
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: field)
            }
            .animation(.easeInOut(duration: 0.15), value: text.wrappedValue.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Connect action

    private func connect() {
        focusedField = nil
        status = .loading
        let rawUrl = serverUrl.trimmingCharacters(in: .whitespaces)
                               .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Normalize username to lowercase for consistent auth
        let user = username.trimmingCharacters(in: .whitespaces).lowercased()

        Task {
            let hex = password.utf8.map { String(format: "%02x", $0) }.joined()
            let token = "enc:\(hex)"

            let u = user.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? user
            let p = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
            let pingURLStr = "\(rawUrl)/rest/ping.view?u=\(u)&p=\(p)&v=1.16.0&c=audiorr&f=json"

            guard let url = URL(string: pingURLStr) else {
                await MainActor.run { status = .error("URL invalida") }
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

                await MainActor.run {
                    status = .success
                    // Animate out, then dismiss
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        withAnimation {
                            dismissPhase = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            onSuccess?()
                        }
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
