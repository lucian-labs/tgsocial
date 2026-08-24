// TDLib wrapper — client lifecycle, update routing, parameters. The only file that owns a TDLibClientManager.
// Updates arrive on TDLibKit's background queue, are queued into one AsyncStream, and are drained by a single
// main-actor task — so the auth state machine and SendTracker see them in exactly the order TDLib emitted them.

import Foundation
import TDLibKit
import UIKit

public struct TGSecrets {
    public let apiId: Int
    public let apiHash: String

    /// Injected through Secrets.xcconfig → Info.plist (TGApiId / TGApiHash). Never hardcoded.
    public static func fromBundle(_ bundle: Bundle = .main) -> TGSecrets? {
        let info = bundle.infoDictionary ?? [:]
        let idString = (info["TGApiId"] as? String) ?? (info["TGApiId"] as? Int).map(String.init) ?? ""
        let hash = (info["TGApiHash"] as? String) ?? ""
        guard let id = Int(idString.trimmingCharacters(in: .whitespaces)), id > 0,
              !hash.isEmpty, hash != "replace_me" else { return nil }
        return TGSecrets(apiId: id, apiHash: hash)
    }
}

final class TDClient {
    /// EXACTLY ONE per process, for the lifetime of the process.
    ///
    /// `TDLibClientManager.init` spawns a thread that loops on `td_receive`, and TDLib aborts
    /// (`process_fatal_error` from its own LOG(FATAL)) the moment a second thread calls
    /// `td_receive` concurrently. Two managers therefore = a guaranteed SIGABRT, which is
    /// exactly what shipped: a crash report showed two `app.swiftgram.TDLibKit.receive`
    /// queues and `client-1` + `client-2` alive in one process.
    ///
    /// A second manager is easy to create by accident because SwiftUI may initialise an
    /// `App`/`View` struct more than once — every `@State private var model = AppModel()`
    /// evaluates its default again, even though only the first instance is kept. Owning the
    /// manager statically makes that harmless: extra `TDClient`s share this one receive loop.
    private static let manager = TDLibClientManager()

    private(set) var api: TDLibClient
    private let updates: AsyncStream<Update>.Continuation
    private let pump: Task<Void, Never>

    /// Delivered on the main actor, in order: one FIFO stream, one consumer. Per-update Tasks would not
    /// preserve order across hops.
    init(onUpdate: @escaping @MainActor (Update) -> Void) {
        let (stream, continuation) = AsyncStream.makeStream(of: Update.self)
        updates = continuation
        pump = Task { @MainActor in
            for await update in stream { onUpdate(update) }
        }
        api = Self.makeClient(Self.manager, continuation)
    }

    deinit { updates.finish(); pump.cancel() }

    private static func makeClient(_ manager: TDLibClientManager, _ updates: AsyncStream<Update>.Continuation) -> TDLibClient {
        let client = manager.createClient { @Sendable data, client in
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            updates.yield(update)
        }
        _ = try? client.execute(query: DTO(SetLogVerbosityLevel(newVerbosityLevel: 1)))
        return client
    }

    /// After `logOut` TDLib closes the client instance; a fresh one restarts the auth flow on the same stream.
    func recreate() { api = Self.makeClient(Self.manager, updates) }

    /// Blocking; call only from willTerminate.
    func closeClients() { Self.manager.closeClients() }

    static var databaseDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tdlib", isDirectory: true).path
    }

    @discardableResult
    func setParameters(secrets: TGSecrets, appVersion: String) async throws -> Ok {
        let dir = Self.databaseDirectory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return try await api.setTdlibParameters(
            apiHash: secrets.apiHash,
            apiId: secrets.apiId,
            applicationVersion: appVersion,
            databaseDirectory: dir,
            databaseEncryptionKey: nil,
            deviceModel: await MainActor.run { UIDevice.current.model },
            filesDirectory: dir,
            systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
            systemVersion: await MainActor.run { UIDevice.current.systemVersion },
            useChatInfoDatabase: true,
            useFileDatabase: true,
            useMessageDatabase: true,
            useSecretChats: false,
            useTestDc: false
        )
    }
}

/// Resolves `sendMessage` results to their final server message (updateMessageSendSucceeded / Failed).
@MainActor
final class SendTracker {
    private var waiters: [Int64: CheckedContinuation<Message, Swift.Error>] = [:]

    func handle(_ update: Update) {
        switch update {
        case .updateMessageSendSucceeded(let u):
            waiters.removeValue(forKey: u.oldMessageId)?.resume(returning: u.message)
        case .updateMessageSendFailed(let u):
            waiters.removeValue(forKey: u.oldMessageId)?.resume(throwing: TDFailure(code: u.error.code, message: u.error.message))
        default: break
        }
    }

    /// Waits for the pending message `tempId` to be acknowledged; times out after `seconds`.
    func awaitSent(_ tempId: Int64, seconds: Double = 30) async throws -> Message {
        try await withCheckedThrowingContinuation { c in
            waiters[tempId] = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.waiters.removeValue(forKey: tempId)?.resume(throwing: TDFailure(code: 408, message: "Telegram did not confirm the message."))
            }
        }
    }
}

/// TDLib error shape, normalised for the UI layer.
struct TDFailure: Swift.Error, Equatable {
    let code: Int
    let message: String

    init(_ error: Swift.Error) {
        if let e = error as? TDLibKit.Error { code = e.code; message = e.message }
        else { code = -1; message = String(describing: error) }
    }

    init(code: Int, message: String) { self.code = code; self.message = message }

    var floodWaitSeconds: Int? { FloodWait.seconds(code: code, message: message) }
    var isFloodWait: Bool { (floodWaitSeconds ?? 0) > 0 }
    static func isFloodWait(_ error: Swift.Error) -> Bool { TDFailure(error).isFloodWait }
    var isNotFound: Bool { code == 404 }
    var isNetwork: Bool { code == 500 && message.lowercased().contains("network") || message == "Request aborted" }
}
