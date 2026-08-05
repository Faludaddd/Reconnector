import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var ipInput: String = ""
    @State private var tokenInput: String = ""
    @State private var showingSavedAlert = false
    @State private var showingSetupGuide = false
    
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
                        appState.ipAddress = ipInput
                        appState.authToken = tokenInput
                        appState.saveSettings()
                        showingSavedAlert = true
                    } label: {
                        Label("Save Settings", systemImage: "checkmark.circle.fill")
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Enter the IP address of your Android tablet. Default token: reconnector123")
                }
                
                // Watchdog Interval
                Section {
                    if let status = appState.status {
                        Picker("Check Interval", selection: Binding(
                            get: { status.interval },
                            set: { newValue in
                                Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).setInterval(minutes: newValue) }
                            }
                        )) {
                            Text("1 minute").tag(1)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("15 minutes").tag(15)
                            Text("30 minutes").tag(30)
                        }
                    } else {
                        Text("Connect to backend first").foregroundColor(.secondary)
                    }
                } header: {
                    Text("Watchdog")
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
                            Text(lastTime, style: .relative).foregroundColor(.secondary)
                        }
                    }
                    if let error = appState.connectionError {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                    Button("Reconnect Now") { appState.connectWebSocket() }
                } header: {
                    Text("Connection Status")
                }
                
                // Setup Guide
                Section {
                    NavigationLink {
                        SetupGuideView()
                    } label: {
                        Label("Setup Guide", systemImage: "book.fill")
                    }
                }
                
                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.3").foregroundColor(.secondary)
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
                Text("Settings saved. Reconnecting to backend...")
            }
            .onAppear {
                ipInput = appState.ipAddress
                tokenInput = appState.authToken
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationViewStyle(.stack)
    }
}

struct SetupGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Step 1
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue).frame(width: 28, height: 28)
                            Text("1").font(.caption).fontWeight(.bold).foregroundColor(.white)
                        }
                        Text("Start the Backend").font(.headline)
                    }
                    Text("Open Termux on your Android tablet and run:")
                        .font(.subheadline).foregroundColor(.secondary)
                    Text("python ~/reconnector/Backend/reconnector_api.py")
                        .font(.system(.caption, design: .monospaced))
                        .padding(10)
                        .background(Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(8)
                    Text("You should see '[STARTUP] Reconnector API starting...' in Termux.")
                        .font(.caption).foregroundColor(.secondary)
                }
                
                Divider()
                
                // Step 2
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue).frame(width: 28, height: 28)
                            Text("2").font(.caption).fontWeight(.bold).foregroundColor(.white)
                        }
                        Text("Find Your Tablet's IP").font(.headline)
                    }
                    Text("In Termux, run:")
                        .font(.subheadline).foregroundColor(.secondary)
                    Text("ifconfig")
                        .font(.system(.caption, design: .monospaced))
                        .padding(10)
                        .background(Color(UIColor.tertiarySystemBackground))
                        .cornerRadius(8)
                    Text("Look for the 'wlan0' section. The IP address looks like 192.168.1.70")
                        .font(.caption).foregroundColor(.secondary)
                }
                
                Divider()
                
                // Step 3
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue).frame(width: 28, height: 28)
                            Text("3").font(.caption).fontWeight(.bold).foregroundColor(.white)
                        }
                        Text("Connect the App").font(.headline)
                    }
                    Text("In Settings, enter the IP address and auth token (default: reconnector123). Tap Save Settings.")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                
                Divider()
                
                // Step 4
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue).frame(width: 28, height: 28)
                            Text("4").font(.caption).fontWeight(.bold).foregroundColor(.white)
                        }
                        Text("Verify Connection").font(.headline)
                    }
                    Text("Go to Dashboard. You should see live status from your tablet. If it shows 'Connecting...', check that Termux is running and both devices are on the same WiFi.")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                
                Divider()
                
                // Troubleshooting
                VStack(alignment: .leading, spacing: 12) {
                    Text("Troubleshooting").font(.headline).foregroundColor(.red)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Can't connect? Make sure both devices are on the same WiFi network.")
                        Text("• Backend offline? Run 'python ~/reconnector/Backend/reconnector_api.py' in Termux.")
                        Text("• Roblox not detected? Make sure Roblox is installed and running on the tablet.")
                        Text("• Need to install dependencies? Run 'pip install fastapi uvicorn websockets' in Termux.")
                    }
                    .font(.subheadline).foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Setup Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}
