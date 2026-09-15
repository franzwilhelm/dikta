import Foundation
import Combine
import CryptoKit

enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case medium, large
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var bytes: Int64 {
        switch self {
        case .medium: return 1_533_763_076
        case .large: return 3_095_033_483
        }
    }
    var checksum: String {
        switch self {
        case .medium: return "f73141401d203ee77fc7ddf7bf97926a8a85fe85faa6066a6920e4815f48a73d"
        case .large: return "0f2f66f22e11a7c7da3c582d8e5c89cb2c0011753ba9c7c9731e320a4ba33e76"
        }
    }
    var url: URL {
        let revision: String
        switch self {
        case .medium: revision = "0ed074d5985bd56ca4140159a9dbffbc3fb5117e"
        case .large: revision = "8c6249fdeeb4dcd05e5735a4c39640607eb6e4ac"
        }
        return URL(string: "https://huggingface.co/NbAiLab/nb-whisper-\(rawValue)/resolve/\(revision)/ggml-model.bin")!
    }
    var file: URL { NBWhisperAssets.directory.appendingPathComponent("nb-whisper-\(rawValue).bin") }
    var isInstalled: Bool {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        return values?.isRegularFile == true && Int64(values?.fileSize ?? 0) == bytes
    }
}

final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private let destination: URL
    private let update: @Sendable (Int64) -> Void

    init(destination: URL, update: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.update = update
    }

    func download(from url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 24 * 60 * 60
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                downloadTask = task
                task.resume()
                lock.unlock()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.downloadTask
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let now = Date()
        let emit = now.timeIntervalSince(lastUpdate) >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite
        if emit { lastUpdate = now }
        lock.unlock()
        if emit { update(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw DiktatError(message: "Modellnedlastingen feilet. Prøv igjen.")
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        downloadTask = nil
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}

@MainActor
final class WhisperModels: ObservableObject {
    static let shared = WhisperModels()
    @Published var selected: WhisperModel {
        didSet {
            UserDefaults.standard.set(selected.rawValue, forKey: "whisperModel")
            if selected != oldValue { ensureSelected() }
        }
    }
    @Published private(set) var progress: Double = 0
    @Published private(set) var isDownloading = false
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var verifying = false

    // A recording snapshots this value; completing a download never switches an active session.
    var availableModel: WhisperModel {
        if selected.isInstalled { return selected }
        return .medium
    }

    private init() {
        selected = WhisperModel(rawValue: UserDefaults.standard.string(forKey: "whisperModel") ?? "medium") ?? .medium
        ensureSelected()
    }

    func cancelDownload() {
        generation = UUID()
        task?.cancel()
        task = nil
        isDownloading = false
        status = "Nedlasting avbrutt. Medium brukes inntil valgt modell er klar."
    }

    func ensureSelected() {
        task?.cancel()
        task = nil
        let token = UUID()
        generation = token
        let model = selected
        error = nil
        progress = 0
        verifying = false
        isDownloading = false
        if model.isInstalled {
            status = "\(model.title) er klar."
            return
        }
        isDownloading = true
        status = "Laster ned \(model.title) …"
        task = Task { [weak self] in
            let staging = NBWhisperAssets.directory.appendingPathComponent("\(UUID().uuidString).download")
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(at: NBWhisperAssets.directory, withIntermediateDirectories: true)
                let downloader = ModelDownload(destination: staging) { [weak self] received in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.isDownloading, !self.verifying else { return }
                        self.progress = min(1, Double(received) / Double(model.bytes))
                        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .decimal)
                        let total = ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .decimal)
                        self.status = "Laster ned \(model.title): \(done) / \(total)"
                    }
                }
                try await downloader.download(from: model.url)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.verifying = true
                self.status = "Kontrollerer \(model.title) …"
                let verification = Task.detached(priority: .utility) {
                    let file = try FileHandle(forReadingFrom: staging)
                    defer { try? file.close() }
                    var hash = SHA256()
                    var bytes: Int64 = 0
                    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                        try Task.checkCancellation()
                        bytes += Int64(data.count)
                        hash.update(data: data)
                    }
                    let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    guard bytes == model.bytes, actual == model.checksum else {
                        throw DiktatError(message: "Modellfilen har feil kontrollsum. Prøv nedlastingen igjen.")
                    }
                }
                try await withTaskCancellationHandler {
                    try await verification.value
                } onCancel: { verification.cancel() }
                try Task.checkCancellation()
                guard self.generation == token else { return }
                if FileManager.default.fileExists(atPath: model.file.path) {
                    _ = try FileManager.default.replaceItemAt(model.file, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: model.file)
                }
                self.isDownloading = false
                self.progress = 1
                self.status = "\(model.title) er klar til neste opptak."
                self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.isDownloading = false
                self.error = error.localizedDescription
                self.status = "Nedlastingen ble ikke fullført."
                self.task = nil
            }
        }
    }
}
