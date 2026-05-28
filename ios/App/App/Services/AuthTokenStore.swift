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
/// `ensureSession()` es el punto unico de establecimiento: hace login con las
/// credenciales Navidrome y persiste el par. Lo consumen tanto las llamadas
/// REST (`BackendService.performRequest`) como el Connect Hub
/// (`ConnectService.authenticate`), compartiendo un solo login via
/// `ensureInFlight`. Los gates `backendUnauthorized`, `lockedUntil` y el
/// counter de fallos de login evitan trafico innecesario al backend.
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
        case noCredentials
        case persistenceFailed

        var errorDescription: String? {
            switch self {
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
    // Counter cliente preventivo de fallos consecutivos de login (401). Ortogonal
    // al brute-force guard server-side (que cuenta por username): este cuenta
    // por dispositivo, parando el ruido antes de que el request salga. Cuando
    // alcanza el threshold, bloquea login durante `loginFailureTTL`. TTL
    // alineado con el lockoutMs del servidor (15min) para no penalizar mas alla
    // de lo que el backend ya hace por su cuenta.
    private static let loginFailureCountKey = "audiorr_session_login_failure_count"
    private static let loginFailureUntilKey = "audiorr_session_login_failure_until"
    private static let loginFailureThreshold: Int = 3
    private static let loginFailureTTL: TimeInterval = 900  // 15min

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

    /// Devuelve el sessionToken vigente (sin refrescar) y limpia la sesion en el
    /// mismo paso atomico del actor. Para logout: el caller usa el token devuelto
    /// para invalidar la sesion server-side mientras la local ya queda borrada.
    /// Atomico evita la carrera en la que un re-login inmediato reestablece la
    /// sesion y un `clear()` diferido la borraria.
    func takeSessionTokenAndClear() -> String? {
        bootstrapIfNeeded()
        let token = cachedSession?.sessionToken
        clear()
        return token
    }

    /// Dispara refresh del par sessionToken+refreshToken contra el backend.
    /// Serializa concurrentes via shared in-flight Task: si varias Tasks
    /// reciben 401 simultaneo, solo una hace el POST /api/auth/refresh y
    /// las demas await el mismo resultado.
    ///
    /// Si no hay sesion cacheada (cold start sin login previo) lanza
    /// `noCredentials`. El backend reusa el `username` guardado en la sesion
    /// previa porque el endpoint /api/auth/refresh no lo devuelve.
    func refresh() async throws -> String {
        bootstrapIfNeeded()
        guard let snapshot = cachedSession else {
            throw AuthTokenError.noCredentials
        }

        if let inflight = refreshInFlight {
            return try await inflight.value
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw AuthTokenError.noCredentials }
            do {
                let result = try await BackendService.shared.refresh(refreshToken: snapshot.refreshToken)
                try await self.save(
                    sessionToken: result.token,
                    refreshToken: result.refreshToken,
                    expiresIn: result.expiresIn,
                    refreshExpiresIn: result.refreshExpiresIn,
                    isAdmin: result.isAdmin ?? snapshot.isAdmin,
                    username: snapshot.username
                )
                return result.token
            } catch BackendError.unauthorized {
                // Backend rechaza el refreshToken: invalidado o expirado.
                // Limpiamos la sesion local para evitar reintentos eternos.
                await self.clear()
                throw BackendError.unauthorized
            }
        }
        refreshInFlight = task
        defer { refreshInFlight = nil }
        return try await task.value
    }

    /// Punto unico de establecimiento de sesion Bearer, compartido por las
    /// llamadas REST (`BackendService.performRequest`) y por el Connect Hub
    /// (`ConnectService.authenticate`). Devuelve el sessionToken vigente; si no
    /// hay sesion cacheada, hace login con las credenciales Navidrome del
    /// `NavidromeService` y persiste el par. El `ensureInFlight` serializa
    /// concurrentes: aunque varias REST y el Hub lo invoquen a la vez en cold
    /// launch, solo sale UN `POST /api/auth/login`.
    ///
    /// Devuelve `nil` (degradacion a modo Navidrome puro, request sin Bearer)
    /// cuando:
    ///
    /// 1. Hay flag `backendUnauthorized` activo (TTL 24h tras un 403 previo).
    /// 2. Hay flag `lockedUntil` activo (TTL del Retry-After de un 429).
    /// 3. Hay flag de fallos de login consecutivos activo (counter cliente).
    /// 4. No hay credenciales Navidrome guardadas.
    /// 5. El login responde 403 (whitelist → marca gate 24h) o 401 (creds
    ///    invalidas → acumula counter) o 503 (Navidrome caido → no penaliza).
    /// 6. El backend es legacy y no emite `refreshToken` (sin par persistible).
    func ensureSession() async throws -> String? {
        if let until = backendUnauthorizedUntil(), until > Date() {
            return nil
        }
        if let until = lockedUntil(), until > Date() {
            return nil
        }
        if let until = consecutiveLoginFailuresUntil(), until > Date() {
            return nil
        }
        if let token = await currentToken() {
            return token
        }
        if let inflight = ensureInFlight {
            return try await inflight.value
        }
        let task = Task<String?, Error> { [weak self] in
            guard let self else { return nil }
            // Sin credenciales Navidrome no hay nada que autenticar contra el
            // backend Audiorr — degradacion a modo Navidrome puro.
            guard let creds = NavidromeService.shared.credentials,
                  let navToken = creds.token else {
                return nil
            }
            do {
                let result = try await BackendService.shared.login(
                    serverUrl: creds.serverUrl,
                    username: creds.username,
                    token: navToken
                )
                // Backend legacy sin refresh flow: sin par persistible seguimos
                // en modo Navidrome puro (REST sin Bearer, igual que pre-migracion).
                guard let refreshToken = result.refreshToken else {
                    return nil
                }
                try await self.save(
                    sessionToken: result.token,
                    refreshToken: refreshToken,
                    expiresIn: result.expiresIn,
                    refreshExpiresIn: result.refreshExpiresIn ?? result.expiresIn,
                    isAdmin: result.isAdmin ?? false,
                    username: result.username
                )
                self.clearLoginFailures()
                return result.token
            } catch BackendError.forbidden {
                // Whitelist del backend rechaza esta serverUrl/username. Gate 24h
                // para no martillear al homelab desde clientes con Navidrome ajena.
                self.markBackendUnauthorized()
                self.clearLoginFailures()
                return nil
            } catch BackendError.unauthorized {
                // 401 credenciales Navidrome invalidas. Counter cliente preventivo.
                self.recordLoginFailure()
                return nil
            } catch BackendError.serviceUnavailable {
                // 503 Navidrome inalcanzable. NO acumular fallo: un Navidrome
                // flaky no debe auto-bloquear al usuario legitimo.
                return nil
            }
        }
        ensureInFlight = task
        defer { ensureInFlight = nil }
        return try await task.value
    }

    /// Establecimiento explicito de la sesion Bearer cuando el usuario inicia
    /// sesion deliberadamente (LoginView, tras validar contra Navidrome).
    ///
    /// El path perezoso (`ensureSession` desde REST/Hub) puede reusar una sesion
    /// Bearer obsoleta persistida en Keychain — `logout` NO la limpiaba — y por
    /// eso `currentToken()` la devolvia (o intentaba refrescarla) sin disparar
    /// nunca un `POST /api/auth/login` nuevo: el sintoma observado en backend era
    /// "hub conecta, cero login, REST sin Bearer".
    ///
    /// Aqui, al ser un login deliberado, limpiamos los gates de cliente (lockout
    /// 429, gate 403 de whitelist, counter de fallos) y descartamos cualquier
    /// sesion previa para forzar un login fresco con las credenciales recien
    /// guardadas. Devuelve `true` si la sesion Bearer quedo establecida.
    @discardableResult
    func establishOnUserLogin() async -> Bool {
        clearLockedUntil()
        clearBackendUnauthorized()
        clearLoginFailures()
        clear()
        return (try? await ensureSession()) != nil
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
        // Fuerza re-evaluacion inmediata de BackendState para que las features
        // REST se duerman sin esperar al proximo disparador natural de check().
        Task { @MainActor in BackendState.shared.invalidateAndRecheck() }
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
        // Fuerza isAvailable=false ya — sin esperar al proximo check(). Cierra
        // la ventana donde las features REST mandan trafico residual al backend
        // del operador tras un 403 de whitelist.
        Task { @MainActor in BackendState.shared.invalidateAndRecheck() }
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

    // MARK: - Login failures counter (cliente, preventivo)

    /// Timestamp hasta cuando el cliente se auto-bloquea por fallos consecutivos
    /// de login (401). Ortogonal al `lockedUntil()` del 429 server-side: aqui
    /// paramos antes de mandar la peticion, evitando ruido al backend.
    nonisolated func consecutiveLoginFailuresUntil() -> Date? {
        let ts = UserDefaults.standard.double(forKey: Self.loginFailureUntilKey)
        guard ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        if date <= Date() {
            UserDefaults.standard.removeObject(forKey: Self.loginFailureUntilKey)
            UserDefaults.standard.removeObject(forKey: Self.loginFailureCountKey)
            return nil
        }
        return date
    }

    /// Acumula un fallo de login (401). Cuando alcanza `loginFailureThreshold`,
    /// fija el lock por `loginFailureTTL`. NO debe llamarse para 503 (Navidrome
    /// caido) ni 429 (ese lockout lo maneja `setLockedUntil`).
    nonisolated func recordLoginFailure() {
        let count = UserDefaults.standard.integer(forKey: Self.loginFailureCountKey) + 1
        UserDefaults.standard.set(count, forKey: Self.loginFailureCountKey)
        if count >= Self.loginFailureThreshold {
            let until = Date().addingTimeInterval(Self.loginFailureTTL)
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.loginFailureUntilKey)
            // Fuerza re-evaluacion inmediata al cruzar el threshold (no en
            // cada fallo individual, solo cuando el gate se activa).
            Task { @MainActor in BackendState.shared.invalidateAndRecheck() }
        }
    }

    /// Resetea el counter (llamar tras login exitoso, tras cambio de
    /// credenciales Navidrome, y tras `markBackendUnauthorized` para no
    /// solapar dos gates).
    nonisolated func clearLoginFailures() {
        UserDefaults.standard.removeObject(forKey: Self.loginFailureCountKey)
        UserDefaults.standard.removeObject(forKey: Self.loginFailureUntilKey)
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
