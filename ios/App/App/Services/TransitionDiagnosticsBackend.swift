// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   TransitionDiagnosticsBackend                                       ║
// ║   Round 2026-05-10 — diagnostics-backend-port                        ║
// ║                                                                      ║
// ║   Cliente HTTP del backend de diagnósticos de transiciones (homelab  ║
// ║   LAN, base `<navidromeHost>:2999/api/diagnostics`). Sustituye la    ║
// ║   persistencia local en JSON (`transition_diagnostics_history.json`) ║
// ║   y el log textual (`transition_diagnostics.log`). Backend = source  ║
// ║   of truth único; sin queue, sin sync, sin reconciliación.           ║
// ║                                                                      ║
// ║   Endpoints:                                                         ║
// ║     POST   /transitions                       — sube record nuevo    ║
// ║     PATCH  /transitions/:id                   — edita rating/comment ║
// ║     DELETE /transitions/:id/comment           — soft-delete comment  ║
// ║     GET    /transitions?since=&until=&...     — lista paginada       ║
// ║     GET    /sessions?limit=                   — sesiones agrupadas   ║
// ║                                                                      ║
// ║   Auth: header `x-navidrome-user: <username>` (mismo patrón que      ║
// ║   `BackendService.navidromeHeaders`). Multi-tenant: el backend       ║
// ║   filtra por owner; nunca verás records de otro usuario.             ║
// ║                                                                      ║
// ║   Política de fallo: timeout corto (5s, LAN <100ms en condiciones    ║
// ║   normales — si tarda más es señal de problema y abortamos). Cero    ║
// ║   reintentos: si falla, se descarta. El usuario re-edita o re-crea   ║
// ║   manualmente — coherente con el principio "sin queue".              ║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import Foundation

// MARK: - Errors

/// Errores específicos del cliente de diagnósticos. Independiente de
/// `BackendService.BackendError` para que cada llamada exprese el caso (401 /
/// 403 / 404 / 409 / 5xx / network) sin necesidad de leer el integer literal
/// del HTTP status en cada call site.
enum DiagnosticsBackendError: Error, LocalizedError {
    /// No hay credenciales Navidrome (sin `x-navidrome-user`). El backend
    /// rechazaría con 401 — abortamos antes de pegarle al servidor.
    case unauthorized
    /// 403 — el usuario actual no es el owner del record que intenta tocar.
    /// No debería ocurrir en flujos normales (cada cliente solo edita lo
    /// suyo); si pasa, hay bug de routing o intento de edición cross-user.
    case forbidden
    /// 404 — el record no existe. Puede pasar si el JSON local trae un id
    /// que el backend no tiene (backend reset, history huérfano).
    case notFound
    /// 409 — id ya existe en backend. No debería ocurrir (UUID v4 colision
    /// es ~0). Se loguea warn y se descarta el record duplicado.
    case conflict
    /// 5xx o error de red / timeout. Backend caído, LAN flaky, etc.
    case serverError(underlying: Error?)
    /// `backendURL()` devolvió nil o no pudo construirse la URL final.
    /// Configuración incompleta (sin Navidrome credentials).
    case noBaseURL
    /// Respuesta 2xx pero el body no parsea según el contrato esperado.
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Diagnostics: missing Navidrome user header (401)"
        case .forbidden: return "Diagnostics: not the owner of this record (403)"
        case .notFound: return "Diagnostics: record not found (404)"
        case .conflict: return "Diagnostics: duplicate id (409)"
        case .serverError(let err): return "Diagnostics: server error (\(err?.localizedDescription ?? "unknown"))"
        case .noBaseURL: return "Diagnostics: backend URL not configured"
        case .invalidResponse: return "Diagnostics: invalid response body"
        }
    }
}

// MARK: - Response models

/// Respuesta del POST /transitions (201). El backend asigna `sessionId` por
/// gap-based (≥30 min sin transición = nueva sesión). El cliente no lo calcula.
struct DiagnosticsUploadResponse: Decodable {
    let id: UUID
    let sessionId: UUID
    let createdAt: Date
}

/// Respuesta del GET /transitions (200). Lista paginada + metadata.
struct DiagnosticsTransitionsResponse: Decodable {
    let transitions: [TransitionDiagnostics.TransitionRecord]
    let total: Int
    let limit: Int
    let offset: Int
    let hasMore: Bool
}

/// Resumen por sesión que devuelve GET /sessions. Para la UI de Settings >
/// Diagnostics (sesión iOS parte 2) y queries operativas.
struct DiagnosticsSessionSummary: Decodable, Identifiable {
    /// `id` para `Identifiable` de SwiftUI; mapea a `sessionId`.
    var id: UUID { sessionId }
    let sessionId: UUID
    let startedAt: Date
    let endedAt: Date
    let transitionCount: Int
    let rated: Int
    let unrated: Int
    /// `nil` si no hay ratings en la sesión.
    let meanRating: Double?
    /// Versión predominante en la sesión (puede mezclar dos si hubo update
    /// TestFlight a mitad). Backend devuelve la moda.
    let algorithmVersion: String?
    let buildId: String?
    /// Conteo de records con rating ≥9 (los "diamonds" del set).
    let diamonds: Int
}

private struct DiagnosticsSessionsResponse: Decodable {
    let sessions: [DiagnosticsSessionSummary]
}

// MARK: - Request bodies

/// Body del PATCH /transitions/:id. Ambos campos opcionales — solo se envían
/// los que cambian (server-side merge).
private struct PatchOpinionBody: Encodable {
    let userRating: Int?
    let userComment: String?
}

/// Round v14.e Alt-3 (2026-05-17) — clave dinámica para inyectar sub-objetos
/// aditivos en el payload del POST + PATCH enrich sin tener que declarar
/// cada nombre estático. Backend acepta cualquier top-level key fuera del
/// set `PROTECTED_ENRICH_KEYS` (14 columnas indexadas, ninguna empieza por
/// "postResetAudit").
private struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

/// Wrapper Encodable para diccionarios `[String: Any]` con tipos primitivos
/// (String, Bool, Float, Double). Tipos no soportados se ignoran silenciosamente
/// — el payload audit slim no incluye nada más.
private struct NestedDict: Encodable {
    let dict: [String: Any]
    init(_ d: [String: Any]) { self.dict = d }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        for (k, v) in dict {
            guard let key = DynamicKey(stringValue: k) else { continue }
            switch v {
            case let s as String: try c.encode(s, forKey: key)
            case let b as Bool:   try c.encode(b, forKey: key)
            case let f as Float:  try c.encode(f, forKey: key)
            case let d as Double: try c.encode(d, forKey: key)
            default: break
            }
        }
    }
}

/// Envelope que mezcla el `TransitionRecord` con sub-objetos aditivos como
/// hermanos del top-level. El backend persiste todo en `recordJson` sin
/// sanitizer (confirmado backend-guardian sec 2.2). Usado por `uploadRecord`
/// para inyectar `postResetAuditCompleteCrossfade` cuando viene presente.
private struct UploadEnvelope: Encodable {
    let record: TransitionDiagnostics.TransitionRecord
    let extras: [String: [String: Any]]?  // top-level key → sub-objeto

    func encode(to encoder: Encoder) throws {
        // Primero codificamos el record (todas sus keys al top-level).
        try record.encode(to: encoder)
        // Luego mezclamos extras como top-level siblings.
        guard let extras else { return }
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (k, sub) in extras {
            guard let key = DynamicKey(stringValue: k) else { continue }
            try container.encode(NestedDict(sub), forKey: key)
        }
    }
}

/// Envelope-only para PATCH /enrich — body es un dict de top-level keys
/// (e.g. `postResetAuditPostSwap`) → sub-objetos. Sin record principal.
private struct OuterEnvelope: Encodable {
    let body: [String: [String: Any]]
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (k, sub) in body {
            guard let key = DynamicKey(stringValue: k) else { continue }
            try container.encode(NestedDict(sub), forKey: key)
        }
    }
}

// MARK: - Service

/// Cliente HTTP del backend de diagnósticos. Singleton stateless — toda la
/// configuración (baseURL, auth) la lee dinámicamente de `NavidromeService`
/// para reaccionar a override de URL en tiempo real (Settings).
final class TransitionDiagnosticsBackend {

    static let shared = TransitionDiagnosticsBackend()

    /// Timeout corto: LAN responde en <100ms en condiciones normales. Si tarda
    /// >5s es señal de problema y mejor abortar (consistente con "sin queue").
    private let requestTimeout: TimeInterval = 5

    /// Decoder con date strategy iso8601 (backend serializa con `toISOString()`).
    private let jsonDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    /// Encoder con la misma estrategia (simetría — el backend espera ISO8601
    /// para `date` y `ratedAt`).
    private let jsonEncoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    private init() {}

    // MARK: - Public API

    /// Sube un record nuevo al backend. Fire-and-forget desde el call site:
    /// si falla, descarta sin reintento (consistente con "sin queue, sin
    /// sync"). Devuelve `Result` por si el caller quiere loguear el outcome.
    ///
    /// Round v14.e Alt-3 (2026-05-17): `postResetAuditCompleteCrossfade` es
    /// opcional. Cuando viene presente, se inyecta como sub-objeto top-level
    /// hermano del record. Backend lo persiste en `recordJson` sin sanitizer.
    nonisolated func uploadRecord(
        _ record: TransitionDiagnostics.TransitionRecord,
        postResetAuditCompleteCrossfade: [String: Any]? = nil
    ) async -> Result<DiagnosticsUploadResponse, DiagnosticsBackendError> {
        guard let request = makeRequest(path: "/transitions", method: "POST") else {
            return .failure(.noBaseURL)
        }
        var req = request
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let envelope = UploadEnvelope(
                record: record,
                extras: postResetAuditCompleteCrossfade.map { ["postResetAuditCompleteCrossfade": $0] }
            )
            req.httpBody = try jsonEncoder.encode(envelope)
        } catch {
            return .failure(.invalidResponse)
        }
        return await execute(req) { data in
            try self.jsonDecoder.decode(DiagnosticsUploadResponse.self, from: data)
        }
    }

    /// PATCH /transitions/:id/enrich — añade sub-objetos aditivos al
    /// `recordJson` del record existente. El backend hace shallow merge
    /// `{...parsed, ...body}` (verificado backend-guardian test #9 sec 5).
    /// `body` debe contener top-level keys que NO estén en
    /// `PROTECTED_ENRICH_KEYS` (userRating, type, id, etc.) o el backend
    /// responde 400.
    ///
    /// Round v14.e Alt-3 — usado para enviar `postResetAuditPostSwap` tras
    /// `.success` del POST. Si responde 404, marca race lost (POST 201 OK
    /// pero record aún no commiteado — extremadamente raro con LAN flaky).
    nonisolated func enrichRecord(
        id: UUID,
        body: [String: [String: Any]]
    ) async -> Result<Void, DiagnosticsBackendError> {
        guard let request = makeRequest(path: "/transitions/\(id.uuidString)/enrich", method: "PATCH") else {
            return .failure(.noBaseURL)
        }
        var req = request
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try jsonEncoder.encode(OuterEnvelope(body: body))
        } catch {
            return .failure(.invalidResponse)
        }
        return await execute(req) { _ in () }
    }

    /// Patch del rating y/o comment en un record existente. Body envía solo los
    /// campos que cambian (`nil` significa "no tocar"). Para borrar un comment
    /// específicamente, usar `deleteComment(id:)` — pasar `comment: ""` aquí
    /// también lo borra pero no marca `deletedAt`.
    nonisolated func updateOpinion(
        id: UUID,
        rating: Int?,
        comment: String?
    ) async -> Result<TransitionDiagnostics.TransitionRecord, DiagnosticsBackendError> {
        guard let request = makeRequest(path: "/transitions/\(id.uuidString)", method: "PATCH") else {
            return .failure(.noBaseURL)
        }
        var req = request
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = PatchOpinionBody(userRating: rating, userComment: comment)
        do {
            req.httpBody = try jsonEncoder.encode(body)
        } catch {
            return .failure(.invalidResponse)
        }
        return await execute(req) { data in
            try self.jsonDecoder.decode(TransitionDiagnostics.TransitionRecord.self, from: data)
        }
    }

    /// Soft-delete del comment de un record. El record persiste, el rating se
    /// preserva, solo el `userComment` se pone a NULL y se setea `deletedAt`.
    /// Endpoint dedicado (no via PATCH) porque la semántica "borrar comment
    /// preservando rating" merece verbo HTTP propio.
    nonisolated func deleteComment(
        id: UUID
    ) async -> Result<Void, DiagnosticsBackendError> {
        guard let request = makeRequest(path: "/transitions/\(id.uuidString)/comment", method: "DELETE") else {
            return .failure(.noBaseURL)
        }
        return await execute(request) { _ in () }
    }

    /// Lista paginada con filtros opcionales. Pensado para la UI de Settings >
    /// Diagnostics (sesión iOS parte 2 del round) y para `loadHistoryFromBackend`
    /// del init de `TransitionDiagnostics`.
    ///
    /// - Note: `types` se serializa como CSV (`type=BMB,CUT`) según contrato
    ///   verificado del backend.
    nonisolated func fetchTransitions(
        since: Date? = nil,
        until: Date? = nil,
        minRating: Int? = nil,
        maxRating: Int? = nil,
        unrated: Bool? = nil,
        types: [String]? = nil,
        sessionId: UUID? = nil,
        algorithmVersion: String? = nil,
        buildId: String? = nil,
        search: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) async -> Result<DiagnosticsTransitionsResponse, DiagnosticsBackendError> {
        var items: [URLQueryItem] = []
        let isoFormatter = ISO8601DateFormatter()
        if let since { items.append(.init(name: "since", value: isoFormatter.string(from: since))) }
        if let until { items.append(.init(name: "until", value: isoFormatter.string(from: until))) }
        if let minRating { items.append(.init(name: "minRating", value: String(minRating))) }
        if let maxRating { items.append(.init(name: "maxRating", value: String(maxRating))) }
        if let unrated { items.append(.init(name: "unrated", value: unrated ? "true" : "false")) }
        if let types, !types.isEmpty { items.append(.init(name: "type", value: types.joined(separator: ","))) }
        if let sessionId { items.append(.init(name: "sessionId", value: sessionId.uuidString)) }
        if let algorithmVersion { items.append(.init(name: "algorithmVersion", value: algorithmVersion)) }
        if let buildId { items.append(.init(name: "buildId", value: buildId)) }
        if let search, !search.isEmpty { items.append(.init(name: "search", value: search)) }
        items.append(.init(name: "limit", value: String(limit)))
        items.append(.init(name: "offset", value: String(offset)))

        guard let request = makeRequest(path: "/transitions", method: "GET", queryItems: items) else {
            return .failure(.noBaseURL)
        }
        return await execute(request) { data in
            try self.jsonDecoder.decode(DiagnosticsTransitionsResponse.self, from: data)
        }
    }

    /// Sesiones recientes agrupadas por el backend (gap-based, threshold 30 min).
    /// Devuelve metadata por sesión: total, rated, mean, algorithmVersion, etc.
    nonisolated func fetchSessions(
        limit: Int = 20
    ) async -> Result<[DiagnosticsSessionSummary], DiagnosticsBackendError> {
        let items: [URLQueryItem] = [.init(name: "limit", value: String(limit))]
        guard let request = makeRequest(path: "/sessions", method: "GET", queryItems: items) else {
            return .failure(.noBaseURL)
        }
        return await execute(request) { data in
            try self.jsonDecoder.decode(DiagnosticsSessionsResponse.self, from: data).sessions
        }
    }

    // MARK: - Private helpers

    /// Construye el `URLRequest` base con la URL final + auth header. Devuelve
    /// `nil` si no se puede resolver baseURL o el username (caller traduce a
    /// `.noBaseURL` o `.unauthorized`).
    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = []
    ) -> URLRequest? {
        guard let base = NavidromeService.shared.backendURL() else { return nil }
        var components = URLComponents(string: "\(base)/api/diagnostics\(path)")
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        // Auth header — mismo patrón que `BackendService.navidromeHeaders`.
        // Si no hay credentials, mandamos sin header → backend responde 401
        // y el `execute` lo traduce a `.unauthorized`.
        if let creds = NavidromeService.shared.credentials {
            request.setValue(creds.username, forHTTPHeaderField: "x-navidrome-user")
        }
        return request
    }

    /// Ejecuta el request, traduce HTTP status a `DiagnosticsBackendError`, y
    /// aplica el decoder pasado en `decode`. Para 204 (DELETE), el closure
    /// recibe Data() vacía — los callers que devuelven `Void` lo ignoran.
    private func execute<T>(
        _ request: URLRequest,
        decode: @escaping (Data) throws -> T
    ) async -> Result<T, DiagnosticsBackendError> {
        do {
            let (data, response) = try await AudiorrNetwork.background.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            switch http.statusCode {
            case 200, 201:
                do {
                    let value = try decode(data)
                    return .success(value)
                } catch {
                    return .failure(.invalidResponse)
                }
            case 204:
                // No body. Si T es Void, el decode closure devuelve () correctamente.
                do {
                    let value = try decode(Data())
                    return .success(value)
                } catch {
                    return .failure(.invalidResponse)
                }
            case 401: return .failure(.unauthorized)
            case 403: return .failure(.forbidden)
            case 404: return .failure(.notFound)
            case 409: return .failure(.conflict)
            default:
                return .failure(.serverError(underlying: nil))
            }
        } catch {
            return .failure(.serverError(underlying: error))
        }
    }
}
