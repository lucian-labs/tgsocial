// App — entry point. One AppModel for the process; TDLib clients are closed on willTerminate only.
//
// Two rules are load-bearing here, and both are about being constructed more than once.
//
// 1. Under XCTest the app is only a host process: it must not boot TDLib. The test runner calls
//    exit() when the suite finishes, which runs TDLib's static destructors while TDLibKit's receive
//    thread is still polling — a guaranteed SIGSEGV at exit that shows up as "tgsocial crashed"
//    after every `make test`. The unit tests cover the pure protocol layer and never need a client.
//
// 2. SwiftUI may initialise an App/View struct several times. `@State private var model = AppModel()`
//    would evaluate `AppModel()` on every one of those inits, and only the first result is kept —
//    so the extras leak whatever their init started. AppModel starts a TDLib client, and TDLib
//    aborts the process (LOG(FATAL) → process_fatal_error) as soon as a second thread calls
//    td_receive. That crash was real: a report showed two `TDLibKit.receive` queues and client-1 +
//    client-2 in one process. TDClient now owns its manager statically, and `shared` below makes
//    the model itself a single instance, so re-initialising this struct costs nothing.

import SwiftUI

@main
struct tgsocialApp: App {
    /// The one AppModel for the process. `nil` under XCTest, where the app is only a test host.
    @MainActor static let shared: AppModel? = isTestHost ? nil : AppModel()

    @State private var model: AppModel? = tgsocialApp.shared

    static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
    }

    var body: some Scene {
        WindowGroup {
            if let model {
                RootView()
                    .environment(model)
                    .preferredColorScheme(.light)
                    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                        model.terminate()
                    }
            } else {
                HPBackdrop()
            }
        }
    }
}
