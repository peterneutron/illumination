//
//  IlluminationApp.swift
//  Illumination
//

import SwiftUI
import AppKit

@main
struct IlluminationApp: App {
    @StateObject private var viewModel = IlluminationViewModel()

    var body: some Scene {
        MenuBarExtra {
            IlluminationMenuView(vm: viewModel)
        } label: {
            IlluminationMenuBarLabel(vm: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
