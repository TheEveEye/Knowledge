import SwiftUI

struct ChatOverlay: View {
    @Bindable var session: ChatSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isExpanded: Bool
    var showsCollapsedButton = true
    var searchText: Binding<String>? = nil
    @State private var message = ""
    @FocusState private var isFocused: Bool
    @Namespace private var glassNamespace

    private var hasMessage: Bool { !message.trimmed.isEmpty }

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .bottom) {
                if isExpanded {
                    Button {
                        handleBackgroundTap()
                    } label: {
                        Color.black.opacity(reduceTransparency ? 1 : (colorScheme == .dark ? 0.24 : 0.16))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Keep the scrim full-screen as the keyboard appears or dismisses.
                    // Only this layer ignores the keyboard; the composer still avoids it.
                    .ignoresSafeArea(.all)
                    .accessibilityLabel(isFocused ? "Dismiss keyboard" : "Close chat")
                    .transition(.opacity)
                }

                VStack(spacing: 12) {
                    if isExpanded, !session.messages.isEmpty {
                        ChatConversation(
                            session: session,
                            onBackgroundTap: handleBackgroundTap,
                            onMessageTap: { isFocused = false }
                        )
                            .frame(maxHeight: .infinity)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    } else if isExpanded, let introduction = session.presentation.introduction {
                        ChatWelcomeView(introduction: introduction)
                            .frame(maxHeight: .infinity)
                            .opacity(isFocused || hasMessage ? 0 : 1)
                            .accessibilityHidden(isFocused || hasMessage)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused || hasMessage)
                            .onTapGesture(perform: handleBackgroundTap)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if isExpanded || showsCollapsedButton {
                        composer.padding(.horizontal)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .accessibilityAction(.escape) { closeChat() }
        .onChange(of: isExpanded) {
            if !isExpanded { isFocused = false }
        }
        .onAppear { session.resumeQueued() }
        .onDisappear { isFocused = false }
    }

    private var composer: some View {
        // Share morph geometry without joining the separate resting controls.
        GlassEffectContainer(spacing: 0) {
            HStack(alignment: .center) {
                if isExpanded || searchText != nil {
                    HStack(spacing: 10) {
                        if !isExpanded {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                                .transition(.opacity)
                        }
                        // Keep one field alive while its purpose changes, with
                        // separate storage for the search query and chat draft.
                        TextField(isExpanded ? session.presentation.placeholder : "Find a concept or alias",
                                  text: isExpanded ? $message : (searchText ?? $message), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .lineLimit(isExpanded ? 1...5 : 1...1)
                            .focused($isFocused)
                            .padding(.vertical, 10)
                            .accessibilityLabel(isExpanded ? session.presentation.inputLabel : "Find a concept or alias")
                        if !isExpanded, let searchText, !searchText.wrappedValue.isEmpty {
                            Button("Clear search", systemImage: "xmark.circle.fill") {
                                searchText.wrappedValue = ""
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22))
                    .glassEffectID("composer", in: glassNamespace)
                    .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                } else {
                    Spacer(minLength: 0)
                }

                // Preserve the button's identity so its symbol can transition as the glass splits.
                actionButton
                    .glassEffectID(isExpanded || searchText != nil ? "action" : "composer", in: glassNamespace)
                    .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            }
            // Animate keyboard movement at the row boundary, keeping the glass
            // field and button in the same coordinate space throughout dismissal.
            .geometryGroup()
        }
    }

    private var actionButton: some View {
        Button(action: performAction) {
            Label(actionLabel, systemImage: actionSymbol)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.offUp))
                .frame(width: actionSize, height: actionSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Size the actual glass surface, rather than framing a system-styled
        // button whose intrinsic padding can vary with its symbol.
        .glassEffect(
            .regular.tint(isExpanded && hasMessage && !session.isResponding ? Color.accentColor : nil).interactive(),
            in: Circle()
        )
        .accessibilityHint(actionHint)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: hasMessage)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.isResponding)
    }

    private let actionSize: CGFloat = 56

    private var actionSymbol: String {
        guard isExpanded else { return "bubble.left" }
        if session.isResponding { return "stop.fill" }
        return hasMessage ? "arrow.up" : "xmark"
    }

    private var actionLabel: String {
        guard isExpanded else { return session.presentation.title }
        if session.isResponding { return "Stop response" }
        return hasMessage ? "Send message" : "Close chat"
    }

    private var actionHint: String {
        guard isExpanded else { return "Expands the instruction field. Tap the field to type." }
        if session.isResponding { return "Stops the current reply and keeps any text you are drafting" }
        return hasMessage ? session.presentation.sendHint : "Collapses the instruction field"
    }

    private func performAction() {
        if !isExpanded {
            // Dismiss search focus before the same field becomes the chat input.
            // Opening chat leaves the keyboard hidden until the field is tapped.
            isFocused = false
            setExpanded(true)
        } else if session.isResponding {
            session.stop()
        } else if !hasMessage {
            closeChat()
        } else {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.04)) {
                if session.send(message) {
                    isFocused = false
                    message = ""
                }
            }
        }
    }

    private func closeChat() {
        isFocused = false
        setExpanded(false)
    }

    private func handleBackgroundTap() {
        if isFocused {
            isFocused = false
        } else {
            closeChat()
        }
    }

    private func setExpanded(_ expanded: Bool) {
        // A light opening spring and quicker, bounce-free close remain interruptible.
        let animation: Animation? = reduceMotion ? nil : .spring(
            duration: expanded ? 0.44 : 0.3,
            bounce: expanded ? 0.08 : 0
        )
        withAnimation(animation) { isExpanded = expanded }
    }
}

private struct ChatWelcomeView: View {
    let introduction: ChatPresentation.Introduction

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text(introduction.title)
                    .font(.title2.weight(.semibold))
                Text(introduction.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct ChatConversation: View {
    let session: ChatSession
    let onBackgroundTap: () -> Void
    let onMessageTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                GlassEffectContainer(spacing: 0) {
                    messagesContent
                }
                .padding(.horizontal)
                .padding(.vertical)
            }
            .defaultScrollAnchor(.bottom)
            .scrollBounceBehavior(.basedOnSize)
            .contentShape(Rectangle())
            .onTapGesture(perform: onBackgroundTap)
            .onChange(of: session.messages.count) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                    proxy.scrollTo("reply", anchor: .bottom)
                }
            }
            .onChange(of: session.messages.last?.text) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
                    proxy.scrollTo("reply", anchor: .bottom)
                }
            }
        }
    }

    private var messagesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(session.messages.filter { !$0.text.isEmpty }) { message in
                HStack(alignment: .bottom) {
                    if message.role == .user { Spacer(minLength: 44) }
                    messageBubble(message)
                    if let id = message.undoID {
                        Button("Undo", systemImage: "arrow.uturn.backward") { session.undo(id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .buttonSizing(.flexible)
                            .frame(width: 44, height: 44)
                            .disabled(!session.canUndo(id))
                    }
                    if message.role != .user { Spacer(minLength: message.undoID == nil ? 44 : 0) }
                }
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .offset(y: 8).combined(with: .opacity),
                    removal: .opacity
                ))
            }
            if session.isResponding {
                HStack {
                    ChatTypingIndicator(label: session.activity)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .glassEffect(.regular, in: Capsule())
                    Text(session.activity).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .transition(reduceMotion ? .identity : .opacity)
            }
            Color.clear.frame(height: 1).id("reply").accessibilityHidden(true)
        }
        // A streamed reply starts empty, so message count alone misses its insertion.
        .animation(reduceMotion ? nil : .smooth(duration: 0.24),
                   value: session.messages.filter { !$0.text.isEmpty }.map(\.id))
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: session.isResponding)
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            messageContent(message)
                .font(.body)
                .contentTransition(reduceMotion ? .identity : .interpolate)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: message.text)
                .textSelection(.enabled)
            if let id = message.retryID {
                Button("Try again", systemImage: "arrow.clockwise") { session.retry(id) }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
            if message.usageLimitReached {
                Link("Manage ChatGPT usage", destination: ChatGPTAccountLinks.usage)
                    .frame(minHeight: 44)
            }
            if session.isQueued(message.id) {
                Button("Cancel request", systemImage: "xmark") { session.cancelQueued(message.id) }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        // Consume message taps so only the surrounding space closes the chat.
        // Buttons, links, and text selection keep their own interactions.
        .onTapGesture(perform: onMessageTap)
    }

    @ViewBuilder private func messageContent(_ message: ChatMessage) -> some View {
        if message.role == .assistant {
            ChatMathText(source: message.text)
        } else {
            Text(message.text)
                .accessibilityLabel(message.role == .user ? "You: \(message.text)" : message.text)
        }
    }
}

private struct ChatTypingIndicator: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                dots(activeIndex: nil)
            } else {
                PhaseAnimator([0, 1, 2, 3]) { phase in
                    dots(activeIndex: phase)
                } animation: { phase in
                    .easeInOut(duration: phase == 3 ? 0.45 : 0.25)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private func dots(activeIndex: Int?) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(activeIndex == nil || activeIndex == index ? 1 : 0.3)
            }
        }
    }
}
