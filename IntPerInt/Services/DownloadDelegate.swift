import Foundation

// MARK: - URLSessionDownloadDelegate helper for progress & completion
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let modelName: String
    let destinationURL: URL
    // onProgress(name, progress(0-1), speedMBps, expectedBytes, totalBytesWritten)
    let onProgress: (String, Double, Double, Int64, Int64) -> Void
    let onComplete: (String, Result<URL, Error>) -> Void
    private let startDate: Date

    init(modelName: String,
         destinationURL: URL,
         onProgress: @escaping (String, Double, Double, Int64, Int64) -> Void,
         onComplete: @escaping (String, Result<URL, Error>) -> Void) {
        self.modelName = modelName
        self.destinationURL = destinationURL
        self.onProgress = onProgress
        self.onComplete = onComplete
        self.startDate = Date()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite
        let progress: Double
        if expected > 0 {
            progress = Double(totalBytesWritten) / Double(expected)
        } else {
            progress = 0.0
        }
        let elapsed = Date().timeIntervalSince(startDate)
        let speedMBps = elapsed > 0 ? (Double(totalBytesWritten) / 1_000_000.0) / elapsed : 0.0
        onProgress(modelName, progress, speedMBps, expected, totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            onComplete(modelName, .success(destinationURL))
        } catch {
            onComplete(modelName, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            onComplete(modelName, .failure(error))
        }
    }
}
