import SwiftUI
import AVKit

/// Sheet that shows available playback devices — local audio route, hub devices, LAN/Cast.
struct DevicePickerView: View {
    @Environment(\.dismiss) private var dismiss
    private var connect = ConnectService.shared
    private var state = NowPlayingState.shared

    var body: some View {
        NavigationStack {
            List {
                // Current audio output + system route picker
                audioRouteSection

                // Hub-connected devices (other instances of Audiorr)
                if !otherHubDevices.isEmpty {
                    hubDevicesSection
                }

                // LAN devices (Chromecast, AirPlay receivers, etc.)
                if !connect.lanDevices.isEmpty {
                    lanDevicesSection
                }

                // Connection status
                if !connect.hubConnected {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Conectando al hub...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Reproducir en")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Audio Route Section

    private var isLocalActive: Bool {
        connect.activeDeviceId == nil && !state.isRemote
    }

    private var audioRouteSection: some View {
        Section {
            // Current audio output
            HStack(spacing: 14) {
                Image(systemName: state.audioRouteIcon)
                    .font(.system(size: 22))
                    .foregroundStyle(isLocalActive ? .green : .primary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.audioRouteName)
                        .font(.body)
                        .foregroundStyle(isLocalActive ? .green : .primary)

                    if isLocalActive {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                            Text("Reproduciendo")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()

                if isLocalActive {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if state.isRemote || connect.activeDeviceId != nil {
                    connect.switchToLocal()
                }
            }

            // System route picker (AirPlay, AirPods switch, etc.)
            HStack(spacing: 14) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 22))
                    .foregroundStyle(.primary)
                    .frame(width: 32)

                Text("AirPlay y Bluetooth")
                    .font(.body)

                Spacer()

                // Invisible AVRoutePickerView overlay
                SystemRoutePickerButton()
                    .frame(width: 32, height: 32)
            }
        } header: {
            Text("Salida de audio")
        } footer: {
            if state.audioRouteIcon != "iphone" {
                Text("Conectado a \(state.audioRouteName)")
            }
        }
    }

    // MARK: - Hub devices

    private var otherHubDevices: [ConnectDevice] {
        connect.connectedDevices.filter { !$0.isThisDevice }
    }

    private var hubDevicesSection: some View {
        Section("Audiorr Connect") {
            ForEach(otherHubDevices) { device in
                let isActive = state.isRemote && state.remoteDeviceName == device.name
                deviceRow(
                    icon: device.type.icon,
                    name: device.name,
                    subtitle: isActive ? "Reproduciendo" : nil,
                    isActive: isActive
                ) {
                    // Request sync to get this device's playback state
                    connect.requestSync()
                }
            }
        }
    }

    // MARK: - LAN devices

    private var lanDevicesSection: some View {
        Section("Dispositivos en la red") {
            ForEach(connect.lanDevices) { device in
                let isActive = connect.activeDeviceId == device.id
                deviceRow(
                    icon: "tv",
                    name: device.name,
                    subtitle: isActive ? "Transmitiendo" : nil,
                    isActive: isActive
                ) {
                    if isActive {
                        connect.stopCasting()
                    } else {
                        connect.castToDevice(device)
                    }
                }
            }
        }
    }

    // MARK: - Row

    private func deviceRow(
        icon: String,
        name: String,
        subtitle: String?,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isActive ? .green : .primary)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .foregroundStyle(isActive ? .green : .primary)

                    if let subtitle {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(.green)
                                .frame(width: 5, height: 5)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()

                if isActive {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System Route Picker (AVRoutePickerView wrapped for SwiftUI)

struct SystemRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .label
        picker.activeTintColor = .systemGreen
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
