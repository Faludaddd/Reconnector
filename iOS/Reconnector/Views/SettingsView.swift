import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var ipInput = ""
    @State private var tokenInput = ""
    @State private var showingSavedAlert = false
    @State private var showingResetAlert = false
    @State private var notificationStatus: String = ""

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Connection
                Section {
                    TextField("IP Address", text: $ipInput)
                        .keyboardType(.decimalPad)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                    SecureField("API Key (from Termux)", text: $tokenInput)
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                    Toggle("Auto-Connect on Launch", isOn: $appState.autoConnect)
                    Button("Save & Reconnect") {
                        appState.ipAddress = ipInput
                        appState.authToken = tokenInput
                        appState.saveConnectionSettings()
                        showingSavedAlert = true
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("API Key is printed in the Termux terminal when the backend starts. Copy it exactly — every request is authenticated.")
                        .font(.caption)
                }

                // MARK: - Notifications
                Section {
                    Toggle("Disconnect Alerts", isOn: $appState.notifyOnDisconnect)
                    Toggle("Reconnect Alerts", isOn: $appState.notifyOnReconnect)
                    Toggle("Error Alerts", isOn: $appState.notifyOnError)
                    Button("Send Test Notification") {
                        appState.sendTestNotification()
                    }
                    if !notificationStatus.isEmpty {
                        Text(notificationStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Notifications")
                        Spacer()
                        Button {
                            refreshNotificationStatus()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                // MARK: - Logs
                Section("Logs") {
                    Toggle("Auto-Scroll", isOn: $appState.autoScrollLogs)
                }

                // MARK: - Connection Status
                Section("Connection Status") {
                    HStack {
                        Image(systemName: appState.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(appState.isConnected ? .green : .red)
                        Text("Status")
                        Spacer()
                        Text(appState.isConnected ? "Connected" : "Disconnected")
                    }
                    if let lastTime = appState.lastConnectionTime {
                        HStack {
                            Text("Last Update")
                            Spacer()
                            Text(lastTime, style: .relative).foregroundColor(.secondary)
                        }
                    }
                    if let error = appState.connectionError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Button("Reconnect Now") { appState.reconnect() }
                }

                // MARK: - Setup guide
                Section {
                    NavigationLink {
                        SetupGuideView()
                    } label: {
                        Label("Setup Guide", systemImage: "book.fill")
                    }
                }

                // MARK: - About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.4.0").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Backend")
                        Spacer()
                        Text(appState.status != nil ? "Online" : "Offline")
                            .foregroundColor(appState.status != nil ? .green : .red)
                    }
                    Button(role: .destructive) {
                        showingResetAlert = true
                    } label: {
                        Label("Reset All Settings", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("Settings Saved", isPresented: $showingSavedAlert) {
                Button("OK", role: .cancel) {}
            }
            .alert("Reset Settings?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    appState.resetSettings()
                    ipInput = ""
                    tokenInput = ""
                }
            }
            .onAppear {
                ipInput = appState.ipAddress
                tokenInput = appState.authToken
                refreshNotificationStatus()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationViewStyle(.stack)
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized:
                    notificationStatus = "Permission granted. Alerts: \(settings.alertSetting == .enabled ? "on" : "off")"
                case .denied:
                    notificationStatus = "Blocked. Please enable in iOS Settings."
                case .notDetermined:
                    notificationStatus = "Not requested yet. Tap Test Notification."
                case .provisional:
                    notificationStatus = "Provisional permission only."
                case .ephemeral:
                    notificationStatus = "Ephemeral permission."
                @unknown default:
                    notificationStatus = ""
                }
            }
        }
    }
}

struct SetupGuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 28, height: 28)
                            Text("1").font(.caption).fontWeight(.bold).foregroundColor(.white)
                        }
                        Text("Start the Backend").font(.headline)
                    }
                    Text("Open Termux and run:").font(AppTheme.bodyFont).foregroundColor(.secondary)
                    Text("python ~/reconnector/Backend/reconnector_api.py")
                        .font(.system(.caption, design: .monospaced))
                        .padding(10)
                        .background(AppTheme.subtleBackground)
                        .cornerRadius(8)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 28, height: 28)
                            Text("2").font(.caption).fontWeight(.bold).foregroundColor(.white)
                        }
                        Text("Find IP Address").font(.headline)
                    }
                    Text("Run 'ifconfig' in Termux. Look for wlan0 IP (e.g., 192.168.1.70)")
                        .font(AppTheme.bodyFont)
                        .foregroundColor(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 28, height: 28)
                            Text("3").font(.caption).fontWeight(.bold).foregroundColor(.white)
                        }
                        Text("Connect App").font(.headline)
                    }
                    Text("Enter IP and token in Settings. Default token: reconnector123")
                        .font(AppTheme.bodyFont)
                        .foregroundColor(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Troubleshooting").font(.headline).foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Both devices must be on same WiFi")
                        Text("• Backend must be running in Termux")
                        Text("• Roblox must be installed on tablet")
                    }
                    .font(AppTheme.bodyFont)
                    .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Setup Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}
