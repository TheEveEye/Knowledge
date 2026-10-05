import SwiftUI

struct PlanUsageExampleView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.scenePhase) private var scenePhase
    @State private var example = PlanUsageExample()
    let openAccount: () -> Void
    private var planEnabled: Bool { authentication.activeAccount?.credentials?.planEnabled == true }

    var body: some View {
        @Bindable var example = example
        Form {
            Section {
                Text("Send a short prompt to check your ChatGPT connection.")
                if let account = authentication.activeAccount {
                    Text(account.identity.displayName)
                        .foregroundStyle(.secondary)
                }
                if planEnabled {
                    Label("Using your ChatGPT plan", systemImage: "checkmark.circle")
                    Text("Each test request counts toward your ChatGPT usage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Enable permission to use your ChatGPT plan in account settings first.")
                        .foregroundStyle(.secondary)
                    Button("Open account settings", action: openAccount)
                }
                Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
            } header: { Text("Try your plan") }

            if planEnabled {
                Section("Test prompt") {
                    if example.phase == .loadingModels {
                        ProgressView("Loading available models…")
                    } else if !example.models.isEmpty {
                        Picker("Model", selection: $example.selectedModelID) {
                            ForEach(example.models) { model in
                                Text(model.displayName).tag(model.slug)
                            }
                        }
                        .disabled(example.isBusy)
                    }
                    TextField("Prompt", text: $example.prompt, axis: .vertical)
                        .lineLimit(3...8)
                        .disabled(example.phase == .sending)
                        .accessibilityIdentifier("planTestPrompt")
                    if example.phase == .sending {
                        HStack {
                            ProgressView("Waiting for OpenAI…")
                            Spacer()
                            Button("Stop") { example.cancel() }
                        }
                    } else {
                        Button("Send test prompt") {
                            Task { await example.send { try await authentication.authorizedAccessToken() } }
                        }
                        .disabled(!example.canSend)
                        .accessibilityIdentifier("sendPlanTestPrompt")
                    }
                    if example.models.isEmpty && example.phase != .loadingModels {
                        Button("Reload models") {
                            Task { await example.loadModels { try await authentication.authorizedAccessToken() } }
                        }
                    }
                }
            }

            if let failure = example.failure {
                Section("Test could not complete") {
                    Text(failure.localizedDescription)
                    if let diagnostic = failure.diagnostic {
                        Text(diagnostic)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if !example.output.isEmpty || example.phase == .completed || example.phase == .canceled {
                Section {
                    if example.phase == .completed {
                        Label("Completed using your ChatGPT plan", systemImage: "checkmark.circle.fill")
                            .accessibilityIdentifier("planTestCompleted")
                    } else if example.phase == .canceled {
                        Text("Request stopped. Completion was not confirmed.")
                            .foregroundStyle(.secondary)
                    } else if example.phase == .failed {
                        Text("Partial response — completion was not confirmed.")
                            .foregroundStyle(.secondary)
                    }
                    Text(example.output.isEmpty ? "OpenAI completed the request without text output." : example.output)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("planTestResponse")
                    if let receipt = example.receipt {
                        if let input = receipt.inputTokens, let output = receipt.outputTokens {
                            Text("\(input) input tokens · \(output) output tokens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Response") }
            }
        }
        .navigationTitle("Try ChatGPT plan")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: authentication.activeAccount?.clientID) {
            if planEnabled { await example.loadModels { try await authentication.authorizedAccessToken() } }
        }
        .onDisappear { example.cancel() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { example.cancel() }
        }
    }
}
