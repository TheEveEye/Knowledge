//
//  KnowledgeApp.swift
//  Knowledge
//
//  Created by Oskar on 10/5/26.
//

import SwiftUI
import SwiftData

@main
struct KnowledgeApp: App {
    @State private var authentication: AuthenticationStore
    @State private var imports: ImportCoordinator
    let sharedModelContainer: ModelContainer

    init() {
        let authentication = AuthenticationStore()
        do {
            let container = try KnowledgePersistence.container()
            sharedModelContainer = container
            _authentication = State(initialValue: authentication)
            _imports = State(initialValue: ImportCoordinator(authentication: authentication, container: container))
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            authenticatedContent
        }
        .modelContainer(sharedModelContainer)
    }

    private var authenticatedContent: some View {
            AuthenticationRootView()
                .environment(authentication)
                .environment(imports)
                .onChange(of: authentication.isBusy) { _, busy in
                    if busy {
                        imports.interruptChats(message: "Your ChatGPT connection is changing. Send your request again when it finishes.")
                        imports.merges.interrupt()
                        imports.pauseAll(message: "Your ChatGPT connection is changing. Your drafts were kept.")
                    }
                }
                .onChange(of: authentication.activeAccount?.credentials?.planEnabled) { _, enabled in
                    if enabled != true {
                        imports.interruptChats(message: "ChatGPT plan permission changed. Your draft edits were kept.")
                        imports.merges.interrupt()
                        imports.pauseAll(message: "ChatGPT plan permission changed. Your drafts were kept.")
                    }
                }
    }
}
