import SwiftUI

struct KnowledgeAccountView: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var showChatGPT = false
    @State private var confirmSignOut = false

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
                        NavigationLink("Sign in with email") { KnowledgeEmailSignInView() }
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
        password.unicodeScalars.count >= 15 && password.utf16.count <= 128 && password == confirmation
    }
    private var title: String {
        switch account.flow {
        case .signIn: "Welcome back"
        case .signUp: "Create your account"
        case .verifyEmail: "Verify your email"
        case .recovery: "Set or reset your password"
        case .resetPassword: "Choose a new password"
        }
    }
    private var introduction: String? {
        switch account.flow {
        case .signIn, .signUp: nil
        case .verifyEmail(let email): "Enter the six-digit verification code sent to \(email)."
        case .recovery: "We’ll email you a recovery code. Use this if you forgot your password or previously signed in with email codes."
        case .resetPassword(let email): "If an account exists for \(email), we’ve sent a recovery code. Enter it below with your new password."
        }
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "books.vertical.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(title).font(.title2.bold())
                    if let introduction {
                        Text(introduction).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(Color.clear)

            switch account.flow {
            case .signIn, .signUp:
                Section {
                    Picker("Account access", selection: Binding(
                        get: { isSignUp },
                        set: { account.selectFlow($0 ? .signUp : .signIn) }
                    )) {
                        Text("Sign in").tag(false)
                        Text("Sign up").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(account.isBusy)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Section {
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
                    if isSignUp { confirmationField }
                } footer: {
                    if !isSignUp {
                        Button("Reset password") { account.selectFlow(.recovery) }
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .buttonStyle(.plain)
                            .disabled(account.isBusy)
                    }
                }
                .disabled(account.isBusy)

                Section {
                    attemptButton(isSignUp ? "Sign up" : "Sign in", disabled: !validEmail ||
                                  (isSignUp ? (!validNewPassword || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) : password.isEmpty), fullWidth: true) {
                        if isSignUp { await account.signUp(email: email, name: name, password: password) }
                        else { await account.signIn(email: email, password: password) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

            case .recovery:
                Section { emailField }
                    .disabled(account.isBusy)
                primaryActionSection {
                    resendButton("Send recovery code", email: email, reset: true, disabled: !validEmail)
                }

            case .verifyEmail(let requested):
                Section { codeField }
                    .disabled(account.isBusy)
                primaryActionSection {
                    attemptButton("Verify email", disabled: code.count != 6, fullWidth: true) {
                        await account.verifyEmail(email: requested, code: code)
                    }
                }
                primaryActionSection {
                    resendButton("Resend verification code", email: requested, reset: false)
                }

            case .resetPassword(let requested):
                Section {
                    codeField
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    confirmationField
                }
                .disabled(account.isBusy)
                primaryActionSection {
                    attemptButton("Reset password", disabled: code.count != 6 || !validNewPassword, fullWidth: true) {
                        await account.resetPassword(email: requested, code: code, password: password)
                    }
                }
                primaryActionSection {
                    resendButton("Resend recovery code", email: requested, reset: true)
                }
            }
            if account.isBusy { ProgressView("Connecting…") }
            if let message = account.message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Knowledge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if account.flow != .signIn && account.flow != .signUp {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign in", systemImage: "chevron.left") { account.selectFlow(.signIn) }
                        .disabled(account.isBusy)
                        .accessibilityLabel("Back to sign in")
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
    private func primaryActionSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
    private func attemptButton(_ title: String, disabled: Bool, fullWidth: Bool = false, action: @escaping () async -> Void) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let delay = max(0, Int(ceil(account.nextAttempt.timeIntervalSince(context.date))))
            Button { Task { await action() } } label: {
                Text(delay > 0 ? "Try again in \(delay)s" : title)
                    .frame(maxWidth: fullWidth ? .infinity : nil)
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
