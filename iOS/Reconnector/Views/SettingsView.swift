import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var ipInput: String = ""
    @State private var tokenInput: String = ""
    @State private var showingSavedAlert = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("Connection") {
                    TextField("IP Address", text: $ipInput)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                    SecureField("Auth Token", text: $tokenInput)
                    Button("Save Settings") {
                        appState.ipAddress = ipInput
                        appState.authToken = tokenInput
                        appState.saveSettings()
                        showingSavedAlert = true
                    }
                }
                
                Section("Watchdog Interval") {
                    if let status = appState.status {
                        Picker("Interval", selection: Binding(
                            get: { status.interval },
                            set: { newValue in
                                Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).setInterval(minutes: newValue) }
                            }
                        )) {
                            Text("1 min").tag(1)
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                        }
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Connection")
                        Spacer()
                        Text(appState.isConnected ? "Connected" : "Disconnected")
                            .foregroundColor(appState.isConnected ? .green : .red)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Settings Saved", isPresented: $showingSavedAlert) {
                Button("OK", role: .cancel) {}
            }
            .onAppear {
                ipInput = appState.ipAddress
                tokenInput = appState.authToken
            }
        }
    }
}
