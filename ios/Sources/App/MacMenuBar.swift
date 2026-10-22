#if targetEnvironment(macCatalyst)
import Foundation

/// Retain the loaded AppKit helper for the process lifetime, independent of scenes.
@MainActor enum MacMenuBar {
    private static var bundle: Bundle?
    private static var controller: NSObject?

    static func start() {
        guard controller == nil,
              let url = Bundle.main.url(forResource: "MacMenuBar", withExtension: "bundle"),
              let loaded = Bundle(url: url),
              let type = loaded.principalClass as? NSObject.Type else { return }
        bundle = loaded
        controller = type.init()
    }
}
#endif
