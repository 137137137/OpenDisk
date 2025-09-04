//
//  Disk_ManagerApp.swift
//  Disk Manager
//
//  Created by 137137137 on 9/2/25.
//

import SwiftUI

@main
struct Disk_ManagerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowToolbarStyle(UnifiedWindowToolbarStyle())
        .commands {
            SidebarCommands()
            ToolbarCommands()
        }
    }
}
