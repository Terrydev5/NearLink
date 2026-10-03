//
//  NearLinkApp.swift
//  NearLink
//
//  Created by Terry on 2026/9/14.
//

import SwiftUI

@main
struct NearLinkApp: App {
    // 应用入口持有共享状态；子视图通过 environmentObject 读取，生命周期事件交给 model。
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
