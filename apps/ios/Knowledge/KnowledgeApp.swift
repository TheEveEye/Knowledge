//
//  KnowledgeApp.swift
//  Knowledge
//
//  Created by Oskar on 10/5/26.
//

import SwiftUI

@main
struct KnowledgeApp: App {
    @State private var account = KnowledgeAccountStore()

    var body: some Scene {
        WindowGroup {
            CloudAuthenticationRootView().environment(account)
        }
    }
}
