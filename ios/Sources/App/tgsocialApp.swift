// App — entry point. One AppModel for the process; TDLib clients are closed on willTerminate only.
//
// Under XCTest the app is only a host process: it must not boot TDLib. The test runner calls
// exit() when the suite finishes, which runs TDLib's static destructors while TDLibKit's receive
// thread is still polling — a guaranteed SIGSEGV at exit that shows up as "tgsocial crashed"
// after every `make test`. The unit tests cover the pure protocol layer and never need a client.

import SwiftUI

@main
struct tgsocialApp: App {
    @State private var model: AppModel? = tgsocialApp.isTestHost ? nil : AppModel()

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
