import SwiftUI

struct KnowledgeAccountView: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var showChatGPT = false
    @State private var confirmSignOut = false
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            List {
                Section("Knowledge account") {
                    if account.isRestoring { ProgressView("Restoring your session…") }
                    else if let user = account.user {
                        LabeledContent("Name", value: user.displayName)
                        LabeledContent("Email", value: user.email)
                        Button("Refresh session") { Task { await account.refresh() } }
                        Button("Sign out of Knowledge", role: .destructive) { confirmSignOut = true }
                    } else {
                        Button("Log in or sign up") { showSignIn = true }
                    }
                }
                .disabled(account.isBusy)
                if let message = account.message {
                    Section {
                        Text(message).foregroundStyle(.secondary)
                        Button("Dismiss message") { account.dismissMessage() }
                    }
                }
                Section {
                    Button("ChatGPT") { showChatGPT = true }
                } header: {
                    Text("AI connections")
                } footer: {
                    Text("Connect a ChatGPT plan to use the current AI features. Your Knowledge account is separate.")
                }
                Section("Library on this device") {
                    Text("Your saved items stay on this device. Account sync is not enabled yet, and signing in does not upload or transfer your library.")
                        .foregroundStyle(.secondary)
                }
                if account.isBusy { ProgressView("Updating your account…") }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showChatGPT) { ChatGPTAccountView() }
            .sheet(isPresented: $showSignIn) { KnowledgeAuthenticationSheet() }
            .confirmationDialog("Sign out of Knowledge?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                Button("Cancel", role: .cancel) { }
            } message: { Text("You’ll need to sign in again to use Knowledge. Your local library and AI connection stay on this device.") }
        }
    }
}

struct KnowledgeEmailSignInView: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @State private var email = ""
    @State private var name = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var isSignUp: Bool { account.flow == .signUp }
    private var validEmail: Bool { email.contains("@") && email.utf8.count <= 254 }
    private var validNewPassword: Bool {
        password.unicodeScalars.count >= 10 && password.utf16.count <= 128 && password == confirmation
    }
    private var title: String {
        switch account.flow {
        case .signIn: "Log in"
        case .signUp: "Create your account"
        case .verifyEmail: "Verify your email"
        case .recovery: "Reset your password"
        case .resetPassword: "Choose a new password"
        }
    }
    private var introduction: String? {
        switch account.flow {
        case .signIn, .signUp: nil
        case .verifyEmail(let email): "Enter the six-digit verification code sent to \(email)."
        case .recovery: "Enter your email address to receive a recovery code."
        case .resetPassword(let email): "If an account exists for \(email), we’ve sent a recovery code. Enter it below with your new password."
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Image("KnowledgeMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let introduction {
                        Text(introduction).foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)

            switch account.flow {
            case .signIn, .signUp:
                Section {
                    credentialFields
                } footer: {
                    if isSignUp {
                        passwordGuidance
                    } else {
                        Button("Forgot password?") { account.selectFlow(.recovery) }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(account.isBusy)
                    }
                }
                .disabled(account.isBusy)

            case .recovery:
                Section { emailField }.disabled(account.isBusy)

            case .verifyEmail(let requested):
                Section { codeField } footer: {
                    resendButton("Resend verification code", email: requested, reset: false)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(account.isBusy)

            case .resetPassword(let requested):
                Section {
                    codeField
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    confirmationField
                } footer: {
                    passwordGuidance
                    resendButton("Resend recovery code", email: requested, reset: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(account.isBusy)
            }

            if let message = account.message {
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("knowledgeAccountMessage")
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if account.isBusy { ProgressView("Connecting…") }
                primaryAction
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(account.isBusy)
            }
            .padding()
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if account.flow != .signIn && account.flow != .signUp {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Log in", systemImage: "chevron.left") { account.selectFlow(.signIn) }
                        .disabled(account.isBusy)
                        .accessibilityLabel("Back to log in")
                }
            }
        }
        .onChange(of: account.flow) { _, flow in
            password = ""; confirmation = ""; code = ""
            if case .verifyEmail(let requested) = flow { email = requested; codeFocused = true }
            else if case .resetPassword(let requested) = flow { email = requested; codeFocused = true }
            else { codeFocused = false }
        }
        .onDisappear {
            password = ""; confirmation = ""; code = ""
            account.discardPendingPassword()
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch account.flow {
        case .signIn, .signUp:
            attemptButton("Continue", disabled: !validEmail ||
                          (isSignUp ? (!validNewPassword || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) : password.isEmpty)) {
                if isSignUp { await account.signUp(email: email, name: name, password: password) }
                else { await account.signIn(email: email, password: password) }
            }
        case .recovery:
            resendButton("Continue", email: email, reset: true, disabled: !validEmail)
        case .verifyEmail(let requested):
            attemptButton("Continue", disabled: code.count != 6) {
                await account.verifyEmail(email: requested, code: code)
            }
        case .resetPassword(let requested):
            attemptButton("Reset password", disabled: code.count != 6 || !validNewPassword) {
                await account.resetPassword(email: requested, code: code, password: password)
            }
        }
    }

    @ViewBuilder private var credentialFields: some View {
        if isSignUp {
            TextField("Name", text: $name)
                .textContentType(.name)
                .onChange(of: name) { _, value in name = String(value.prefix(80)) }
        }
        emailField
        SecureField("Password", text: $password)
            .textContentType(isSignUp ? .newPassword : .password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        if isSignUp {
            confirmationField
        }
    }

    @ViewBuilder private var passwordGuidance: some View {
        if !password.isEmpty && (password.unicodeScalars.count < 10 || password.utf16.count > 128) {
            Text("Use 10–128 characters for your password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !confirmation.isEmpty && password != confirmation {
            Text("Passwords don’t match.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emailField: some View {
        TextField("Email address", text: $email)
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
    private var confirmationField: some View {
        SecureField("Confirm password", text: $confirmation)
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
    private var codeField: some View {
        TextField("Verification code", text: $code)
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
            .focused($codeFocused)
            .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
    }
    private func attemptButton(_ title: String, disabled: Bool, action: @escaping () async -> Void) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let delay = max(0, Int(ceil(account.nextAttempt.timeIntervalSince(context.date))))
            Button { Task { await action() } } label: {
                Text(delay > 0 ? "Try again in \(delay)s" : title)
                    .frame(maxWidth: .infinity)
            }
            .disabled(disabled || account.isBusy || delay > 0)
        }
    }
    private func resendButton(_ title: String, email: String, reset: Bool, disabled: Bool = false) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let delay = max(0, Int(ceil(account.nextCodeRequest.timeIntervalSince(context.date))))
            Button {
                Task { code = ""; await account.requestCode(email: email, reset: reset) }
            } label: {
                Text(delay > 0 ? "Send code in \(delay)s" : title)
                    .frame(maxWidth: .infinity)
            }
            .disabled(disabled || account.isBusy || delay > 0)
        }
    }
}
