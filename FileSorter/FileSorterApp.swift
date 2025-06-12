//
//  FileSorterApp.swift
//  FileSorter
//
//  Created by Cameron Brooks on 6/11/25.
//

import SwiftUI
import CoreData

@main
struct FileSorterApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .containerBackground(.ultraThinMaterial, for: .window)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
    }
}
