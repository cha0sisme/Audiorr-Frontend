import SwiftUI

/// Alias local del modelo de sesión expuesto por `BackendService` — evita
/// arrastrar el prefijo `BackendService.` por toda la vista. Internal (no
/// private) porque lo exponen miembros internal del view model.
typealias SessionInfo = BackendService.SessionView

// MARK: - View Model

@MainActor
final class SessionsViewModel: ObservableObject {
    @Published var sessions: [SessionInfo] = []
    @Published var isLoading = true
    @Published var isClosingOthers = false
    @Published var errorMessage: String?

    /// Sesión de ESTE dispositivo (la decide el backend, no el cliente).
    var currentSession: SessionInfo? { sessions.first { $0.current } }

    /// Resto de sesiones, ya ordenadas por actividad más reciente.
    var otherSessions: [SessionInfo] { sessions.filter { !$0.current } }

    func load() async {
        // Solo mostramos el spinner a pantalla completa en la primera carga;
        // en un refresh manual conservamos la lista visible.
        isLoading = sessions.isEmpty
        errorMessage = nil
        do {
            let fetched = try await BackendService.shared.getSessions()
            // Este dispositivo primero; el resto por última actividad descendente.
            sessions = fetched.sorted {
                if $0.current != $1.current { return $0.current }
                return $0.lastSeen > $1.lastSeen
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func close(_ session: SessionInfo) async {
        do {
            try await BackendService.shared.closeSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func closeOthers() async {
        isClosingOthers = true
        defer { isClosingOthers = false }
        do {
            _ = try await BackendService.shared.closeOtherSessions()
            // Conservamos solo la sesión actual.
            sessions = sessions.filter { $0.current }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Sessions View

/// Pantalla "Dispositivos": gestiona las sesiones Bearer activas del usuario.
/// Solo se muestra cuando hay backend Audiorr (`BackendState.isAvailable`);
/// el `NavigationLink` que la abre está gateado en `SettingsView`.
struct SessionsView: View {
    @StateObject private var vm = SessionsViewModel()
    @State private var showCloseOthersConfirm = false

    var body: some View {
        Group {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.sessions.isEmpty, let error = vm.errorMessage {
                ContentUnavailableView {
                    Label("No se pudieron cargar las sesiones", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Reintentar") { Task { await vm.load() } }
                }
            } else if vm.sessions.isEmpty {
                ContentUnavailableView(
                    "Sin sesiones activas",
                    systemImage: "iphone.gen3",
                    description: Text("No hay ninguna sesión iniciada en este momento.")
                )
            } else {
                sessionsList
            }
        }
        .navigationTitle("Sesiones")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Refresco periódico mientras la pantalla está abierta: el estado
            // "activa" (vista hace <5s) depende del `lastSeen` del servidor, así
            // que repescamos cada pocos segundos para que la presencia en vivo
            // sea fiable (como los indicadores de sesión "pro"). El bucle se
            // cancela solo al salir de la vista.
            await vm.load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                await vm.load()
            }
        }
        .refreshable { await vm.load() }
    }

    // MARK: - List

    private var sessionsList: some View {
        List {
            if let current = vm.currentSession {
                Section("Este dispositivo") {
                    sessionRow(current, isCurrent: true)
                }
            }

            if !vm.otherSessions.isEmpty {
                Section("Otras sesiones") {
                    ForEach(vm.otherSessions) { session in
                        sessionRow(session, isCurrent: false)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await vm.close(session) }
                                } label: {
                                    Label("Cerrar", systemImage: "xmark")
                                }
                            }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showCloseOthersConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            if vm.isClosingOthers {
                                ProgressView()
                            } else {
                                Text("Cerrar el resto de sesiones")
                            }
                            Spacer()
                        }
                    }
                    .disabled(vm.isClosingOthers)
                } footer: {
                    Text("Cierra todas las sesiones excepto la de este dispositivo. Tendrás que volver a iniciar sesión en los demás.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            "¿Cerrar el resto de sesiones?",
            isPresented: $showCloseOthersConfirm,
            titleVisibility: .visible
        ) {
            Button("Cerrar el resto", role: .destructive) {
                Task { await vm.closeOthers() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se cerrará la sesión en todos los demás dispositivos. Esta seguirá activa.")
        }
    }

    // MARK: - Row

    private func sessionRow(_ session: SessionInfo, isCurrent: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: platformIcon(session.platform))
                .font(.title2)
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(isCurrent ? "Este iPhone" : platformName(session.platform))
                    .font(.body.weight(.medium))

                HStack(spacing: 5) {
                    Text(countryLabel(session.country))
                    if let ip = session.ip, !ip.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(ip).foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                lastSeenLabel(session, isCurrent: isCurrent)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isActive(session) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                    Text("Activa")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Una sesión está "activa" si es la de este dispositivo o si el servidor
    /// la vio hace menos de 5 segundos (presencia en vivo, estilo apps pro).
    /// Como `lastSeen` lo refresca el backend, la pantalla repesca cada pocos
    /// segundos para que el indicador siga la realidad.
    private func isActive(_ session: SessionInfo) -> Bool {
        if session.current { return true }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return (nowMs - session.lastSeen) < 5000
    }

    // MARK: - Formatters

    private func platformIcon(_ platform: String?) -> String {
        switch platform?.lowercased() {
        case "ios":     return "iphone.gen3"
        case "android": return "candybarphone"
        case "web":     return "globe"
        default:        return "questionmark.circle"
        }
    }

    private func platformName(_ platform: String?) -> String {
        switch platform?.lowercased() {
        case "ios":     return "iOS"
        case "android": return "Android"
        case "web":     return "Navegador web"
        default:        return "Dispositivo desconocido"
        }
    }

    /// País a partir del ISO alpha-2: bandera emoji + código. "Desconocido"
    /// cuando el backend no lo puebla (LAN/homelab, o sesiones legacy previas
    /// al deploy de Cloudflare).
    private func countryLabel(_ code: String?) -> String {
        guard let code, code.count == 2, code.allSatisfy(\.isLetter) else { return "Desconocido" }
        let flag = code.uppercased().unicodeScalars.reduce(into: "") { result, scalar in
            if let regional = UnicodeScalar(127_397 + scalar.value) {
                result.unicodeScalars.append(regional)
            }
        }
        return "\(flag) \(code.uppercased())"
    }

    @ViewBuilder
    private func lastSeenLabel(_ session: SessionInfo, isCurrent: Bool) -> some View {
        let date = Date(timeIntervalSince1970: session.lastSeen / 1000)
        if isActive(session) {
            Text("En uso ahora")
        } else {
            Text("Vista \(date, format: .relative(presentation: .named))")
        }
    }
}
