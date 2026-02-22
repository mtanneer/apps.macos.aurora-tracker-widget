//
//  AuroraTrackerApp.swift
//  AuroraTracker
//
//  Created by Manas Tanneeru on 2/20/26.
//

import SwiftUI
import WidgetKit

@main
struct AuroraTrackerApp: App {
    init() {
        WidgetCenter.shared.reloadAllTimelines()
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
