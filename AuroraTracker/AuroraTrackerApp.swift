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
    @AppStorage("appTheme") private var theme: AppTheme = .system

    init() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(theme.colorScheme)
        }
    }
}
