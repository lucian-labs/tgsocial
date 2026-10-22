#if targetEnvironment(macCatalyst)
import Foundation
import CryptoKit

struct ConnectorUploadSpec: Codable, Equatable {
    var feed: String
    var kind: String
    var filename: String
    var bytes: Int64
    var sha256: String
    var caption: String = ""

    func validated(maxBytes: Int64) throws -> Self {
        guard let username = Username.normalise(feed), ["video", "photo", "document"].contains(kind),
              !filename.isEmpty, filename.count <= 120, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), !ConnectorHTTP.hasControlCharacters(filename),
              bytes > 0, bytes <= maxBytes, caption.utf16.count <= 1024,
              sha256.count == 64, sha256.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ConnectorError.badRequest("Invalid upload metadata, size, filename, caption or SHA-256.")
        }
        if kind == "photo", bytes > 10 * 1024 * 1024 {
            throw ConnectorError.tooLarge(bytes: bytes, maxBytes: 10 * 1024 * 1024)
        }
        var result = self; result.feed = username; result.sha256 = sha256.lowercased()
        return result
    }
}

struct ConnectorUploadJob: Codable {
    var id: String
    var spec: ConnectorUploadSpec
    var state = "uploading"
    var receivedBytes: Int64 = 0
    var uploadedBytes: Int64 = 0
    var createdAt = Date()
    var chatId: Int64?
    var pendingId: Int64?
    var fileId: Int?
    var postURL: String?
    var error: String?

    var body: [String: Any] {
        ["requestId": id, "feed": spec.feed, "kind": spec.kind, "state": state,
         "phase": state == "queued" ? (uploadedBytes < spec.bytes ? "telegram-upload" : "telegram-queue") : state,
         "bytes": spec.bytes, "receivedBytes": receivedBytes, "uploadedBytes": uploadedBytes,
         "chunkBytes": ConnectorUploadStore.chunkBytes,
         "postURL": ConnectorJSON.optional(postURL), "error": ConnectorJSON.optional(error)]
    }
}

/// Persistent small receipt ledger; all payloads live in temporary storage.
/// A request ID is never automatically reused, even after an uncertain send or a restart.
@MainActor
final class ConnectorUploadStore {
    static let chunkBytes = 1 << 20
    static let maxJobs = 1000
    static let maxActive = 4
    static let stagingBudget: Int64 = 1 << 30
    private let store: LocalStore
    private let key: String
    let directory: URL
    private(set) var jobs: [String: ConnectorUploadJob]

    init(store: LocalStore, directory: URL, key: String = "connector-upload-receipts") throws {
        self.store = store; self.directory = directory; self.key = key
        jobs = store.load([String: ConnectorUploadJob].self, key) ?? [:]
        for id in Array(jobs.keys) {
            switch jobs[id]?.state {
            case "queued", "uncertain":
                jobs[id]?.state = "uncertain"
                jobs[id]?.error = "App restarted before confirmation. Do not resend; reconcile with Telegram."
            case "uploading", "staged", "verifying":
                jobs[id]?.state = "failed"; jobs[id]?.error = "Temporary upload interrupted by restart."
            default: break
            }
        }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try persist()
    }

    static func validID(_ id: String) -> Bool {
        (8...80).contains(id.count) && id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    func job(_ id: String) throws -> ConnectorUploadJob {
        guard Self.validID(id), let job = jobs[id] else { throw ConnectorError.notFound("upload request") }
        return job
    }
    func url(_ job: ConnectorUploadJob) -> URL {
        directory.appendingPathComponent(job.id, isDirectory: true).appendingPathComponent(job.spec.filename)
    }
    private func persist() throws { try store.saveVerified(jobs, key) }
    func save(_ job: ConnectorUploadJob) throws { jobs[job.id] = job; try persist() }
    func removeData(_ job: ConnectorUploadJob) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(job.id, isDirectory: true)) }

    func create(id: String, spec: ConnectorUploadSpec) throws -> ConnectorUploadJob {
        guard Self.validID(id) else { throw ConnectorError.badRequest("requestId must be 8–80 ASCII letters, digits, - or _") }
        if let existing = jobs[id] {
            guard existing.spec == spec else { throw ConnectorError.conflict("requestId already belongs to a different upload") }
            return existing
        }
        let active = jobs.values.filter { ["uploading", "staged", "verifying", "queued"].contains($0.state) }
        guard jobs.count < Self.maxJobs, active.count < Self.maxActive,
              active.reduce(Int64(0), { $0 + $1.spec.bytes }) + spec.bytes <= Self.stagingBudget else {
            throw ConnectorError.conflict("Upload queue or receipt ledger is full")
        }
        let job = ConnectorUploadJob(id: id, spec: spec)
        let parent = url(job).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard FileManager.default.createFile(atPath: url(job).path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ConnectorError.badRequest("Could not create temporary upload")
        }
        try save(job)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15 * 60))
            try? self?.expire()
        }
        return job
    }

    func append(id: String, offset: Int64, data: Data) throws -> ConnectorUploadJob {
        var job = try self.job(id)
        guard ["uploading", "staged"].contains(job.state), !data.isEmpty, data.count <= Self.chunkBytes,
              offset >= 0, offset <= job.receivedBytes, offset + Int64(data.count) <= job.spec.bytes else {
            throw ConnectorError.conflict("Invalid chunk offset, size or upload state; read upload status")
        }
        let file = try FileHandle(forUpdating: url(job)); defer { try? file.close() }
        try file.seek(toOffset: UInt64(offset))
        if offset < job.receivedBytes {
            guard offset + Int64(data.count) <= job.receivedBytes,
                  try file.read(upToCount: data.count) == data else {
                throw ConnectorError.conflict("Chunk retry does not match saved bytes")
            }
            return job
        }
        try file.write(contentsOf: data); try file.synchronize()
        job.receivedBytes += Int64(data.count)
        if job.receivedBytes == job.spec.bytes { job.state = "staged" }
        try save(job)
        return job
    }

    func verify(id: String) async throws -> ConnectorUploadJob {
        var job = try self.job(id)
        guard job.state == "staged" else { throw ConnectorError.conflict("Upload is not staged") }
        job.state = "verifying"; try save(job)
        let fileURL = url(job)
        let digest = try await Task.detached {
            let file = try FileHandle(forReadingFrom: fileURL); defer { try? file.close() }
            var hash = SHA256()
            while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
        job = try self.job(id)
        guard job.state == "verifying" else { throw ConnectorError.conflict("Upload was cancelled") }
        guard digest == job.spec.sha256 else {
            job.state = "failed"; job.error = "SHA-256 mismatch"; try save(job); removeData(job)
            throw ConnectorError.badRequest("SHA-256 mismatch")
        }
        return job
    }
    func expire(at now: Date = Date()) throws {
        for var job in jobs.values where ["uploading", "staged", "verifying"].contains(job.state) && now.timeIntervalSince(job.createdAt) >= 15 * 60 {
            job.state = "failed"; job.error = "Temporary staging expired"; try save(job); removeData(job)
        }
    }
}
#endif
