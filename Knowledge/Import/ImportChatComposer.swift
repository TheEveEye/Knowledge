import SwiftUI

struct ImportChatComposer: View {
    let jobID: UUID
    @Binding var isExpanded: Bool
    @Environment(ImportCoordinator.self) private var imports

    var body: some View {
        ImportChatContent(session: imports.chat(for: jobID), isExpanded: $isExpanded)
    }
}

private struct ImportChatContent: View {
    @Bindable var session: ImportChatSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isExpanded: Bool
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
                    .accessibilityLabel(isFocused ? "Dismiss keyboard" : "Close import chat")
                    .transition(.opacity)
                }

                VStack(spacing: 12) {
                    if isExpanded, !session.messages.isEmpty {
                        ImportChatConversation(
                            session: session,
                            onBackgroundTap: handleBackgroundTap,
                            onMessageTap: { isFocused = false }
                        )
                            .frame(maxHeight: .infinity)
                            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Spacer(minLength: 0)
                    }
                    composer
                        .padding(.horizontal)
                }
                .padding(.vertical, 6)
            }
        }
        .accessibilityAction(.escape) { closeChat() }
        .onAppear { session.resumeQueued() }
        .onDisappear { isFocused = false }
    }

    private var composer: some View {
        // Share morph geometry without joining the separate resting controls.
        GlassEffectContainer(spacing: 0) {
            HStack(alignment: .bottom) {
                if isExpanded {
                    TextField("What would you like to do?", text: $message, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...5)
                        .focused($isFocused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 22))
                        .glassEffectID("composer", in: glassNamespace)
                        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                        .padding(.bottom, 6)
                        .accessibilityLabel("Import instructions")
                } else {
                    Spacer(minLength: 0)
                }

                // Preserve the button's identity so its symbol can transition as the glass splits.
                actionButton
                    .glassEffectID(isExpanded ? "action" : "composer", in: glassNamespace)
                    .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
            }
        }
    }

    private var actionButton: some View {
        Button(action: performAction) {
            Label(actionLabel, systemImage: actionSymbol)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.offUp))
        }
        .buttonStyle(.glass(.regular.tint(isExpanded && hasMessage && !session.isResponding ? Color.accentColor : nil)))
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .buttonSizing(.flexible)
        .frame(width: 56, height: 56)
        .accessibilityHint(actionHint)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: hasMessage)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: session.isResponding)
    }

    private var actionSymbol: String {
        guard isExpanded else { return "bubble.left" }
        if session.isResponding { return "stop.fill" }
        return hasMessage ? "arrow.up" : "xmark"
    }

    private var actionLabel: String {
        guard isExpanded else { return "Import chat" }
        if session.isResponding { return "Stop response" }
        return hasMessage ? "Send message" : "Close chat"
    }

    private var actionHint: String {
        guard isExpanded else { return "Expands the instruction field. Tap the field to type." }
        if session.isResponding { return "Stops the current reply and keeps any text you are drafting" }
        return hasMessage ? "Asks ChatGPT to help with this import" : "Collapses the instruction field"
    }

    private func performAction() {
        if !isExpanded {
            // Expanding deliberately leaves the keyboard hidden until the field is tapped.
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

private struct ImportChatConversation: View {
    let session: ImportChatSession
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
                    ImportTypingIndicator(label: session.activity)
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

    private func messageBubble(_ message: ImportChatMessage) -> some View {
        let content = formattedContent(for: message)
        return VStack(alignment: .leading, spacing: 8) {
            Text(content)
                .font(.body)
                .contentTransition(reduceMotion ? .identity : .interpolate)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: message.text)
                .textSelection(.enabled)
                .accessibilityLabel(message.role == .user ? "You: \(message.text)" : String(content.characters))
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

    private func formattedContent(for message: ImportChatMessage) -> AttributedString {
        guard message.role == .assistant else { return AttributedString(message.text) }
        // Preserve paragraphs and simple list markers, including while a reply streams.
        return (try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.text)
    }
}

private struct ImportTypingIndicator: View {
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
