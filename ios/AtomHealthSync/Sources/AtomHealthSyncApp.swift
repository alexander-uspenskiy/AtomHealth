import BackgroundTasks
import SwiftUI

@main
struct AtomHealthSyncApp: App {
    static let refreshID = "com.alex.atomhealthsync.refresh"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Runs for every launch, including the background launches HealthKit and BGTaskScheduler trigger,
        // when no view is ever created. Observers must be registered here or those wake-ups do nothing.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
            Self.schedule()   // always queue the next one first
            let work = Task { @MainActor in
                await AppModel.shared.start()
                await AppModel.shared.syncNow()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        Self.schedule()
        Task { @MainActor in await AppModel.shared.start() }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
            .onChange(of: scenePhase) { _, p in if p == .background { Self.schedule() } }
    }

    static func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: refreshID)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }
}
