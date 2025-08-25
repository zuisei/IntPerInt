import Foundation

/// Delegate to handle multiple concurrent download tasks.
/// Maps URLSessionTask identifiers to model IDs and forwards
/// progress/completion events via closures.
class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    /// Called with (modelID, bytesWritten, totalBytes).
    var progressHandler: ((String, Int64, Int64) -> Void)?
    /// Called when download finished with (modelID, location).
    var completionHandler: ((String, URL) -> Void)?

    private var taskToID: [Int: String] = [:]

    /// Associate a task with a model identifier so delegate can
    /// report progress for the correct model.
    func register(task: URLSessionDownloadTask, for id: String) {
        taskToID[task.taskIdentifier] = id
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = taskToID[downloadTask.taskIdentifier] else { return }
        progressHandler?(id, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = taskToID[downloadTask.taskIdentifier] else { return }
        completionHandler?(id, location)
        taskToID.removeValue(forKey: downloadTask.taskIdentifier)
    }
}
