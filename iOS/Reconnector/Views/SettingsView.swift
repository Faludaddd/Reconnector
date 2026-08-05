import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var ipInput: String = ""
    @State private var tokenInput: String = ""
    @State private var showingSavedAlert = false
    @State private var selectedInterval = 1
    
    var body: some View {
        NavigationView {
            Form {
                // Connection Section
                Section {
                    TextField("IP Address", text: $ipInput)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    SecureField("Auth Token", text: $tokenInput)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    
                    Button {
                        saveSettings()
                    } label: {
                        Label("Save Settings", systemImage: "checkmark.circle.fill")
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Enter the IP address of your Android tablet running the Reconnector backend. The default auth token is 'reconnector123'.")
                }
                
                // Watchdog Interval
                Section {
                    if let status = appState.status {
                        Picker("Check Interval", selection: Binding(
                            get: { status.interval },
                            set: { newValue in
                                selectedInterval = newValue
                                Task {
                                    try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).setInterval(minutes: newValue)
                                }
                            }
                        )) {
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                        }
                    } else {
                        Text("Connect to backend first")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Watchdog")
                } footer: {
                    Text("How often the bot checks if Roblox is still running.")
                }
                
                // Connection Status
                Section {
                    HStack {
                        Image(systemName: appState.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(appState.isConnected ? .green : .red)
                        Text("Status")
                        Spacer()
                        Text(appState.isConnected ? "Connected" : "Disconnected")
                            .foregroundColor(appState.isConnected ? .green : .red)
                    }
                    
                    if let lastTime = appState.lastConnectionTime {
                        HStack {
                            Text("Last Update")
                            Spacer()
                            Text(lastTime, style: .relative)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let error = appState.connectionError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    Button("Reconnect Now") {
                        appState.connectWebSocket()
                    }
                } header: {
                    Text("Connection Status")
                }
                
                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Backend")
                        Spacer()
                        Text(appState.status != nil ? "Online" : "Offline")
                            .foregroundColor(appState.status != nil ? .green : .red)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .alert("Settings Saved", isPresented: $showingSavedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your settings have been saved. The app will now reconnect to the backend.")
            }
            .onAppear {
                ipInput = appState.ipAddress
                tokenInput = appState.authToken
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }
    
    private func saveSettings() {
        appState.ipAddress = ipInput
        appState.authToken = tokenInput
        appState.saveSettings()
        showingSavedAlert = true
    }
}
