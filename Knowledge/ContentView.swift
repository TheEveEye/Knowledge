//
//  ContentView.swift
//  Knowledge
//
//  Created by Oskar on 10/5/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthenticationStore.self) private var authentication
    @Query private var items: [Item]
    @State private var presentedSheet: AccountSheet?

    private enum AccountSheet: String, Identifiable {
        case account, planWelcome
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Items") {
                    ForEach(items) { item in
                        NavigationLink {
                            Text("Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))")
                        } label: {
                            Text(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
            }
            .navigationTitle("Knowledge")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        presentedSheet = .account
                    } label: {
                        Label("ChatGPT account", systemImage: "person.crop.circle")
                    }
                }
            }
        } detail: {
            Text("Select an item")
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .account:
                ChatGPTAccountView()
            case .planWelcome:
                ChatGPTPlanWelcomeView()
            }
        }
        .onAppear {
            if authentication.planWelcomeAccountID != nil {
                presentedSheet = .planWelcome
            }
        }
        .onChange(of: authentication.planWelcomeAccountID) { _, accountID in
            if accountID != nil { presentedSheet = .planWelcome }
        }
    }

    private func addItem() {
        withAnimation {
            let newItem = Item(timestamp: Date())
            modelContext.insert(newItem)
        }
    }

    private func deleteItems(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                modelContext.delete(items[index])
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AuthenticationStore())
        .modelContainer(for: Item.self, inMemory: true)
}
