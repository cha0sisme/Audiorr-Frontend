// ╔══════════════════════════════════════════════════════════════════════╗
// ║                                                                      ║
// ║   TransitionDiagnosticsView                                          ║
// ║   Round 2026-05-10 — diagnostics-backend-port (sesión iOS parte 2)   ║
// ║                                                                      ║
// ║   Lista paginada de transiciones servidas por el backend, agrupadas  ║
// ║   por sesión (gap-based, ≥30 min). Search top + filter chips +       ║
// ║   sticky headers por día/sesión + AirPods banner contextual + swipe  ║
// ║   actions + detail sheet con autosave debounced.                     ║
// ║                                                                      ║
// ║   Sustituye la vista anterior (estilo "log textual con secciones de  ║
// ║   diagnóstico"). El active-transition diagnostic en tiempo real      ║
// ║   queda fuera del rediseño — se accede vía la tab "Active" abajo.    ║
// ║                                                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

import SwiftUI
import AVFoundation

/// Vista principal Settings > Diagnostics.
///
/// History es lo que el director consume el 95% del tiempo. La telemetría en
/// vivo del crossfade activo es contextual — solo importa cuando hay
/// transición ahora mismo. Para no robar espacio con un tab segmentado, vive
/// detrás de un botón "Live" en la toolbar que solo aparece cuando
/// `TransitionDiagnostics.shared.isActive == true`. Apple Music/Photos usan
/// patrones similares para vistas de tiempo real opcionales.
struct TransitionDiagnosticsView: View {
    @State private var diag = TransitionDiagnostics.shared
    @State private var showLive = false

    var body: some View {
        TransitionHistoryView()
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if diag.isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showLive = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.subheadline.weight(.semibold))
                                Text("Live")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.red.opacity(0.12), in: Capsule())
                            .overlay(
                                Capsule().stroke(.red.opacity(0.35), lineWidth: 0.5)
                            )
                        }
                        .accessibilityLabel("Ver transición en curso")
                    }
                }
            }
            .sheet(isPresented: $showLive) {
                NavigationStack {
                    TransitionActiveView()
                        .navigationTitle("En curso")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Cerrar") { showLive = false }
                            }
                        }
                }
                .presentationDragIndicator(.visible)
                .presentationDetents([.large])
            }
    }
}

// MARK: - History tab

/// Lista paginada con search + filter chips + sticky headers (día → sesión) +
/// AirPods banner + swipe actions + lazy load + pull to refresh.
struct TransitionHistoryView: View {
    @State private var transitions: [TransitionDiagnostics.TransitionRecord] = []
    @State private var sessions: [DiagnosticsSessionSummary] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var totalCount = 0
    @State private var offset = 0
    private let pageSize = 50

    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    @State private var selectedFilter: HistoryFilter = .all
    @State private var unratedCount: Int = 0

    @State private var airpodsConnected: Bool = false
    @State private var routeObserver: NSObjectProtocol?

    @State private var presentedRecord: TransitionDiagnostics.TransitionRecord?

    /// Singleton observable. Cuando `publishCompletion` inserta un nuevo record
    /// en `history`, el `.onChange` sobre `diag.history.first?.id` lo detecta y
    /// hace prepend en la lista local — evita tener que salir/volver a la view.
    @State private var diag = TransitionDiagnostics.shared

    enum HistoryFilter: Int, Hashable, Identifiable, CaseIterable {
        case all = 0
        case unrated = 1
        case low = 2       // 1-3
        case mid = 3       // 4-6
        case high = 4      // 7-10
        case diamonds = 5  // 10

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .all: return "Todas"
            case .unrated: return "Sin valorar"
            case .low: return "1–3"
            case .mid: return "4–6"
            case .high: return "7–10"
            case .diamonds: return "Diamonds"
            }
        }

        var systemImage: String? {
            switch self {
            case .diamonds: return "diamond.fill"
            default: return nil
            }
        }

        var tint: Color {
            switch self {
            case .all: return .accentColor
            case .unrated: return .red
            case .low: return Color(red: 0.85, green: 0.40, blue: 0.40)
            case .mid: return .yellow
            case .high: return .green
            case .diamonds: return .cyan
            }
        }
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 4)

                filterChips
                    .padding(.bottom, 4)

                if airpodsConnected && unratedCount > 0 {
                    airpodsBanner
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if !debouncedSearch.isEmpty {
                    HStack {
                        Text("Resultado: \(totalCount) transición\(totalCount == 1 ? "" : "es")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                }

                listContent
            }
        }
        .task(id: filterFingerprint) {
            await reload()
        }
        .task {
            await loadSessions()
            await loadUnratedCount()
        }
        .onChange(of: searchText) { _, newValue in
            scheduleSearchDebounce(query: newValue)
        }
        // Reactividad en tiempo real: cuando el singleton inserta un record
        // nuevo (publishCompletion → history.insert(at: 0)), aparece arriba sin
        // salir/volver a la view. Solo se prepend si pasa los filtros activos.
        .onChange(of: diag.history.first?.id) { _, _ in
            handleNewLiveRecord()
        }
        .onAppear { startRouteObserver() }
        .onDisappear { stopRouteObserver() }
        .sheet(item: $presentedRecord) { record in
            TransitionDetailSheet(
                record: record,
                onCommit: { rating, comment in
                    apply(rating: rating, comment: comment, to: record.id)
                },
                onDeleteComment: {
                    deleteComment(for: record.id)
                }
            )
            .presentationDragIndicator(.visible)
            .presentationDetents([.large])
        }
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Buscar canción…", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HistoryFilter.allCases) { filter in
                    FilterChip(
                        filter: filter,
                        isSelected: selectedFilter == filter,
                        unratedBadge: filter == .unrated && unratedCount > 0 ? unratedCount : nil
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            selectedFilter = filter
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var airpodsBanner: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                selectedFilter = .unrated
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "airpodspro")
                    .font(.title2)
                    .foregroundStyle(.cyan.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(unratedCount) transicion\(unratedCount == 1 ? "" : "es") por valorar")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text("AirPods conectados — buen momento para escuchar")
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var listContent: some View {
        if isLoading && transitions.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text("Cargando…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if transitions.isEmpty {
            emptyState
        } else {
            // SwiftUI List es necesario para swipeActions nativos. Section
            // headers se pinzan automáticamente con `.listSectionSpacing` y
            // `.headerProminence`. Para visual Liquid Glass usamos
            // `.listRowBackground(Color.clear)` + `.scrollContentBackground(.hidden)`.
            List {
                ForEach(groupedByDay, id: \.dayKey) { dayGroup in
                    Section {
                        ForEach(dayGroup.sessionGroups, id: \.sessionId) { sessionGroup in
                            // Sub-header de sesión como primera "fila" de la sección.
                            sessionHeader(sessionGroup)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

                            ForEach(sessionGroup.records) { record in
                                TransitionRow(record: record)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        presentedRecord = record
                                    }
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            quickRate(record: record)
                                        } label: {
                                            Label("Valorar", systemImage: "star")
                                        }
                                        .tint(.yellow)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        if (record.userComment ?? "").isEmpty == false {
                                            Button(role: .destructive) {
                                                deleteComment(for: record.id)
                                            } label: {
                                                Label("Borrar comment", systemImage: "text.bubble.fill")
                                            }
                                        } else {
                                            Button {
                                                presentedRecord = record
                                            } label: {
                                                Label("Editar", systemImage: "pencil")
                                            }
                                            .tint(.accentColor)
                                        }
                                    }
                            }
                        }
                    } header: {
                        dayHeader(dayGroup)
                    }
                }

                if hasMore {
                    loadMoreSentinel
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                await reload()
                await loadSessions()
                await loadUnratedCount()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyMessage: String {
        if !debouncedSearch.isEmpty { return "Sin resultados para “\(debouncedSearch)”." }
        switch selectedFilter {
        case .all: return "Aún no hay transiciones registradas. Reproduce algo y vuelve a entrar."
        case .unrated: return "Todas valoradas. Buen trabajo."
        case .low: return "Sin transiciones en este rango."
        case .mid: return "Sin transiciones en este rango."
        case .high: return "Sin transiciones en este rango."
        case .diamonds: return "Aún no hay diamonds (rating 10)."
        }
    }

    private var loadMoreSentinel: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 16)
        .onAppear {
            Task { await fetchNextPage() }
        }
    }

    @ViewBuilder
    private func dayHeader(_ group: DayGroup) -> some View {
        Text(group.label)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    @ViewBuilder
    private func sessionHeader(_ group: SessionGroup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.timeLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let v = group.algorithmVersion {
                        Text(v)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text("\(group.records.count) trans.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let mean = group.meanRating {
                        Text("· media \(String(format: "%.1f", mean))/10")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(meanColor(mean))
                    }
                    if group.diamonds > 0 {
                        Image(systemName: "diamond.fill")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                        Text("\(group.diamonds)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Grouping

    private struct DayGroup {
        let dayKey: String
        let label: String
        let sessionGroups: [SessionGroup]
    }

    private struct SessionGroup {
        let sessionId: UUID
        let startedAt: Date
        let timeLabel: String
        let algorithmVersion: String?
        let meanRating: Double?
        let diamonds: Int
        let records: [TransitionDiagnostics.TransitionRecord]
    }

    private var groupedByDay: [DayGroup] {
        // Bucket records by sessionId; records sin sessionId (recién subidos
        // antes de que el backend devuelva) caen en bucket UUID nil → grupo "Local".
        var bySession: [UUID?: [TransitionDiagnostics.TransitionRecord]] = [:]
        for record in transitions {
            bySession[record.sessionId, default: []].append(record)
        }

        let sessionsLookup = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })

        // Construir SessionGroup ordenando records por fecha desc dentro.
        var sessionGroups: [SessionGroup] = []
        for (sid, records) in bySession {
            let sortedRecords = records.sorted { $0.date > $1.date }
            let resolvedSid = sid ?? UUID()
            let summary = sid.flatMap { sessionsLookup[$0] }
            let started = summary?.startedAt ?? sortedRecords.last?.date ?? Date()
            let mean: Double? = {
                if let s = summary, let m = s.meanRating { return m }
                let rated = sortedRecords.compactMap { $0.userRating }
                guard !rated.isEmpty else { return nil }
                return Double(rated.reduce(0, +)) / Double(rated.count)
            }()
            let diamonds = summary?.diamonds ?? sortedRecords.filter { $0.userRating == 10 }.count
            let version = summary?.algorithmVersion ?? sortedRecords.first?.algorithmVersion
            sessionGroups.append(SessionGroup(
                sessionId: resolvedSid,
                startedAt: started,
                timeLabel: TransitionHistoryView.timeFormatter.string(from: started),
                algorithmVersion: version,
                meanRating: mean,
                diamonds: diamonds,
                records: sortedRecords
            ))
        }
        sessionGroups.sort { $0.startedAt > $1.startedAt }

        // Bucket sessionGroups por día (clave dayKey local) preservando el
        // orden inverso de las sesiones (más reciente arriba).
        var byDay: [String: [SessionGroup]] = [:]
        var dayOrder: [String] = []
        let cal = Calendar.current
        for group in sessionGroups {
            let key = TransitionHistoryView.dayKeyFormatter.string(from: cal.startOfDay(for: group.startedAt))
            if byDay[key] == nil { dayOrder.append(key) }
            byDay[key, default: []].append(group)
        }
        return dayOrder.map { key -> DayGroup in
            let groups = byDay[key] ?? []
            let label = TransitionHistoryView.dayLabel(for: groups.first?.startedAt ?? Date())
            return DayGroup(dayKey: key, label: label, sessionGroups: groups)
        }
    }

    // MARK: - Networking

    /// Fingerprint que dispara reload — cualquier cambio en filtro o search
    /// activa una refetch desde offset 0.
    private var filterFingerprint: String {
        "\(selectedFilter.id)|\(debouncedSearch)"
    }

    private func reload() async {
        offset = 0
        hasMore = true
        transitions = []
        totalCount = 0
        await fetchNextPage()
    }

    private func fetchNextPage() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        let (minR, maxR, unratedFlag) = filterToBackendArgs(selectedFilter)
        let result = await TransitionDiagnosticsBackend.shared.fetchTransitions(
            minRating: minR,
            maxRating: maxR,
            unrated: unratedFlag,
            search: debouncedSearch.isEmpty ? nil : debouncedSearch,
            limit: pageSize,
            offset: offset
        )
        switch result {
        case .success(let response):
            // Dedupe por id (defensivo si una página solapa por re-fetch).
            let existingIds = Set(transitions.map { $0.id })
            let fresh = response.transitions.filter { !existingIds.contains($0.id) }
            transitions.append(contentsOf: fresh)
            totalCount = response.total
            hasMore = response.hasMore
            offset += response.transitions.count
        case .failure(let error):
            print("[TransitionHistoryView] ⚠️ fetch failed: \(error.localizedDescription)")
            hasMore = false
        }
    }

    private func loadSessions() async {
        let result = await TransitionDiagnosticsBackend.shared.fetchSessions(limit: 30)
        if case .success(let summaries) = result {
            sessions = summaries
        }
    }

    private func loadUnratedCount() async {
        // Pequeña query sólo para el badge del chip y el banner — limit=1 con
        // unrated=true devuelve el `total` que necesitamos.
        let result = await TransitionDiagnosticsBackend.shared.fetchTransitions(
            unrated: true,
            limit: 1,
            offset: 0
        )
        if case .success(let response) = result {
            unratedCount = response.total
        }
    }

    private func filterToBackendArgs(_ filter: HistoryFilter) -> (min: Int?, max: Int?, unrated: Bool?) {
        switch filter {
        case .all:      return (nil, nil, nil)
        case .unrated:  return (nil, nil, true)
        case .low:      return (1, 3, nil)
        case .mid:      return (4, 6, nil)
        case .high:     return (7, 10, nil)
        case .diamonds: return (10, 10, nil)
        }
    }

    // MARK: - Live record reactivity

    /// Llamado por `.onChange(of: diag.history.first?.id)`. Si el primer record
    /// del singleton no está ya en la lista local y pasa los filtros activos
    /// (search + filter chip), se hace prepend al instante. El record recién
    /// publicado tiene `userRating == nil` y `userComment == nil` por
    /// definición, así que solo casa con `.all` y `.unrated`.
    private func handleNewLiveRecord() {
        guard let latest = diag.history.first else { return }
        // Idempotencia: si ya existe (re-render por mismo id) no duplicar.
        guard !transitions.contains(where: { $0.id == latest.id }) else { return }
        guard recordMatchesActiveFilters(latest) else { return }
        transitions.insert(latest, at: 0)
        totalCount += 1
        if latest.userRating == nil { unratedCount += 1 }
        // Refrescar resumen de sesiones para que el header de "Sesión X" cuente
        // la transición nueva. No bloquea — corre detached.
        Task { await loadSessions() }
    }

    /// True si el record encaja con los filtros activos (search + chip). Se
    /// usa solo para el path de inserción reactiva — la fetch paginada del
    /// backend ya filtra server-side.
    private func recordMatchesActiveFilters(_ r: TransitionDiagnostics.TransitionRecord) -> Bool {
        // Search
        if !debouncedSearch.isEmpty {
            let q = debouncedSearch.lowercased()
            let hit = r.fromTitle.lowercased().contains(q) || r.toTitle.lowercased().contains(q)
            if !hit { return false }
        }
        // Filter chip
        switch selectedFilter {
        case .all:      return true
        case .unrated:  return r.userRating == nil
        case .low:      if let v = r.userRating { return v >= 1 && v <= 3 } else { return false }
        case .mid:      if let v = r.userRating { return v >= 4 && v <= 6 } else { return false }
        case .high:     if let v = r.userRating { return v >= 7 && v <= 10 } else { return false }
        case .diamonds: return r.userRating == 10
        }
    }

    // MARK: - Search debounce

    private func scheduleSearchDebounce(query: String) {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                debouncedSearch = query.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: - Mutations

    private func apply(rating: Int?, comment: String?, to recordId: UUID) {
        TransitionDiagnostics.shared.updateOpinion(recordId: recordId, rating: rating, comment: comment)
        // Mirror local — actualizamos la copia que muestra la UI sin esperar
        // otra fetch. Coherente con optimistic update del singleton.
        if let idx = transitions.firstIndex(where: { $0.id == recordId }) {
            transitions[idx].userRating = rating
            transitions[idx].userComment = (comment?.isEmpty == true) ? nil : comment
            transitions[idx].ratedAt = (rating != nil || (comment?.isEmpty == false)) ? Date() : nil
        }
        Task { await loadUnratedCount() }
    }

    private func quickRate(record: TransitionDiagnostics.TransitionRecord) {
        // Escenario rápido: abrir sheet directamente; la slider intuición ya
        // estaba en el detail. Mantenemos un punto único de edición.
        presentedRecord = record
    }

    private func deleteComment(for recordId: UUID) {
        TransitionDiagnostics.shared.deleteOpinion(recordId: recordId)
        if let idx = transitions.firstIndex(where: { $0.id == recordId }) {
            transitions[idx].userComment = nil
            transitions[idx].deletedAt = Date()
        }
    }

    // MARK: - AirPods route detection

    private func startRouteObserver() {
        airpodsConnected = Self.isAirPodsConnected()
        let nc = NotificationCenter.default
        routeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let connected = Self.isAirPodsConnected()
                if connected != self.airpodsConnected {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        self.airpodsConnected = connected
                    }
                }
            }
        }
    }

    private func stopRouteObserver() {
        if let obs = routeObserver {
            NotificationCenter.default.removeObserver(obs)
            routeObserver = nil
        }
    }

    private static func isAirPodsConnected() -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { output in
            let isBT = [AVAudioSession.Port.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains(output.portType)
            return isBT && output.portName.lowercased().contains("airpod")
        }
    }

    // MARK: - Helpers

    private func meanColor(_ mean: Double) -> Color {
        if mean >= 7 { return .green }
        if mean >= 4 { return .orange }
        return .red
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Hoy" }
        if cal.isDateInYesterday(date) { return "Ayer" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day ?? 0
        if days < 7 { return "Hace \(days) días" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "d 'de' MMMM"
        return f.string(from: date)
    }
}

// MARK: - Filter chip

private struct FilterChip: View {
    let filter: TransitionHistoryView.HistoryFilter
    let isSelected: Bool
    let unratedBadge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let img = filter.systemImage {
                    Image(systemName: img)
                        .font(.caption.weight(.semibold))
                }
                Text(filter.label)
                    .font(.subheadline.weight(.medium))
                if let count = unratedBadge {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.red, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? Color.white : filter.tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule().fill(filter.tint.gradient)
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
            .overlay {
                if !isSelected {
                    Capsule().strokeBorder(filter.tint.opacity(0.3), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transition row

private struct TransitionRow: View {
    let record: TransitionDiagnostics.TransitionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Linea 1: type pill + hora + fade + rating
            HStack(spacing: 10) {
                Text(record.type)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(typeColor(record.type))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(typeColor(record.type).opacity(0.15), in: Capsule())

                Text(record.date, format: .dateTime.hour().minute())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(String(format: "%.1fs", record.fadeDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Spacer()

                ratingView
            }

            // Linea 2: titulos
            Text("\(record.fromTitle) → \(record.toTitle)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            // Linea 3: tokens coloreados de efectos activos.
            // Sin background, monocolor por efecto — patrón heredado del log
            // textual viejo (function `historyToken`). Permite escanear de
            // un vistazo qué procesó el algoritmo en cada transición.
            effectsRow
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var effectsRow: some View {
        let tokens = activeTokens
        if !tokens.isEmpty {
            // ScrollView horizontal — la lista de tokens activos puede sumar
            // 10+ etiquetas y desbordar el ancho de pantalla. Apple Music
            // y Photos usan este patrón para chips/tags variables.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                        Text(token.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(token.color)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    /// Lista de tokens (label + color) por orden de relevancia. Solo aparecen
    /// los efectos realmente activos en este record. anticipationReason se
    /// abrevia para no comerse media línea (e.g. "outroSlopeSteep+filtersAgg"
    /// → "slope+filt"). Preset "normal" se omite (no aporta señal visual).
    private var activeTokens: [(label: String, color: Color)] {
        var out: [(String, Color)] = []
        let preset = record.filterPreset
        if !preset.isEmpty && preset.lowercased() != "normal" {
            out.append((preset, presetColor(preset)))
        }
        if record.beatSynced     { out.append(("beat", .cyan)) }
        if record.timeStretched  { out.append(("stretch", .purple)) }
        if record.tier4Active    { out.append(("tier4", .indigo)) }
        if record.useBassKill    { out.append(("kill", .red)) }
        if record.useMidScoop    { out.append(("mid-scoop", .orange)) }
        if record.useHighShelfCut { out.append(("hi-shelf", .orange)) }
        if record.useDynamicQ    { out.append(("dynQ", .teal)) }
        if record.useNotchSweep  { out.append(("notch", .purple)) }
        if record.useStutterCut  { out.append(("stutter", .orange)) }
        if record.bRapidFadeIn   { out.append(("rapidB", .cyan)) }
        if record.chillRecipeApplied == true { out.append(("chill", .mint)) }
        if record.genreCapApplied == true { out.append(("cap-genre", .yellow)) }
        if record.entryFinalCapApplied == true { out.append(("cap-final", .yellow)) }
        if let reason = record.anticipationReason, !reason.isEmpty {
            out.append(("ant:\(abbreviateReason(reason))", .pink))
        }
        return out
    }

    /// Acorta valores largos de `anticipationReason` para que el token quepa
    /// en una línea sin comerse el resto del row. "outroSlopeSteep" → "slope",
    /// "filtersAggressive" → "filt", combinaciones quedan "slope+filt".
    private func abbreviateReason(_ reason: String) -> String {
        reason
            .replacingOccurrences(of: "outroSlopeSteep", with: "slope")
            .replacingOccurrences(of: "filtersAggressive", with: "filt")
    }

    @ViewBuilder
    private var ratingView: some View {
        if let r = record.userRating {
            RatingBadge(rating: r, hasComment: (record.userComment ?? "").isEmpty == false)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "circle.dashed")
                    .font(.caption2)
                Text("—")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)
        }
    }

    private func presetColor(_ preset: String) -> Color {
        switch preset.lowercased() {
        case "anticipation":  return .blue
        case "energy-down":   return .orange
        case "aggressive":    return .red
        case "normal":        return .secondary
        default:              return .secondary
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "CROSSFADE":        return .blue
        case "EQ_MIX":           return .purple
        case "CUT":              return .red
        case "NATURAL_BLEND":    return .green
        case "BEAT_MATCH_BLEND", "BMB": return .cyan
        case "CUT_A_FADE_IN_B":  return .orange
        case "FADE_OUT_A_CUT_B": return .yellow
        case "STEM_MIX":         return .mint
        case "DROP_MIX":         return .pink
        case "CLEAN_HANDOFF":    return .gray
        case "VINYL_STOP":       return .indigo
        default:                 return .secondary
        }
    }
}

// MARK: - Detail sheet

/// Sheet con grabber visible. Slider rating + textarea autosave debounced 1s
/// + sección "Detalles técnicos" siempre visible scrollable (Apple Notes style).
struct TransitionDetailSheet: View {
    let record: TransitionDiagnostics.TransitionRecord
    let onCommit: (Int?, String?) -> Void
    let onDeleteComment: () -> Void

    @State private var rating: Int
    @State private var comment: String
    @State private var lastSavedRating: Int
    @State private var lastSavedComment: String
    @State private var commentDebounceTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    init(
        record: TransitionDiagnostics.TransitionRecord,
        onCommit: @escaping (Int?, String?) -> Void,
        onDeleteComment: @escaping () -> Void
    ) {
        self.record = record
        self.onCommit = onCommit
        self.onDeleteComment = onDeleteComment
        let initialRating = record.userRating ?? 0
        let initialComment = record.userComment ?? ""
        self._rating = State(initialValue: initialRating)
        self._comment = State(initialValue: initialComment)
        self._lastSavedRating = State(initialValue: initialRating)
        self._lastSavedComment = State(initialValue: initialComment)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard
                    ratingCard
                    commentCard
                    if (record.userComment ?? "").isEmpty == false || !comment.isEmpty {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Borrar comentario")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .foregroundStyle(.red)
                    }
                    technicalSection
                    Color.clear.frame(height: 24)
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Transición")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
            .alert("Borrar comentario", isPresented: $showDeleteConfirm) {
                Button("Cancelar", role: .cancel) {}
                Button("Borrar", role: .destructive) {
                    comment = ""
                    lastSavedComment = ""
                    onDeleteComment()
                }
            } message: {
                Text("El rating se mantiene. Solo se borra el texto del comentario.")
            }
            .onChange(of: rating) { _, newValue in
                if newValue != lastSavedRating {
                    lastSavedRating = newValue
                    onCommit(newValue == 0 ? nil : newValue, comment.isEmpty ? nil : comment)
                }
            }
            .onChange(of: comment) { _, newValue in
                scheduleCommentDebounce(value: newValue)
            }
            .onDisappear {
                // Force-flush si quedó un debounce en vuelo.
                commentDebounceTask?.cancel()
                if comment != lastSavedComment {
                    lastSavedComment = comment
                    onCommit(rating == 0 ? nil : rating, comment.isEmpty ? nil : comment)
                }
            }
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(record.fromTitle)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                Text(record.toTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
            }
            HStack(spacing: 8) {
                typePill(record.type)
                if let v = record.algorithmVersion {
                    Text(v)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Text(record.date, format: .dateTime.day().month().hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var ratingCard: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Mi valoración", systemImage: "star.bubble.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if rating > 0 {
                    Text("\(rating)/10")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(LinearGradient(
                            colors: [.yellow, .orange],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.yellow.opacity(0.15), in: Capsule())
                } else {
                    Text("Sin valorar")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                StarRatingControl(rating: $rating, size: 36)
                Spacer()
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var commentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Comentario", systemImage: "text.bubble.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $comment)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(8)
                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .font(.body)
            HStack {
                Text("Autosave activo")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if comment != lastSavedComment {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if !comment.isEmpty {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var technicalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Detalles técnicos")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            techBlock(title: "Decisión", rows: [
                ("Type", record.type),
                ("Reason", record.transitionReason.isEmpty ? "—" : record.transitionReason),
                ("Entry", String(format: "%.1fs", record.entryPoint)),
                ("Fade", String(format: "%.1fs", record.fadeDuration)),
                ("Offset", String(format: "%.1fs", record.startOffset)),
                ("Anticipation", record.anticipationTime > 0
                    ? String(format: "%.1fs (%@)", record.anticipationTime, record.anticipationReason ?? "—")
                    : "0.0s")
            ])

            techBlock(title: "BPM / Beat", rows: [
                ("BPM A → B", String(format: "%.1f → %.1f", record.bpmA, record.bpmB)),
                ("Diff", record.bpmA > 0 && record.bpmB > 0 ? String(format: "%.1f", abs(record.bpmA - record.bpmB)) : "—"),
                ("Synced", record.beatSynced ? "Yes" : "No"),
                ("Time stretch", record.timeStretched
                    ? String(format: "rateA=%.3f rateB=%.3f", record.rateA, record.rateB)
                    : "Off")
            ])

            effectsCard

            techBlock(title: "Análisis", rows: [
                ("Energy A → B", String(format: "%.2f → %.2f", record.energyA, record.energyB)),
                ("Danceability", String(format: "%.2f", record.danceability)),
                ("Outro instr.", record.isOutroInstrumental ? "Yes" : "No"),
                ("Intro instr.", record.isIntroInstrumental ? "Yes" : "No"),
                ("ReplayGain A/B", String(format: "%.2f / %.2f", record.replayGainA, record.replayGainB))
            ])

            techBlock(title: "Telemetría perceptual", rows: perceptualRows)

            techBlock(title: "Géneros B", rows: [
                ("Tags", (record.bGenres ?? []).isEmpty ? "—" : (record.bGenres ?? []).joined(separator: ", "))
            ])

            techBlock(title: "Trazabilidad", rows: [
                ("buildId", record.buildId ?? "—"),
                ("sessionId", record.sessionId?.uuidString.prefix(8).description ?? "—"),
                ("recordId", record.id.uuidString.prefix(8).description),
                ("ratedAt", record.ratedAt.map { $0.formatted(.dateTime.day().month().hour().minute()) } ?? "—"),
                ("deletedAt (comment)", record.deletedAt.map { $0.formatted(.dateTime.day().month().hour().minute()) } ?? "—")
            ])
        }
    }

    /// Card "Filtros y efectos" con cada bandera activa renderizada como pill
    /// coloreado. Pills inactivos quedan grayed para que el director vea de
    /// un vistazo qué disparó y qué no en esta transición concreta.
    private var effectsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Filtros y efectos")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // Header rows: preset + enabled + skipBFilters como info compacta.
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Text("Preset")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Spacer()
                    Text(record.filterPreset.isEmpty ? "—" : record.filterPreset)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider().padding(.leading, 14)
                HStack(alignment: .top) {
                    Text("Enabled")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Spacer()
                    Text(record.filtersEnabled ? "Yes" : "No")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(record.filtersEnabled
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(.tertiary))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider().padding(.leading, 14)
                HStack(alignment: .top) {
                    Text("Skip B filters")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Spacer()
                    Text(record.skipBFilters ? "Yes" : "No")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(record.skipBFilters
                            ? AnyShapeStyle(Color.yellow)
                            : AnyShapeStyle(.tertiary))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            // Pills coloreados — adaptive grid wraps automáticamente cuando
            // el ancho varía con dynamic type / orientación. El `maximum: 160`
            // deja margen para "entryFinalCap" (13 chars) bajo accessibility
            // dynamic type sin que el pill se aplaste o desborde de la card.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(allEffectPills, id: \.label) { pill in
                    effectPill(pill)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Lista completa de efectos auditables en cada record. Se muestran todos
    /// (activos e inactivos) para que el director compare lo que disparó vs
    /// lo que no. Los inactivos van con opacidad reducida + color terciario.
    private var allEffectPills: [EffectPill] {
        [
            EffectPill(label: "midScoop",     active: record.useMidScoop,      color: .orange),
            EffectPill(label: "hiShelfCut",   active: record.useHighShelfCut,  color: .orange),
            EffectPill(label: "bassKill",     active: record.useBassKill,      color: .red),
            EffectPill(label: "dynamicQ",     active: record.useDynamicQ,      color: .teal),
            EffectPill(label: "notchSweep",   active: record.useNotchSweep,    color: .purple),
            EffectPill(label: "stutterCut",   active: record.useStutterCut,    color: .orange),
            EffectPill(label: "bRapidFadeIn", active: record.bRapidFadeIn,     color: .cyan),
            EffectPill(label: "tier4",        active: record.tier4Active,      color: .indigo),
            EffectPill(label: "beatSync",     active: record.beatSynced,       color: .cyan),
            EffectPill(label: "timeStretch",  active: record.timeStretched,    color: .purple),
            EffectPill(label: "chillRecipe",  active: record.chillRecipeApplied == true, color: .mint),
            EffectPill(label: "genreCap",     active: record.genreCapApplied == true, color: .yellow),
            EffectPill(label: "entryFinalCap", active: record.entryFinalCapApplied == true, color: .yellow)
        ]
    }

    private struct EffectPill: Hashable {
        let label: String
        let active: Bool
        let color: Color
    }

    @ViewBuilder
    private func effectPill(_ pill: EffectPill) -> some View {
        Text(pill.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(pill.active ? AnyShapeStyle(pill.color) : AnyShapeStyle(.tertiary))
            // Defensa contra desborde con dynamic type accessibility o
            // labels largos como "entryFinalCap": forzamos 1 línea y
            // permitimos que el texto se reduzca hasta el 75%. La capsule
            // crece con el contenido pero respeta el max de la columna.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                pill.active
                    ? AnyShapeStyle(pill.color.opacity(0.15))
                    : AnyShapeStyle(Color.gray.opacity(0.08)),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(pill.active ? pill.color.opacity(0.3) : Color.clear, lineWidth: 0.5)
            )
    }

    private var perceptualRows: [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("entryPointSource", record.entryPointSource ?? "—"))
        rows.append(("tier4FailedGate", record.tier4FailedGate ?? "—"))
        if let s = record.introSlopeB { rows.append(("introSlopeB", String(format: "%.4f /s", s))) }
        if let d = record.downbeatDensityB20s { rows.append(("downbeatDensB20s", String(format: "%.2f", d))) }
        if let c = record.chillRecipeApplied { rows.append(("chillRecipe", c ? "Yes" : "No")) }
        if let g = record.genreCapApplied { rows.append(("genreCap", g ? "Applied" : "Skipped")) }
        if let f = record.entryFinalCapApplied { rows.append(("entryFinalCap", f ? "Applied" : "Skipped (drop-driven exempt)")) }
        return rows
    }

    @ViewBuilder
    private func techBlock(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                    HStack(alignment: .top) {
                        Text(row.0)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                        Spacer()
                        Text(row.1)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    if idx < rows.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func typePill(_ type: String) -> some View {
        Text(type)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(typeColor(type).gradient, in: Capsule())
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "CROSSFADE":        return .blue
        case "EQ_MIX":           return .purple
        case "CUT":              return .red
        case "NATURAL_BLEND":    return .green
        case "BEAT_MATCH_BLEND", "BMB": return .cyan
        case "CUT_A_FADE_IN_B":  return .orange
        case "FADE_OUT_A_CUT_B": return .yellow
        case "STEM_MIX":         return .mint
        case "DROP_MIX":         return .pink
        case "CLEAN_HANDOFF":    return .gray
        case "VINYL_STOP":       return .indigo
        default:                 return .secondary
        }
    }

    private func scheduleCommentDebounce(value: String) {
        commentDebounceTask?.cancel()
        commentDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if value != lastSavedComment {
                    lastSavedComment = value
                    onCommit(rating == 0 ? nil : rating, value.isEmpty ? nil : value)
                }
            }
        }
    }
}

// MARK: - Active transition view

/// Telemetría en tiempo real del crossfade activo. Conserva las secciones que
/// hacían falta para tunear in-flight (filtros, beat sync, time stretch,
/// real-time, environment). Sin sección "Log file" — el log se eliminó.
struct TransitionActiveView: View {
    private let diag = TransitionDiagnostics.shared
    private let nowPlaying = NowPlayingState.shared

    var body: some View {
        List {
            backendSection
            currentPlaybackSection
            analysisCacheSection
            environmentSection

            if diag.isActive {
                activeTransitionSection
                filtersSection
                beatSyncSection
                timeStretchSection
                realTimeSection
            } else {
                Section("Transition") {
                    HStack {
                        Image(systemName: "waveform.slash")
                            .foregroundStyle(.secondary)
                        Text("No active crossfade")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .task {
            let url = NavidromeService.shared.backendURL() ?? "N/A"
            diag.updateBackendStatus(connected: BackendState.shared.isAvailable, url: url)
        }
    }

    // MARK: - Backend
    private var backendSection: some View {
        Section("Audiorr Backend") {
            diagRow("Status", value: BackendState.shared.isAvailable ? "Connected" : "Disconnected",
                    color: BackendState.shared.isAvailable ? .green : .red)
            diagRow("URL", value: NavidromeService.shared.backendURL() ?? "N/A")
            if BackendState.shared.isChecking {
                HStack {
                    Text("Checking…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
            Button("Force Recheck") {
                BackendState.shared.invalidateAndRecheck()
            }
            diagRow("Hub", value: ConnectService.shared.hubConnected ? "Connected" : "Disconnected",
                    color: ConnectService.shared.hubConnected ? .green : .orange)
        }
    }

    // MARK: - Analysis Cache
    @State private var cacheActionFeedback: String?

    private var analysisCacheSection: some View {
        Section("Analysis Cache") {
            Button {
                let id = nowPlaying.songId
                let title = nowPlaying.title
                guard !id.isEmpty else {
                    cacheActionFeedback = "No song playing"
                    return
                }
                Task {
                    await AnalysisCacheService.shared.invalidate(songId: id)
                    await MainActor.run {
                        cacheActionFeedback = "Re-analysis queued for ‘\(title)’"
                    }
                }
            } label: {
                Label("Re-analyze Current Track", systemImage: "arrow.clockwise.circle")
            }
            .disabled(nowPlaying.songId.isEmpty)

            Button(role: .destructive) {
                Task {
                    await AnalysisCacheService.shared.invalidateAll()
                    await MainActor.run {
                        cacheActionFeedback = "All analysis cache cleared"
                    }
                }
            } label: {
                Label("Clear All Analysis Cache", systemImage: "trash")
            }

            if let feedback = cacheActionFeedback {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Current Playback
    private var currentPlaybackSection: some View {
        Section("Now Playing") {
            if nowPlaying.isVisible {
                diagRow("Song", value: nowPlaying.title)
                diagRow("Artist", value: nowPlaying.artist)
                diagRow("Progress", value: "\(formatTime(nowPlaying.progress)) / \(formatTime(nowPlaying.duration))")
                diagRow("State", value: nowPlaying.isPlaying ? "Playing" : "Paused",
                        color: nowPlaying.isPlaying ? .green : .orange)
                diagRow("Route", value: "\(nowPlaying.audioRouteName) (\(nowPlaying.audioRouteIcon))")
                diagRow("Crossfading", value: nowPlaying.isCrossfading ? "YES" : "No",
                        color: nowPlaying.isCrossfading ? .cyan : .secondary)
            } else {
                Text("Nothing playing")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Environment
    private var environmentSection: some View {
        Section("Environment") {
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute
            let outputName = route.outputs.first?.portName ?? "Unknown"
            let isBT = route.outputs.contains { [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP].contains($0.portType) }
            let isCP = route.outputs.contains { $0.portType == .carAudio }

            diagRow("Audio Route", value: outputName)
            diagRow("Bluetooth", value: isBT ? "Active" : "No", color: isBT ? .blue : .secondary)
            diagRow("CarPlay", value: isCP ? "Active" : "No", color: isCP ? .green : .secondary)
            diagRow("IO Buffer", value: String(format: "%.1f ms", session.ioBufferDuration * 1000))
            diagRow("Sample Rate", value: String(format: "%.0f Hz", session.sampleRate))
            diagRow("Output Latency", value: String(format: "%.1f ms", session.outputLatency * 1000))

            if let snap = diag.networkSnapshotStart, diag.isActive {
                Divider()
                diagRow("Route at start", value: snap.audioRoute)
                diagRow("App state at start", value: snap.appState)
            }
        }
    }

    // MARK: - Active transition

    private var activeTransitionSection: some View {
        Section("Transition Decision") {
            diagRow("Type", value: diag.transitionType, color: typeColor(diag.transitionType))
            diagRow("From", value: diag.currentTitle)
            diagRow("To", value: diag.nextTitle)
            diagRow("Fade Duration", value: String(format: "%.1fs", diag.fadeDuration))
            diagRow("Entry Point", value: String(format: "%.1fs", diag.entryPoint))
            diagRow("Start Offset", value: String(format: "%.1fs", diag.startOffset))
            if diag.anticipationTime > 0 {
                diagRow("Anticipation", value: String(format: "%.1fs", diag.anticipationTime), color: .purple)
            }
            diagRow("Energy A", value: String(format: "%.2f", diag.energyA), color: energyColor(diag.energyA))
            diagRow("Energy B", value: String(format: "%.2f", diag.energyB), color: energyColor(diag.energyB))
            diagRow("Danceability", value: String(format: "%.2f", diag.danceability))
            diagRow("Outro Instrumental", value: diag.isOutroInstrumental ? "Yes" : "No")
            diagRow("Intro Instrumental", value: diag.isIntroInstrumental ? "Yes" : "No")
            diagRow("ReplayGain A", value: String(format: "%.3f", diag.replayGainA))
            diagRow("ReplayGain B", value: String(format: "%.3f", diag.replayGainB))
        }
    }

    private var filtersSection: some View {
        Section("Filters") {
            diagRow("Enabled", value: diag.filtersEnabled ? "YES" : "NO",
                    color: diag.filtersEnabled ? .green : .red)
            diagRow("Preset", value: diag.filterPreset, color: presetColor(diag.filterPreset))
            diagRow("Mid Scoop (vocal)", value: diag.useMidScoop ? "ACTIVE" : "Off",
                    color: diag.useMidScoop ? .orange : .secondary)
            diagRow("Hi-Shelf Cut", value: diag.useHighShelfCut ? "ACTIVE" : "Off",
                    color: diag.useHighShelfCut ? .orange : .secondary)
            diagRow("Bass Kill", value: diag.useBassKill ? "ACTIVE" : "Off",
                    color: diag.useBassKill ? .red : .secondary)
            diagRow("Dynamic Q (A+B)", value: diag.useDynamicQ ? "ACTIVE" : "Off",
                    color: diag.useDynamicQ ? .cyan : .secondary)
            diagRow("Notch Sweep (B)", value: diag.useNotchSweep ? "ACTIVE" : "Off",
                    color: diag.useNotchSweep ? .purple : .secondary)
            diagRow("Stutter Cut (A)", value: diag.useStutterCut ? "ACTIVE" : "Off",
                    color: diag.useStutterCut ? .orange : .secondary)
            diagRow("B Filters", value: diag.skipBFilters ? "SKIPPED" : "Active",
                    color: diag.skipBFilters ? .yellow : .green)
        }
    }

    private var beatSyncSection: some View {
        Section("Beat Sync") {
            diagRow("Beat Data", value: diag.isBeatSynced ? "YES" : "No",
                    color: diag.isBeatSynced ? .green : .secondary)
            if diag.bpmA > 0 { diagRow("BPM A", value: String(format: "%.1f", diag.bpmA)) }
            if diag.bpmB > 0 { diagRow("BPM B", value: String(format: "%.1f", diag.bpmB)) }
            if diag.bpmA > 0 && diag.bpmB > 0 {
                let diff = abs(diag.bpmA - diag.bpmB)
                diagRow("BPM Diff", value: String(format: "%.1f", diff),
                        color: diff < 3 ? .green : diff < 8 ? .yellow : .red)
            }
            if !diag.beatSyncInfo.isEmpty {
                diagRow("Info", value: diag.beatSyncInfo)
            }
        }
    }

    private var timeStretchSection: some View {
        Section("Time Stretch") {
            diagRow("Enabled", value: diag.useTimeStretch ? "YES" : "No",
                    color: diag.useTimeStretch ? .cyan : .secondary)
            if diag.useTimeStretch {
                diagRow("Target Rate A", value: String(format: "%.3f", diag.rateA))
                diagRow("Target Rate B", value: String(format: "%.3f", diag.rateB))
                diagRow("Current Rate A", value: String(format: "%.3f", diag.currentRateA),
                        color: diag.currentRateA != 1.0 ? .cyan : .secondary)
            }
        }
    }

    private var realTimeSection: some View {
        Section("Real-time (1Hz)") {
            diagRow("Elapsed", value: String(format: "%.1fs / %.1fs", diag.elapsed, diag.fadeDuration))
            VStack(alignment: .leading, spacing: 4) {
                volumeBar(label: "Vol A", value: diag.volumeA, color: .red)
                volumeBar(label: "Vol B", value: diag.volumeB, color: .green)
            }
            diagRow("Master Vol", value: String(format: "%.2f", diag.masterVolume))
            diagRow("HP Freq A", value: String(format: "%.0f Hz", diag.highpassFreqA))
            diagRow("HP Freq B", value: String(format: "%.0f Hz", diag.highpassFreqB))
            if diag.useDynamicQ {
                diagRow("Q-A (Dynamic)", value: String(format: "%.2f", diag.dynamicQA),
                        color: diag.dynamicQA > 2.0 ? .cyan : .secondary)
                diagRow("Q-B (Twin)", value: String(format: "%.2f", diag.dynamicQB),
                        color: diag.dynamicQB > 2.0 ? .cyan : .secondary)
            }
            if diag.useNotchSweep {
                diagRow("Notch Freq B", value: String(format: "%.0f Hz", diag.notchFreqB),
                        color: .purple)
                diagRow("Notch Depth B", value: String(format: "%.1f dB", diag.notchGainB),
                        color: diag.notchGainB < -18 ? .purple : .secondary)
            }
            diagRow("Lowshelf A", value: String(format: "%.1f dB", diag.lowshelfGainA),
                    color: diag.useBassKill && diag.lowshelfGainA < -30 ? .red : .primary)
            diagRow("Lowshelf B", value: String(format: "%.1f dB", diag.lowshelfGainB))
            diagRow("Pan A", value: String(format: "%.3f", diag.panA))
            diagRow("Pan B", value: String(format: "%.3f", diag.panB))
        }
    }

    // MARK: - Helpers

    private func volumeBar(label: String, value: Float, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, value)))))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.3f", value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }

    private func diagRow(_ label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func formatTime(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "CROSSFADE":        return .blue
        case "EQ_MIX":           return .purple
        case "CUT":              return .red
        case "NATURAL_BLEND":    return .green
        case "BEAT_MATCH_BLEND", "BMB": return .cyan
        case "CUT_A_FADE_IN_B":  return .orange
        case "FADE_OUT_A_CUT_B": return .yellow
        case "STEM_MIX":         return .mint
        case "DROP_MIX":         return .pink
        case "CLEAN_HANDOFF":    return .gray
        case "VINYL_STOP":       return .indigo
        default:                 return .secondary
        }
    }

    private func presetColor(_ preset: String) -> Color {
        switch preset {
        case "aggressive":     return .red
        case "anticipation":   return .purple
        case "energy-down":    return .blue
        case "gentle":         return .mint
        case "stem-mix":       return .teal
        case "drop-mix":       return .pink
        case "normal":         return .green
        case "clean-handoff":  return .gray
        default:               return .secondary
        }
    }

    private func energyColor(_ energy: Double) -> Color {
        if energy > 0.7 { return .red }
        if energy > 0.4 { return .orange }
        return .green
    }
}
