import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var ipInput = ""
    @State private var tokenInput = ""
    @State private var showingSavedAlert = false
    @State private var showingResetAlert = false
    
    var body: some View {
        NavigationView {
            Form {
                Section("Connection") {
                    TextField("IP Address", text: $ipInput).keyboardType(.decimalPad).disableAutocorrection(true)
                    SecureField("Auth Token", text: $tokenInput).disableAutocorrection(true)
                    Toggle("Auto-Connect on Launch", isOn: $appState.autoConnect)
                    Button("Save & Reconnect") { appState.ipAddress = ipInput; appState.authToken = tokenInput; appState.saveSettings(); showingSavedAlert = true }
                }
                
                Section("Watchdog") {
                    if let status = appState.status {
                        Picker("Check Interval", selection: Binding(get: { status.interval }, set: { newValue in Task { try? await APIClient(ipAddress: appState.ipAddress, authToken: appState.authToken).setInterval(minutes: newValue) } })) {
                            Text("1 min").tag(1); Text("5 min").tag(5); Text("10 min").tag(10); Text("15 min").tag(15); Text("30 min").tag(30)
                        }
                    }
                }
                
                Section("Notifications") {
                    Toggle("Disconnect Alerts", isOn: $appState.notifyOnDisconnect)
                    Toggle("Reconnect Alerts", isOn: $appState.notifyOnReconnect)
                    Toggle("Error Alerts", isOn: $appState.notifyOnError)
                    Button("Send Test Notification") { appState.sendTestNotification() }
                }
                .onChange(of: appState.notifyOnDisconnect) { _ in appState.saveSettings() }
                .onChange(of: appState.notifyOnReconnect) { _ in appState.saveSettings() }
                
                Section("Logs") {
                    Picker("Log Level", selection: $appState.logLevel) { Text("INFO").tag("INFO"); Text("WARNING").tag("WARNING"); Text("ERROR").tag("ERROR") }
                    Toggle("Auto-Scroll", isOn: $appState.autoScrollLogs)
                }
                .onChange(of: appState.logLevel) { _ in appState.saveSettings() }
                .onChange(of: appState.autoScrollLogs) { _ in appState.saveSettings() }
                
                Section("Connection Status") {
                    HStack { Image(systemName: appState.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(appState.isConnected ? .green : .red); Text("Status"); Spacer(); Text(appState.isConnected ? "Connected" : "Disconnected") }
                    if let lastTime = appState.lastConnectionTime { HStack { Text("Last Update"); Spacer(); Text(lastTime, style: .relative).foregroundColor(.secondary) } }
                    if let error = appState.connectionError { Text(error).font(.caption).foregroundColor(.red) }
                    Button("Reconnect Now") { appState.connectWebSocket() }
                }
                
                Section { NavigationLink { SetupGuideView() } label: { Label("Setup Guide", systemImage: "book.fill") } }
                
                Section("About") {
                    HStack { Text("Version"); Spacer(); Text("1.0.7").foregroundColor(.secondary) }
                    HStack { Text("Backend"); Spacer(); Text(appState.status != nil ? "Online" : "Offline").foregroundColor(appState.status != nil ? .green : .red) }
                    Button(role: .destructive) { showingResetAlert = true } label: { Label("Reset All Settings", systemImage: "trash") }
                }
            }
            .navigationTitle("Settings")
            .alert("Settings Saved", isPresented: $showingSavedAlert) { Button("OK", role: .cancel) {} }
            .alert("Reset Settings?", isPresented: $showingResetAlert) { Button("Cancel", role: .cancel) {}; Button("Reset", role: .destructive) { appState.resetSettings(); ipInput = ""; tokenInput = "" } }
            .onAppear { ipInput = appState.ipAddress; tokenInput = appState.authToken }
            .scrollDismissesKeyboard(.interactively)
        }.navigationViewStyle(.stack)
    }
}

struct SetupGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) { ZStack { Circle().fill(Color.blue).frame(width: 28, height: 28); Text("1").font(.caption).fontWeight(.bold).foregroundColor(.white) }; Text("Start the Backend").font(.headline) }
                    Text("Open Termux and run:").font(.subheadline).foregroundColor(.secondary)
                    Text("python ~/reconnector/Backend/reconnector_api.py").font(.system(.caption, design: .monospaced)).padding(10).background(Color(UIColor.tertiarySystemBackground)).cornerRadius(8)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) { ZStack { Circle().fill(Color.blue).frame(width: 28, height: 28); Text("2").font(.caption).fontWeight(.bold).foregroundColor(.white) }; Text("Find IP Address").font(.headline) }
                    Text("Run 'ifconfig' in Termux. Look for wlan0 IP (e.g., 192.168.1.70)").font(.subheadline).foregroundColor(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) { ZStack { Circle().fill(Color.blue).frame(width: 28, height: 28); Text("3").font(.caption).fontWeight(.bold).foregroundColor(.white) }; Text("Connect App").font(.headline) }
                    Text("Enter IP and token in Settings. Default token: reconnector123").font(.subheadline).foregroundColor(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Troubleshooting").font(.headline).foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Both devices must be on same WiFi")
                        Text("• Backend must be running in Termux")
                        Text("• Roblox must be installed on tablet")
                    }.font(.subheadline).foregroundColor(.secondary)
                }
            }.padding(20)
        }
        .navigationTitle("Setup Guide").navigationBarTitleDisplayMode(.inline)
    }
}
