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
    @State private var authentication = AuthenticationStore()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            AuthenticationRootView()
                .environment(authentication)
        }
        .modelContainer(sharedModelContainer)
    }
}
