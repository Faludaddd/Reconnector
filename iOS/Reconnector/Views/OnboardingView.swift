import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep = 0
    @State private var ipInput = ""
    @State private var tokenInput = "reconnector123"
    @State private var testingConnection = false
    @State private var connectionTestResult: String?
    @State private var connectionSuccess = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.blue)
                
                Text("Reconnector")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Roblox Auto-Reconnect System")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 60)
            .padding(.bottom, 40)
            
            // Steps
            VStack(spacing: 24) {
                OnboardingStep(
                    number: 1,
                    title: "Start the Backend on Android",
                    description: "Open Termux on your tablet and run:",
                    codeBlock: "python ~/reconnector/Backend/reconnector_api.py",
                    isComplete: appState.isConnected
                )
                
                OnboardingStep(
                    number: 2,
                    title: "Enter Connection Details",
                    description: "Enter your tablet's IP address and auth token:",
                    isComplete: connectionSuccess
                )
                
                // Connection form
                VStack(spacing: 12) {
                    TextField("Tablet IP Address (e.g., 192.168.1.70)", text: $ipInput)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.decimalPad)
                        .autocapitalization(.none)
                    
                    TextField("Auth Token", text: $tokenInput)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                    
                    Button(action: testConnection) {
                        HStack {
                            if testingConnection {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(testingConnection ? "Testing..." : "Test Connection")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ipInput.isEmpty || testingConnection)
                    
                    if let result = connectionTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(connectionSuccess ? .green : .red)
                    }
                }
                .padding(.horizontal, 24)
                
                OnboardingStep(
                    number: 3,
                    title: "Start Using Reconnector",
                    description: "Once connected, you'll be able to monitor and control your Roblox farming from your phone.",
                    isComplete: false
                )
            }
            .padding(.horizontal, 24)
            
            Spacer()
            
            // Bottom Button
            VStack(spacing: 8) {
                Button(action: finishSetup) {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!connectionSuccess)
                .padding(.horizontal, 24)
                
                Text("You can change these settings anytime in the Settings tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 40)
        }
        .scrollContentBackground(.hidden)
    }
    
    private func testConnection() {
        testingConnection = true
        connectionTestResult = nil
        
        let client = APIClient(ipAddress: ipInput, authToken: tokenInput)
        
        Task {
            do {
                let status = try await client.getStatus()
                await MainActor.run {
                    self.connectionSuccess = true
                    self.connectionTestResult = "Connected! Roblox is \(status.roblox_running ? "running" : "not running")."
                    self.appState.ipAddress = self.ipInput
                    self.appState.authToken = self.tokenInput
                    self.appState.saveSettings()
                    self.appState.connectWebSocket()
                }
            } catch {
                await MainActor.run {
                    self.connectionSuccess = false
                    self.connectionTestResult = "Failed: \(error.localizedDescription)"
                }
            }
            await MainActor.run {
                self.testingConnection = false
            }
        }
    }
    
    private func finishSetup() {
        appState.completeSetup()
    }
}

struct OnboardingStep: View {
    let number: Int
    let title: String
    let description: String
    var codeBlock: String? = nil
    let isComplete: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(isComplete ? Color.green : Color.blue)
                        .frame(width: 28, height: 28)
                    
                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.caption)
                            .foregroundColor(.white)
                    } else {
                        Text("\(number)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                }
                
                Text(title)
                    .font(.headline)
            }
            
            Text(description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.leading, 40)
            
            if let code = codeBlock {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .padding(10)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(8)
                    .padding(.leading, 40)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
