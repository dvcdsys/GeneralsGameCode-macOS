import Foundation

/// Delegate-based download with progress, bridged to async/await.
/// Faster than iterating `URLSession.bytes` and gives accurate progress.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progressHandler: (Double) -> Void

    init(progress: @escaping (Double) -> Void) {
        self.progressHandler = progress
    }

    func download(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.setValue("GeneralsZHLauncher", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            session.downloadTask(with: req).resume()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            continuation?.resume(throwing: LauncherError.releaseUnavailable(status: status))
            continuation = nil
            return
        }
        // `location` is removed once this delegate returns — move it out now.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gzh-\(UUID().uuidString).zip")
        do {
            try? FileManager.default.removeItem(at: tmp)
            try FileManager.default.moveItem(at: location, to: tmp)
            continuation?.resume(returning: tmp)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
