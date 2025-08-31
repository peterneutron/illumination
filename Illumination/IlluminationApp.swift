//
//  IlluminationApp.swift
//  Illumination
//
//  Created by Sebastian Oechsle on 30.08.25.
//

import SwiftUI
import AppKit

@main
struct IlluminationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Minimal scene to satisfy SwiftUI App requirements; no UI needed here
        Settings {
            EmptyView()
        }
    }
}
