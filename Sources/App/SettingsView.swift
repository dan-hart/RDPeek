import SwiftUI

struct SettingsView: View {
    @AppStorage(NewDeviceDefaults.clipboardSharingKey)
    private var clipboardSharingEnabled = NewDeviceDefaults.clipboardSharingEnabled
    @AppStorage(NewDeviceDefaults.audioPlaybackKey)
    private var audioPlaybackEnabled = NewDeviceDefaults.audioPlaybackEnabled
    @AppStorage(NewDeviceDefaults.hideCertificateWarningsKey)
    private var hideCertificateWarnings = NewDeviceDefaults.hideCertificateWarnings
    @AppStorage(NewDeviceDefaults.timeoutSecondsKey)
    private var timeoutSeconds = NewDeviceDefaults.timeoutSeconds

    var body: some View {
        Form {
            Section {
                Toggle("Share clipboard", isOn: $clipboardSharingEnabled)
                Toggle("Play remote audio", isOn: $audioPlaybackEnabled)
                Toggle("Hide certificate warnings", isOn: $hideCertificateWarnings)
                Stepper(
                    "Connection timeout: \(timeoutSeconds)s",
                    value: $timeoutSeconds,
                    in: DeviceProfile.timeoutSecondsRange,
                    step: 1
                )
            } header: {
                Text("Defaults for New PCs")
            } footer: {
                Text("These apply to PCs you add from now on. Existing PCs keep their own settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
