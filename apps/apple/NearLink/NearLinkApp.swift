//
//  NearLinkApp.swift
//  NearLink
//
//  Created by Terry on 2026/9/14.
//

import SwiftUI

@main
struct NearLinkApp: App {
    @StateObject private var model = NearLinkAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                model.appDidEnterBackground()
            case .active:
                model.resumeAfterBackground()
            default:
                break
            }
        }
    }
}
