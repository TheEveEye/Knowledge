import Observation
import SwiftUI

struct KnowledgeAccountView: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var showChatGPT = false
    @State private var confirmSignOut = false
    @State private var signingOutUser: KnowledgeUser?

    // Preserve account details while the signed-in screen and its sheet disappear.
    private var displayedUser: KnowledgeUser? { account.user ?? signingOutUser }
    private var isUpdating: Bool { account.isBusy || signingOutUser != nil }

    var body: some View {
        NavigationStack {
            List {
                Section("Knowledge account") {
                    if let user = displayedUser {
                        LabeledContent("Name", value: user.displayName)
                        LabeledContent("Email", value: user.email)
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
                if account.isBusy, signingOutUser == nil {
                    ProgressView("Updating your account…")
                }
                if displayedUser != nil {
                    Section {
                        if signingOutUser != nil {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Signing out…")
                            }
                        } else {
                            Button("Sign out of Knowledge", role: .destructive) { confirmSignOut = true }
                        }
                    }
                    .disabled(account.isBusy)
                }
            }
            .disabled(isUpdating)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(isUpdating)
                }
            }
            .sheet(isPresented: $showChatGPT) { ChatGPTAccountView() }
            .alert("Sign out of Knowledge as \(displayedUser?.email ?? "")?", isPresented: $confirmSignOut) {
                Button("Cancel", role: .cancel) { }
                Button("Sign out", role: .destructive) {
                    guard !isUpdating, let user = account.user else { return }
                    signingOutUser = user
                    Task {
                        await account.signOut()
                        if account.user != nil { signingOutUser = nil }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isUpdating)
        .onChange(of: account.user?.id) { _, current in
            if current == nil, signingOutUser != nil { dismiss() }
        }
    }
}

struct KnowledgeEmailSignInView: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @State private var draft = KnowledgeCredentialDraft()
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    // Keep the form busy while a successful sign-in transitions to the main screen.
    private var isSubmitting: Bool { account.isBusy || account.user != nil }
    private var isSignUp: Bool { account.flow == .signUp }
    private var validEmail: Bool { draft.email.contains("@") && draft.email.utf8.count <= 254 }
    private var validNewPassword: Bool {
        draft.password.unicodeScalars.count >= 10 && draft.password.utf16.count <= 128 && draft.password == draft.confirmation
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
                            .disabled(isSubmitting)
                    }
                }
                .disabled(isSubmitting)

            case .recovery:
                Section { emailField }.disabled(isSubmitting)

            case .verifyEmail(let requested):
                Section { codeField } footer: {
                    resendButton("Resend verification code", email: requested, reset: false)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(isSubmitting)

            case .resetPassword(let requested):
                Section {
                    codeField
                    newPasswordField
                    confirmationField
                } footer: {
                    passwordGuidance
                    resendButton("Resend recovery code", email: requested, reset: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(isSubmitting)
            }

            if let message = account.message {
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("knowledgeAccountMessage")
                    if account.lastError == .emailAlreadyRegistered {
                        Button("Log in") { account.selectFlow(.signIn) }
                        Button("Forgot password?") { account.selectFlow(.recovery) }
                    }
                }
                .disabled(isSubmitting)
                .listRowBackground(Color.clear)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                if isSubmitting { ProgressView("Connecting…") }
                primaryAction
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isSubmitting)
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
                        .disabled(isSubmitting)
                        .accessibilityLabel("Back to log in")
                }
            }
        }
        .onChange(of: account.flow) { _, flow in
            // Old fields keep their original draft until SwiftUI removes them.
            // Replacing the draft avoids emptying credentials still in the view hierarchy.
            let next = KnowledgeCredentialDraft(email: draft.email, name: draft.name)
            draft = next
            code = ""
            if case .verifyEmail(let requested) = flow { next.email = requested; codeFocused = true }
            else if case .resetPassword(let requested) = flow { next.email = requested; codeFocused = true }
            else { codeFocused = false }
        }
        .onDisappear {
            account.discardPendingPassword()
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch account.flow {
        case .signIn, .signUp:
            attemptButton("Continue", disabled: !validEmail ||
                          (isSignUp ? (!validNewPassword || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) : draft.password.isEmpty)) {
                if isSignUp {
                    await account.signUp(email: draft.email, name: draft.name, password: draft.password)
                } else { await account.signIn(email: draft.email, password: draft.password) }
            }
        case .recovery:
            resendButton("Continue", email: draft.email, reset: true, disabled: !validEmail)
        case .verifyEmail(let requested):
            attemptButton("Continue", disabled: code.count != 6) {
                await account.verifyEmail(email: requested, code: code)
            }
        case .resetPassword(let requested):
            attemptButton("Reset password", disabled: code.count != 6 || !validNewPassword) {
                await account.resetPassword(email: requested, code: code, password: draft.password)
            }
        }
    }

    @ViewBuilder private var credentialFields: some View {
        @Bindable var draft = draft
        if isSignUp {
            TextField("Name", text: $draft.name)
                .textContentType(.name)
                .onChange(of: draft.name) { _, value in draft.name = String(value.prefix(80)) }
        }
        emailField
        if isSignUp {
            newPasswordField
            confirmationField
        } else {
            SecureField("Password", text: $draft.password)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder private var passwordGuidance: some View {
        if !draft.password.isEmpty && (draft.password.unicodeScalars.count < 10 || draft.password.utf16.count > 128) {
            Text("Use 10–128 characters for your password.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if !draft.confirmation.isEmpty && draft.password != draft.confirmation {
            Text("Passwords don’t match.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emailField: some View {
        @Bindable var draft = draft
        return TextField("Email address", text: $draft.email)
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
    private var newPasswordField: some View {
        @Bindable var draft = draft
        return SecureField(isSignUp ? "Password" : "New password", text: $draft.password)
            .textContentType(.newPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
    private var confirmationField: some View {
        @Bindable var draft = draft
        return SecureField("Confirm password", text: $draft.confirmation)
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
            .disabled(disabled || isSubmitting || delay > 0)
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
            .disabled(disabled || isSubmitting || delay > 0)
        }
    }
}

@MainActor @Observable private final class KnowledgeCredentialDraft {
    var email: String
    var name: String
    var password = ""
    var confirmation = ""

    init(email: String = "", name: String = "") {
        self.email = email
        self.name = name
    }
}
