import SwiftUI
import UIKit

struct ManualWiFiJoinSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ssid = ""
    @State private var password = ""
    @State private var isWEP = false

    let join: (String, String?, Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera network") {
                    TextField("SSID shown by camera", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("manual-wifi-ssid")
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("manual-wifi-password")
                    Toggle("Older WEP network", isOn: $isWEP)
                }

                Section {
                    Button {
                        let enteredSSID = ssid
                        let enteredPassword = password.isEmpty ? nil : password
                        dismiss()
                        join(enteredSSID, enteredPassword, isWEP)
                    } label: {
                        Label("Join camera Wi-Fi", systemImage: "wifi")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("join-manual-camera-wifi")
                } footer: {
                    Text("GM1 Sync asks iOS to join this network. The password stays in the system Wi-Fi configuration and is never written to the diagnostic log.")
                }

                Section("If iOS cannot join") {
                    Button("Open GM1 Sync Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                    Text("From Settings, open Wi-Fi and join the SSID shown on the GM1S. Return here once the camera network is connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Join Camera Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
