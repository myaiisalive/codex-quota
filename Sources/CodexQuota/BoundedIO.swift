import Foundation

enum BoundedFileReader {
    enum ReadError: Error {
        case fileTooLarge
    }

    static func data(from url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize, fileSize > maxBytes {
            throw ReadError.fileTooLarge
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw ReadError.fileTooLarge }
        return data
    }

    static func string(from url: URL, maxBytes: Int) throws -> String {
        let data = try data(from: url, maxBytes: maxBytes)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
}

final class BoundedURLLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum LoadError: Error {
        case responseTooLarge(maxBytes: Int)
        case missingResponse
    }

    private let maxBytes: Int
    private let resourceTimeout: TimeInterval
    private let cachePolicy: URLRequest.CachePolicy
    private let usesSharedCookies: Bool
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var receivedData = Data()
    private var receivedResponse: URLResponse?
    private var terminalError: Error?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false

    private init(
        maxBytes: Int,
        resourceTimeout: TimeInterval,
        cachePolicy: URLRequest.CachePolicy,
        usesSharedCookies: Bool
    ) {
        self.maxBytes = maxBytes
        self.resourceTimeout = resourceTimeout
        self.cachePolicy = cachePolicy
        self.usesSharedCookies = usesSharedCookies
    }

    static func data(
        for request: URLRequest,
        maxBytes: Int,
        resourceTimeout: TimeInterval,
        cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData,
        usesSharedCookies: Bool = false
    ) async throws -> (Data, URLResponse) {
        let loader = BoundedURLLoader(
            maxBytes: maxBytes,
            resourceTimeout: resourceTimeout,
            cachePolicy: cachePolicy,
            usesSharedCookies: usesSharedCookies
        )
        return try await loader.load(request)
    }

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = usesSharedCookies
                    ? URLSessionConfiguration.default
                    : URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = cachePolicy
                configuration.timeoutIntervalForRequest = request.timeoutInterval
                configuration.timeoutIntervalForResource = resourceTimeout

                let delegateQueue = OperationQueue()
                delegateQueue.maxConcurrentOperationCount = 1
                delegateQueue.qualityOfService = .utility

                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                let task = session.dataTask(with: request)

                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                let isCancelled = Task.isCancelled
                lock.unlock()

                if isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        receivedResponse = response
        let expectedLength = response.expectedContentLength
        let isTooLarge = expectedLength > Int64(maxBytes)
        if isTooLarge {
            terminalError = LoadError.responseTooLarge(maxBytes: maxBytes)
        }
        lock.unlock()
        completionHandler(isTooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let exceedsLimit = data.count > maxBytes - receivedData.count
        if exceedsLimit {
            terminalError = LoadError.responseTooLarge(maxBytes: maxBytes)
        } else {
            receivedData.append(data)
        }
        lock.unlock()

        if exceedsLimit {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true

        let continuation = self.continuation
        let resultData = receivedData
        let response = receivedResponse
        let finalError = terminalError ?? error
        self.continuation = nil
        self.task = nil
        let currentSession = self.session
        self.session = nil
        lock.unlock()

        currentSession?.finishTasksAndInvalidate()
        if let finalError {
            continuation?.resume(throwing: finalError)
        } else if let response {
            continuation?.resume(returning: (resultData, response))
        } else {
            continuation?.resume(throwing: LoadError.missingResponse)
        }
    }
}
