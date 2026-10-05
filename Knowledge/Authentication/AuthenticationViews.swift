import SwiftUI
import UIKit

struct AuthenticationRootView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch authentication.state {
            case .restoring:
                ProgressView("Restoring your connection…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedIn:
                ContentView()
            case .signedOut, .signingIn, .recovery:
                ChatGPTSignInView()
            }
        }
        .background {
            AuthenticationWindowReader { window in
                authentication.setPresentationAnchor(window)
            }
            .frame(width: 0, height: 0)
        }
        .safeAreaInset(edge: .bottom) {
            if case .signedIn = authentication.state, let message = authentication.message {
                HStack(alignment: .top, spacing: 16) {
                    Text(message)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("signedInAuthenticationMessage")
                    Button("Dismiss") { authentication.dismissMessage() }
                        .frame(minHeight: 44)
                }
                .padding(16)
                .background(.regularMaterial)
            }
        }
        .task {
            await authentication.restore()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                authentication.sceneDidEnterBackground()
            }
        }
    }
}

private struct ChatGPTSignInView: View {
    @Environment(AuthenticationStore.self) private var authentication

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Welcome to Knowledge")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Connect your ChatGPT account to get started.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    if !authentication.accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your accounts")
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(authentication.accounts) { account in
                                Button {
                                    Task { await authentication.selectAccount(account.id) }
                                } label: {
                                    AccountRow(account: account)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(16)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                                }
                                .buttonStyle(.plain)
                                .disabled(authentication.isBusy)
                                .accessibilityHint("Continues with this saved ChatGPT account")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        ChatGPTSignInButton {
                            Task { await authentication.signIn() }
                        }
                        .disabled(authentication.isBusy)
                        .accessibilityIdentifier("continueWithChatGPT")

                        if !authentication.accounts.isEmpty || authentication.message != nil {
                        Button("Use another ChatGPT account") {
                            Task { await authentication.signIn(startNewRegistration: true) }
                        }
                        .frame(minHeight: 44)
                        .disabled(authentication.isBusy)
                        .accessibilityHint("Starts a new connection so you can choose a different ChatGPT account")
                        }

                        Text("ChatGPT will ask whether you want to let Knowledge use your plan. You can sign in without granting that permission.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if authentication.isBusy {
                            ProgressView("Connecting to ChatGPT…")
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        AuthenticationMessage()

                        if authentication.state == .recovery {
                            Button("Try again") {
                                Task { await authentication.retryRestoration() }
                            }
                            .buttonStyle(.bordered)
                            .disabled(authentication.isBusy)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ChatGPTAccountView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let account = authentication.activeAccount {
                    Section("Connected account") {
                        AccountRow(account: account)
                    }

                    Section {
                        if account.credentials?.planEnabled == true {
                            Label("Your ChatGPT plan is connected", systemImage: "checkmark.circle")
                        } else {
                            Text("Sign-in is connected. Permission to use your ChatGPT plan is optional.")
                                .foregroundStyle(.secondary)
                            ChatGPTSignInButton {
                                Task { await authentication.signIn(accountID: account.id, requestConsent: true) }
                            }
                            .disabled(authentication.isBusy)
                        }
                        Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage)
                    } header: {
                        Text("ChatGPT plan")
                    } footer: {
                        Text("Usage in connected apps counts toward your ChatGPT plan limits.")
                    }
                }

                Section("Accounts") {
                    ForEach(authentication.accounts) { account in
                        Button {
                            Task { await authentication.selectAccount(account.id) }
                        } label: {
                            HStack {
                                AccountRow(account: account)
                                Spacer()
                                if account.id == authentication.activeAccount?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.primary)
                                        .accessibilityLabel("Selected account")
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(authentication.isBusy)
                    }
                    Button("Add another ChatGPT account") {
                        Task { await authentication.signIn(startNewRegistration: true) }
                    }
                    .disabled(authentication.isBusy)
                }

                if authentication.isBusy || authentication.message != nil {
                    Section {
                        if authentication.isBusy {
                            ProgressView("Connecting to ChatGPT…")
                        }
                        AuthenticationMessage()
                    }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task {
                            await authentication.signOut()
                            dismiss()
                        }
                    }
                    .disabled(authentication.isBusy)
                } footer: {
                    Text("Signing out ends this account’s session in Knowledge. Your saved items stay on this device.")
                }
            }
            .navigationTitle("ChatGPT account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct ChatGPTPlanWelcomeView: View {
    @Environment(AuthenticationStore.self) private var authentication
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Your ChatGPT plan is connected")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Eligible AI requests in Knowledge will use your ChatGPT plan and count toward its limits. You can review your usage and manage connected apps in ChatGPT.")
                        .foregroundStyle(.secondary)
                    Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage)
                    Button("Got it") {
                        authentication.dismissPlanWelcome()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                }
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        authentication.dismissPlanWelcome()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { authentication.dismissPlanWelcome() }
    }
}

private struct AccountRow: View {
    let account: StoredChatGPTAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(account.identity.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            if let email = account.identity.email, email != account.identity.displayName {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !account.label.isEmpty {
                Text(account.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ChatGPTSignInButton: View {
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .headline) private var logoSize: CGFloat = 24
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("ChatGPTLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .accessibilityHidden(true)
                Text("Continue with ChatGPT")
            }
            .font(.headline)
            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(colorScheme == .dark ? Color.white : Color.black)
    }
}

private struct AuthenticationMessage: View {
    @Environment(AuthenticationStore.self) private var authentication

    var body: some View {
        if let message = authentication.message {
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("authenticationMessage")
        }
    }
}

private enum ChatGPTAccountLinks {
    static let usage = URL(string: "https://chatgpt.com/settings/usage")!
}

private struct AuthenticationWindowReader: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void

    func makeUIView(context: Context) -> WindowReadingView {
        let view = WindowReadingView()
        view.onWindow = onWindow
        return view
    }

    func updateUIView(_ view: WindowReadingView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class WindowReadingView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
