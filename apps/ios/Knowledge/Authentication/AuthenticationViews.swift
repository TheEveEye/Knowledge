import SwiftUI

struct KnowledgeWelcomeView: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @State private var showingAccountSheet = false
    @ScaledMetric(relativeTo: .largeTitle) private var markSize: CGFloat = 88

    var body: some View {
        ViewThatFits(in: .vertical) {
            welcomeContent
            ScrollView { welcomeContent }
        }
        .background(.background)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button {
                    account.selectFlow(.signIn)
                    showingAccountSheet = true
                } label: {
                    Text("Log in").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    account.selectFlow(.signUp)
                    showingAccountSheet = true
                } label: {
                    Text("Sign up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .disabled(account.isBusy || account.user != nil)
            .controlSize(.large)
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .background(.background)
        }
        .sheet(isPresented: $showingAccountSheet) {
            KnowledgeAuthenticationSheet()
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 48)
            Image("KnowledgeMark")
                .resizable()
                .scaledToFit()
                .frame(width: markSize, height: markSize)
                .accessibilityHidden(true)
            Text("Knowledge")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if let message = account.message {
                VStack(spacing: 12) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Dismiss message") { account.dismissMessage() }
                }
                .frame(maxWidth: 440)
            }
            Spacer(minLength: 48)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct KnowledgeAuthenticationSheet: View {
    @Environment(KnowledgeAccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss

    private var isSubmitting: Bool { account.isBusy || account.user != nil }

    var body: some View {
        NavigationStack {
            KnowledgeEmailSignInView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .disabled(isSubmitting)
                    }
                }
        }
        .presentationDetents([.large])
        .presentationSizing(.form)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSubmitting)
    }
}

struct ChatGPTConnectionRow: View {
    let name: String
    let email: String?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
            if let email, email != name {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !label.isEmpty, label != name {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum ChatGPTAccountLinks {
    static let usage = URL(string: "https://chatgpt.com/settings/usage")!
}
