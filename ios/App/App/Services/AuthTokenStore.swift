import Foundation
import Security

/// Persistent store for the Audiorr backend Bearer session
/// (`sessionToken + refreshToken` emitted by `POST /api/auth/login`).
///
/// Separado de `CredentialsStore` (Navidrome): este actor maneja unicamente
/// el par de tokens del backend Audiorr tras la migracion Cloudflare Zero
/// Trust. CredentialsStore sigue siendo la fuente de verdad para las
/// credenciales Navidrome usadas en streaming Subsonic.
///
/// Persistencia Keychain bajo service `com.audiorr.audiorr-session`. La
/// accesibilidad es `kSecAttrAccessibleAfterFirstUnlock` para permitir
/// lecturas en background (scrobble silencioso, lastPlayback save) tras el
/// primer unlock del device.
///
/// **Asimetria consciente** con CredentialsStore: ese store usa el default
/// `WhenUnlocked`. Cambiar el atributo de un item Keychain existente requiere
/// `delete + add` (SecItemUpdate NO muta accessibility), lo que invalidaria
/// las credenciales Navidrome ya guardadas en instalaciones activas. El path
/// critico de background no reentra a CredentialsStore en operacion normal —
/// solo si refreshToken expira y se requiere re-login con creds Navidrome.
/// En ese punto, si el device esta locked, `ensureSession()` falla graceful
/// y la request sale sin Bearer (degradacion al modo Navidrome puro).
///
/// **Estado inicial**: actor declarado pero INERTE. `save()` se enchufa
/// posteriormente desde `ConnectService.authenticate()`. `refresh()` se
/// cablea con `BackendService.refresh(refreshToken:)` — hasta entonces lanza
/// `AuthTokenError.notWiredYet`. Los gates de `backendUnauthorized` y
/// `lockedUntil` SI viven aqui desde el principio: cuando se enchufen el
/// resto de piezas, ya respetan cero trafico innecesario al backend.
actor AuthTokenStore {

    static let shared = AuthTokenStore()

    // MARK: - Types

    struct Session: Codable, Equatable {
        let sessionToken: String
        let refreshToken: String
        let expiresAt: Date
        let refreshExpiresAt: Date
        let isAdmin: Bool
        let username: String
    }

    enum AuthTokenError: LocalizedError {
        case notWiredYet
        case noCredentials
        case persistenceFailed

        var errorDescription: String? {
            switch self {
            case .notWiredYet:       "Auth flow not wired in this build"
            case .noCredentials:     "Navidrome credentials missing for re-login"
            case .persistenceFailed: "Could not persist session to Keychain"
            }
        }
    }

    // MARK: - Configuration

    private let keychainService = "com.audiorr.audiorr-session"
    private let keychainAccount = "session"
    private let preemptWindow: TimeInterval = 60  // refresh proactivo si vence en <60s

    // Keys UserDefaults. `static` porque los consumen helpers `nonisolated`
    // que no pueden tocar properties isolated del actor sin await.
    private static let lockedUntilKey         = "audiorr_session_locked_until"
    private static let backendUnauthorizedKey = "audiorr_session_backend_unauthorized_until"
    private static let unauthorizedTTL: TimeInterval = 86400  // 24h

    // MARK: - State

    private var cachedSession: Session?
    private var didLoadFromKeychain = false
    private var refreshInFlight: Task<String, Error>?
    private var ensureInFlight: Task<String?, Error>?

    private init() {}

    // MARK: - Public API

    /// Devuelve el sessionToken vigente. Hace preempt refresh si el token
    /// vence en menos de `preemptWindow`. Devuelve `nil` si no hay sesion
    /// o si el refreshToken tambien ha expirado.
    func currentToken() async -> String? {
        bootstrapIfNeeded()
        guard let session = cachedSession else { return nil }

        let now = Date()
        if session.expiresAt > now.addingTimeInterval(preemptWindow) {
            return session.sessionToken
        }

        if session.refreshExpiresAt <= now {
            clear()
            return nil
        }

        // Token caducando — intenta renovar antes de devolverlo.
        do {
            return try await refresh()
        } catch {
            return nil
        }
    }

    /// Persiste un par de tokens nuevo (tras login o tras refresh).
    /// Calcula `expiresAt` y `refreshExpiresAt` absolutos en base al reloj
    /// del device. Drift de reloj converge igual via path reactivo 401.
    /// Limpia el flag `backendUnauthorized` porque un login exitoso invalida
    /// cualquier 403 previo.
    func save(sessionToken: String,
              refreshToken: String,
              expiresIn: Int,
              refreshExpiresIn: Int,
              isAdmin: Bool,
              username: String) throws {
        let now = Date()
        let session = Session(
            sessionToken: sessionToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
            refreshExpiresAt: now.addingTimeInterval(TimeInterval(refreshExpiresIn)),
            isAdmin: isAdmin,
            username: username
        )
        try saveToKeychain(session)
        cachedSession = session
        didLoadFromKeychain = true
        clearBackendUnauthorized()
    }

    /// Limpia la sesion de memoria + Keychain. NO toca CredentialsStore
    /// (las creds Navidrome siguen vivas para un eventual re-login).
    func clear() {
        deleteFromKeychain()
        cachedSession = nil
        didLoadFromKeychain = true
    }

    /// Dispara refresh del par sessionToken+refreshToken contra el backend.
    /// Serializa concurrentes via shared in-flight Task: si varias Tasks
    /// reciben 401 simultaneo, solo una hace el POST /api/auth/refresh y
    /// las demas await el mismo resultado.
    ///
    /// **Stub inicial**: lanza `notWiredYet`. El cable real al
    /// `BackendService.refresh(refreshToken:)` aterriza en un cambio posterior.
    func refresh() async throws -> String {
        if let inflight = refreshInFlight {
            return try await inflight.value
        }
        let task = Task<String, Error> {
            throw AuthTokenError.notWiredYet
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    /// Asegura que hay un sessionToken valido. Si la sesion ha expirado por
    /// completo (refreshToken tambien caducado), intenta re-loguear con las
    /// credenciales Navidrome del `CredentialsStore`. Devuelve `nil` cuando:
    ///
    /// 1. Hay flag `backendUnauthorized` activo (TTL 24h tras un 403 previo).
    /// 2. Hay flag `lockedUntil` activo (TTL del Retry-After de un 429).
    /// 3. No hay credenciales Navidrome guardadas.
    /// 4. El re-login responde 401/403 (el caller debe quedarse en modo
    ///    Navidrome puro sin volver a intentar hasta que cambien las creds).
    ///
    /// **Estado inicial**: solo viven los gates anti-trafico
    /// (backendUnauthorized + lockedUntil) y el fast-path via `currentToken()`.
    /// El re-login real con CredentialsStore aterriza en un cambio posterior.
    func ensureSession() async throws -> String? {
        if let until = backendUnauthorizedUntil(), until > Date() {
            return nil
        }
        if let until = lockedUntil(), until > Date() {
            return nil
        }
        if let token = await currentToken() {
            return token
        }
        if let inflight = ensureInFlight {
            return try await inflight.value
        }
        let task = Task<String?, Error> {
            // TODO: leer CredentialsStore + invocar
            // BackendService.shared.login(...) + save() + return token.
            return nil
        }
        ensureInFlight = task
        defer { ensureInFlight = nil }
        return try await task.value
    }

    // MARK: - Lockout (429) — UserDefaults para sobrevivir cold launch

    /// Timestamp hasta cuando el backend rate-limit nos bloquea (Retry-After).
    /// Devuelve nil si no hay lockout o ya ha vencido. Hace auto-clear del
    /// valor vencido para no acumular basura.
    nonisolated func lockedUntil() -> Date? {
        let ts = UserDefaults.standard.double(forKey: Self.lockedUntilKey)
        guard ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        if date <= Date() {
            UserDefaults.standard.removeObject(forKey: Self.lockedUntilKey)
            return nil
        }
        return date
    }

    nonisolated func setLockedUntil(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lockedUntilKey)
    }

    nonisolated func clearLockedUntil() {
        UserDefaults.standard.removeObject(forKey: Self.lockedUntilKey)
    }

    // MARK: - Backend unauthorized gate (403)

    /// Marca el backend como inaccesible para esta instalacion. Causa tipica:
    /// `POST /api/auth/login` respondio 403 porque la `serverUrl` Navidrome
    /// del usuario no esta en la whitelist del backend (tercero del App Store
    /// con Navidrome ajena). TTL 24h: mientras este activo, `ensureSession()`
    /// devuelve `nil` sin tocar red. Protege al homelab de peticiones
    /// innecesarias por CF desde dispositivos sin cuenta autorizada.
    nonisolated func markBackendUnauthorized() {
        let until = Date().addingTimeInterval(Self.unauthorizedTTL)
        UserDefaults.standard.set(until.timeIntervalSince1970,
                                  forKey: Self.backendUnauthorizedKey)
    }

    /// Libera el gate `backendUnauthorized`. Se invoca tras un login exitoso
    /// y deberia invocarse tambien cuando el usuario cambia sus credenciales
    /// Navidrome (la `serverUrl` nueva puede estar whitelisteada). Ese cable
    /// se enchufara en `NavidromeService.saveCredentials` posteriormente.
    nonisolated func clearBackendUnauthorized() {
        UserDefaults.standard.removeObject(forKey: Self.backendUnauthorizedKey)
    }

    /// Timestamp del gate activo o nil si no hay/ha vencido. Auto-clear del
    /// valor vencido por simetria con `lockedUntil()`.
    nonisolated func backendUnauthorizedUntil() -> Date? {
        let ts = UserDefaults.standard.double(forKey: Self.backendUnauthorizedKey)
        guard ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        if date <= Date() {
            UserDefaults.standard.removeObject(forKey: Self.backendUnauthorizedKey)
            return nil
        }
        return date
    }

    // MARK: - Bootstrap (lazy)

    private func bootstrapIfNeeded() {
        guard !didLoadFromKeychain else { return }
        cachedSession = loadFromKeychain()
        didLoadFromKeychain = true
    }

    // MARK: - Keychain

    private func loadFromKeychain() -> Session? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? Self.decoder.decode(Session.self, from: data)
    }

    private func saveToKeychain(_ session: Session) throws {
        guard let data = try? Self.encoder.encode(session) else {
            throw AuthTokenError.persistenceFailed
        }
        let baseQuery: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let attrs: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            for (k, v) in attrs { item[k] = v }
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw AuthTokenError.persistenceFailed }
        } else if updateStatus != errSecSuccess {
            throw AuthTokenError.persistenceFailed
        }
    }

    private func deleteFromKeychain() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Codable strategy

    /// Encoder/decoder locales con `.secondsSince1970` explicito. Sin esto,
    /// el formato del item Keychain dependeria del default global de
    /// JSONEncoder y un cambio futuro a nivel app invalidaria items
    /// existentes silenciosamente.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
