//
//  ContentView.swift
//  WhoZup
//
//  Created by akshay yadav on 21/06/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.alarmScheduler) private var alarmScheduler
    @Environment(AuthManager.self) private var authManager
    @EnvironmentObject private var alarmStatusRecorder: AlarmStatusRecorder
    @Query private var items: [Item]

    var body: some View {
        NavigationSplitView {
            List {
                Section("Test Alarm") {
                    AlarmTestSection(
                        alarmScheduler: alarmScheduler,
                        alarmStatusRecorder: alarmStatusRecorder
                    )
                }
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
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem {
                    Button(action: addItem) {
                        Label("Add Item", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        TipView()
                    } label: {
                        Label("Support WhoZup", systemImage: "heart")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(role: .destructive) {
                        Task { await authManager.signOut() }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        } detail: {
            Text("Select an item")
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
        .modelContainer(for: Item.self, inMemory: true)
        .environmentObject(AlarmStatusRecorder())
        .environment(AuthManager())
}
