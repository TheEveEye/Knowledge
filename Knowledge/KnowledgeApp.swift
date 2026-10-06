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
            AuthenticationRootView()
                .environment(authentication)
                .environment(imports)
                .onChange(of: authentication.activeAccount?.id) { _, _ in imports.accountChanged() }
                .onChange(of: authentication.isBusy) { _, busy in
                    if busy { imports.pause(message: "Your ChatGPT connection is changing. Your draft was kept.") }
                }
                .onChange(of: authentication.activeAccount?.credentials?.planEnabled) { _, enabled in
                    if enabled != true { imports.pause(message: "ChatGPT plan permission changed. Your draft was kept.") }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
