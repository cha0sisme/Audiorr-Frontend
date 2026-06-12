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
    @Published var lockScreenMotion: String = PersistenceService.shared.lockScreenMotion

    // Cache limit options in bytes
    static let cacheLimitOptions: [(label: String, bytes: Int64)] = [
        ("500 MB", 500 * 1024 * 1024),
        ("1 GB", 1_073_741_824),
        ("2 GB", 2_147_483_648),
        ("5 GB", 5_368_709_120),
        ("10 GB", 10_737_418_240),
        (L.noLimit, 0),
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

    func setLockScreenMotion(_ value: String) {
        lockScreenMotion = value
        PersistenceService.shared.lockScreenMotion = value
    }

    func clearUnpinned() async {
        await OfflineStorageManager.shared.deleteUnpinned()
        // Limpiar también los registros de grupo (y sus metas de browsing
        // offline) de lo no fijado — sin esto la sección "Descargas"
        // seguiría listando grupos cuyas canciones ya no existen.
        let removed = DownloadManager.shared.deleteGroupRecords(onlyUnpinned: true)
        await OfflineContentProvider.shared.deleteMetas(ids: removed)
        await load()
    }

    func clearAll() async {
        await OfflineStorageManager.shared.deleteAll()
        DownloadManager.shared.deleteGroupRecords(onlyUnpinned: false)
        await OfflineContentProvider.shared.deleteAllMetas()
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
                    Label(L.cachedSongs, systemImage: "music.note")
                    Spacer()
                    Text("\(vm.cachedSongCount)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label(L.totalSize, systemImage: "externaldrive")
                    Spacer()
                    Text(formatBytes(vm.totalCacheSize))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label(L.pinned, systemImage: "pin.fill")
                    Spacer()
                    Text(formatBytes(vm.pinnedSize))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L.storageUsage)
            }

            // Cache limit
            Section {
                Picker(L.limit, selection: $vm.maxCacheBytes) {
                    ForEach(StorageManagementViewModel.cacheLimitOptions, id: \.bytes) { option in
                        Text(option.label).tag(option.bytes)
                    }
                }
                .onChange(of: vm.maxCacheBytes) { _, newValue in
                    vm.setMaxCache(newValue)
                }
            } header: {
                Text(L.limit)
            } footer: {
                Text(L.cacheLimitFooter)
            }

            // Auto-cache settings
            Section {
                Toggle(isOn: Binding(
                    get: { vm.autoCacheEnabled },
                    set: { vm.toggleAutoCache($0) }
                )) {
                    Label(L.autoCacheOnPlay, systemImage: "arrow.down.circle")
                }
                Toggle(isOn: Binding(
                    get: { vm.wifiOnly },
                    set: { vm.toggleWifiOnly($0) }
                )) {
                    Label(L.wifiOnlyDownload, systemImage: "wifi")
                }
            } header: {
                Text(L.autoDownloads)
            } footer: {
                Text(L.autoCacheFooter)
            }

            // Lock Screen animated artwork (motion). Solo con backend Audiorr
            // disponible: los clips de motion los sirve ese backend, así que sin
            // conexión la opción no aplica y no debe mostrarse.
            if BackendState.shared.isAvailable {
            Section {
                Picker(selection: Binding(
                    get: { vm.lockScreenMotion },
                    set: { vm.setLockScreenMotion($0) }
                )) {
                    Text(L.motionAlways).tag("always")
                    Text(L.motionWifiOnly).tag("wifi")
                    Text(L.motionOff).tag("off")
                } label: {
                    Label(L.animatedArtworkLockScreen, systemImage: "photo.tv")
                }
            } header: {
                Text(L.animatedArtwork)
            } footer: {
                Text(L.animatedArtworkFooter)
            }
            }

            // Downloaded groups
            if !vm.groups.isEmpty {
                Section {
                    ForEach(vm.groups, id: \.groupId) { group in
                        HStack {
                            DownloadGroupCover(groupId: group.groupId)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title)
                                    .font(.subheadline.weight(.medium))
                                Text("\(group.completedSongs)/\(group.totalSongs) \(L.songsLabel.lowercased()) · \(group.groupType == "album" ? L.album : L.playlist)")
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
                    Text(L.downloads)
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
                        Button(L.retryFailed) {
                            DownloadManager.shared.retryFailed()
                        }
                    }
                } header: {
                    Text(L.activeDownloads)
                }
            }

            // Danger zone
            Section {
                Button(L.clearUnpinnedCache) {
                    showClearUnpinnedConfirm = true
                }
                .foregroundStyle(.orange)

                Button(L.clearAllCache) {
                    showClearAllConfirm = true
                }
                .foregroundStyle(.red)
            } header: {
                Text(L.management)
            } footer: {
                Text(L.managementFooter)
            }
        }
        .navigationTitle(L.storage)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        // Recarga en vivo: cubre cambios del caché originados fuera de esta
        // vista (eliminar descarga desde el botón de un álbum/playlist,
        // evicción LRU, descargas que completan) mientras está abierta.
        .task {
            for await _ in NotificationCenter.default.notifications(named: .audiorrOfflineCacheChanged) {
                await vm.load()
            }
        }
        .refreshable { await vm.load() }
        .confirmationDialog(L.clearUnpinnedCache, isPresented: $showClearUnpinnedConfirm, titleVisibility: .visible) {
            Button(L.delete, role: .destructive) {
                Task { await vm.clearUnpinned() }
            }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.clearUnpinnedConfirm(formatBytes(vm.totalCacheSize - vm.pinnedSize)))
        }
        .confirmationDialog(L.clearAllCache, isPresented: $showClearAllConfirm, titleVisibility: .visible) {
            Button(L.deleteAll, role: .destructive) {
                Task { await vm.clearAll() }
            }
            Button(L.cancel, role: .cancel) {}
        } message: {
            Text(L.clearAllConfirm)
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
                Label(L.pinnedLegend, systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Label(L.cacheLegend, systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue.opacity(0.4))
                Spacer()
                if vm.maxCacheBytes > 0 {
                    Text(L.cacheLimit(formatBytes(vm.maxCacheBytes)))
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

// MARK: - Download group cover

/// Miniatura de la cover de un grupo descargado (álbum/playlist), para que en el
/// gestor de descargas aparezca "tal cual" con su portada. Lee la cover
/// persistida en disco por `OfflineArtworkStore` (keyed por groupId al descargar).
private struct DownloadGroupCover: View {
    let groupId: String

    var body: some View {
        Group {
            if let img = OfflineArtworkStore.shared.image(forKey: groupId) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.tertiarySystemFill)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
