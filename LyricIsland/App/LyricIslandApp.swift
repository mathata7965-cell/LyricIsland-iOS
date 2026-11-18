import SwiftUI

@main
struct LyricIslandApp: App {
    @StateObject private var engine = LyricEngine.shared

    init() {
        LiveActivityCommandBridge.handler = { command in
            LyricEngine.shared.handleLiveCommand(command)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainStageView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    engine.handleDeepLink(url)
                }
        }
    }
}
