import SwiftUI

// MARK: - View Model

@MainActor
final class StorageManagementViewModel: ObservableObject {
    @Published var totalCacheSize: Int64 = 0
    @Published var pinnedSize: Int64 = 0
    @Published var cachedSongCount: Int = 0
    @Published var groups: [DownloadGroup] = []
    @Published var maxCacheBytes: Int64 = PersistenceService.shared.offlineMaxCacheBytes
    @Published var autoCacheEnabled: Bool = PersistenceService.shared.offlineAutoCacheEnabled
    @Published var wifiOnly: Bool = PersistenceService.shared.offlineWifiOnly

    // Cache limit options in bytes
    static let cacheLimitOptions: [(label: String, bytes: Int64)] = [
        ("500 MB", 500 * 1024 * 1024),
        ("1 GB", 1_073_741_824),
        ("2 GB", 2_147_483_648),
        ("5 GB", 5_368_709_120),
        ("10 GB", 10_737_418_240),
        ("Sin límite", 0),
    ]

    func load() async {
        totalCacheSize = await OfflineStorageManager.shared.totalCacheSize()
        pinnedSize = await OfflineStorageManager.shared.pinnedSize()
        cachedSongCount = await OfflineStorageManager.shared.cachedSongCount()
        groups = DownloadManager.shared.groups()
    }

    func setMaxCache(_ bytes: Int64) {
        maxCacheBytes = bytes
        PersistenceService.shared.offlineMaxCacheBytes = bytes
        Task { await OfflineStorageManager.shared.evictIfNeeded() }
    }

    func toggleAutoCache(_ enabled: Bool) {
        autoCacheEnabled = enabled
        PersistenceService.shared.offlineAutoCacheEnabled = enabled
    }

    func toggleWifiOnly(_ enabled: Bool) {
        wifiOnly = enabled
        PersistenceService.shared.offlineWifiOnly = enabled
    }

    func clearUnpinned() async {
        await OfflineStorageManager.shared.deleteUnpinned()
        await load()
    }

    func clearAll() async {
        await OfflineStorageManager.shared.deleteAll()
        await load()
    }
}

// MARK: - View

struct StorageManagementView: View {
    @StateObject private var vm = StorageManagementViewModel()
    @State private var showClearUnpinnedConfirm = false
    @State private var showClearAllConfirm = false

    var body: some View {
        List {
            // Storage usage section
            Section {
                storageBar
                HStack {
                    Label("Canciones en caché", systemImage: "music.note")
                    Spacer()
                    Text("\(vm.cachedSongCount)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Tamaño total", systemImage: "externaldrive")
                    Spacer()
                    Text(formatBytes(vm.totalCacheSize))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Fijado (protegido)", systemImage: "pin.fill")
                    Spacer()
                    Text(formatBytes(vm.pinnedSize))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Uso de almacenamiento")
            }

            // Cache limit
            Section {
                Picker("Límite de caché", selection: $vm.maxCacheBytes) {
                    ForEach(StorageManagementViewModel.cacheLimitOptions, id: \.bytes) { option in
                        Text(option.label).tag(option.bytes)
                    }
                }
                .onChange(of: vm.maxCacheBytes) { _, newValue in
                    vm.setMaxCache(newValue)
                }
            } header: {
                Text("Límite")
            } footer: {
                Text("Las canciones más antiguas sin fijar se eliminan automáticamente al superar el límite.")
            }

            // Auto-cache settings
            Section {
                Toggle(isOn: Binding(
                    get: { vm.autoCacheEnabled },
                    set: { vm.toggleAutoCache($0) }
                )) {
                    Label("Auto-caché al reproducir", systemImage: "arrow.down.circle")
                }
                Toggle(isOn: Binding(
                    get: { vm.wifiOnly },
                    set: { vm.toggleWifiOnly($0) }
                )) {
                    Label("Solo descargar con Wi-Fi", systemImage: "wifi")
                }
            } header: {
                Text("Descargas automáticas")
            } footer: {
                Text("Con auto-caché activado, cada canción que reproduzcas se guarda para escuchar sin conexión.")
            }

            // Downloaded groups
            if !vm.groups.isEmpty {
                Section {
                    ForEach(vm.groups, id: \.groupId) { group in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.subheadline.weight(.medium))
                                Text("\(group.completedSongs)/\(group.totalSongs) canciones · \(group.groupType == "album" ? "Álbum" : "Playlist")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if group.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            if group.isComplete {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                ProgressView(value: group.progress)
                                    .frame(width: 40)
                            }
                        }
                    }
                } header: {
                    Text("Descargas")
                }
            }

            // Active downloads
            if !DownloadManager.shared.activeDownloads.isEmpty {
                Section {
                    ForEach(DownloadManager.shared.activeDownloads) { download in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(download.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(download.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if download.state == "active" {
                                ProgressView(value: download.progress)
                                    .frame(width: 50)
                            } else if download.state == "failed" {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                            } else {
                                Image(systemName: "clock")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if DownloadManager.shared.failedCount > 0 {
                        Button("Reintentar fallidas") {
                            DownloadManager.shared.retryFailed()
                        }
                    }
                } header: {
                    Text("Descargas activas")
                }
            }

            // Danger zone
            Section {
                Button("Borrar caché no fijado") {
                    showClearUnpinnedConfirm = true
                }
                .foregroundStyle(.orange)

                Button("Borrar todo el caché") {
                    showClearAllConfirm = true
                }
                .foregroundStyle(.red)
            } header: {
                Text("Gestión")
            } footer: {
                Text("\"Borrar caché no fijado\" elimina todo excepto el contenido fijado. \"Borrar todo\" elimina absolutamente todo.")
            }
        }
        .navigationTitle("Almacenamiento")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .refreshable { await vm.load() }
        .confirmationDialog("Borrar caché no fijado", isPresented: $showClearUnpinnedConfirm, titleVisibility: .visible) {
            Button("Borrar", role: .destructive) {
                Task { await vm.clearUnpinned() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se eliminarán \(formatBytes(vm.totalCacheSize - vm.pinnedSize)) de canciones en caché.")
        }
        .confirmationDialog("Borrar todo el caché", isPresented: $showClearAllConfirm, titleVisibility: .visible) {
            Button("Borrar todo", role: .destructive) {
                Task { await vm.clearAll() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Se eliminarán todas las canciones descargadas, incluyendo las fijadas.")
        }
    }

    // MARK: - Storage Bar

    private var storageBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let maxBytes = vm.maxCacheBytes > 0 ? vm.maxCacheBytes : max(vm.totalCacheSize * 2, 2_147_483_648)
                let totalRatio = min(CGFloat(vm.totalCacheSize) / CGFloat(maxBytes), 1.0)
                let pinnedRatio = min(CGFloat(vm.pinnedSize) / CGFloat(maxBytes), 1.0)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.blue.opacity(0.4))
                        .frame(width: geo.size.width * totalRatio, height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.green)
                        .frame(width: geo.size.width * pinnedRatio, height: 8)
                }
            }
            .frame(height: 8)

            HStack(spacing: 16) {
                Label("Fijado", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Label("Caché", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue.opacity(0.4))
                Spacer()
                if vm.maxCacheBytes > 0 {
                    Text("Límite: \(formatBytes(vm.maxCacheBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
