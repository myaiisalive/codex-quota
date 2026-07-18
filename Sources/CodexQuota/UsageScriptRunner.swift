import Foundation
import JavaScriptCore
import Darwin

/// 调用 CC Switch 的 usage_script 拿到余额
/// 流程：模板替换 → JS eval 拿 request 配置 → URLSession 发请求 → JS eval extractor(response)
enum UsageScriptRunner {
    private static let workerFlag = "--usage-script-worker"
    private static let workerInputLimit = 6 * 1024 * 1024
    private static let workerOutputLimit = 1024 * 1024
    private static let workerMemoryLimit = UInt64(128 * 1024 * 1024)
    private static let networkResponseLimit = 4 * 1024 * 1024
    private static let scriptTimeoutSeconds: TimeInterval = 5

    struct Balance: Codable, Equatable {
        var providerName: String
        var remaining: Double?
        var used: Double?
        var total: Double?
        var unit: String?
        var planName: String?
        var isValid: Bool
        var invalidMessage: String?
    }

    enum RunError: Error, LocalizedError, CustomStringConvertible {
        case jsEvalFailed(String)
        case jsTimedOut
        case workerMemoryLimitExceeded
        case workerFailed(String)
        case badRequestSpec
        case badRequestBody
        case http(Int)
        case network(Error)
        case responseTooLarge
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .jsEvalFailed(let message):
                return "余额脚本无法运行：\(message)"
            case .jsTimedOut:
                return "余额脚本运行超时，已自动停止"
            case .workerMemoryLimitExceeded:
                return "余额脚本占用内存过多，已自动停止"
            case .workerFailed(let message):
                return "余额脚本没有完成：\(message)"
            case .badRequestSpec:
                return "余额脚本没有提供有效的查询地址"
            case .badRequestBody:
                return "余额脚本的查询内容无法识别"
            case .http(let statusCode):
                return "余额接口返回了错误状态（\(statusCode)）"
            case .network(let error):
                return "无法连接余额接口：\(error.localizedDescription)"
            case .responseTooLarge:
                return "余额接口返回内容过大，已停止读取"
            case .invalidJSON:
                return "余额接口返回的内容无法识别"
            }
        }

        var description: String {
            errorDescription ?? "余额查询失败"
        }
    }

    static func run(provider: CCSwitchProvider, codexApiKey: String? = nil) async throws -> Balance {
        let baseUrl = provider.baseUrl.hasSuffix("/")
            ? String(provider.baseUrl.dropLast())
            : provider.baseUrl
        // codexApiKey 优先：codex auth.json 里的 key 才是实际使用的那个
        let apiKey = codexApiKey ?? provider.apiKey ?? ""
        let filled = provider.usageScriptCode
            .replacingOccurrences(of: "{{baseUrl}}", with: baseUrl)
            .replacingOccurrences(of: "{{apiKey}}", with: apiKey)
            .replacingOccurrences(of: "{{accessToken}}", with: provider.accessToken ?? "")
            .replacingOccurrences(of: "{{userId}}", with: provider.userId ?? "")

        // JavaScript 在独立工作进程中运行，异常脚本不会拖住主软件。
        let workerSession = try await startWorkerSession(script: filled)
        defer { closeWorkerSession(workerSession) }
        let workerRequest = workerSession.request
        guard let url = URL(string: workerRequest.url) else {
            throw RunError.badRequestSpec
        }
        let body: Data?
        if let encodedBody = workerRequest.bodyBase64 {
            guard let decodedBody = Data(base64Encoded: encodedBody) else {
                throw RunError.badRequestBody
            }
            body = decodedBody
        } else {
            body = nil
        }

        // 3. 发请求
        var req = URLRequest(url: url)
        req.httpMethod = workerRequest.method
        let networkTimeout = provider.timeoutSeconds ?? 15
        req.timeoutInterval = networkTimeout
        for (key, value) in workerRequest.headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
        req.httpBody = body

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await BoundedURLLoader.data(
                for: req,
                maxBytes: networkResponseLimit,
                resourceTimeout: networkTimeout > 0 ? networkTimeout + 5 : 60,
                // 余额会实时变化，不能复用系统缓存中的旧响应。
                cachePolicy: .reloadIgnoringLocalCacheData,
                usesSharedCookies: true
            )
        } catch BoundedURLLoader.LoadError.responseTooLarge {
            throw RunError.responseTooLarge
        } catch {
            throw RunError.network(error)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RunError.http(http.statusCode)
        }

        guard let bodyStr = String(data: data, encoding: .utf8) else {
            throw RunError.invalidJSON
        }

        // 4. extractor 同样放在隔离进程中执行。
        let extractorOutput = try await finishWorkerSession(
            workerSession,
            responseJSON: bodyStr
        )
        guard let resultJsonStr = extractorOutput.resultJSON,
              let resultData = resultJsonStr.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw RunError.jsEvalFailed("extractor 失败")
        }

        return parseBalance(providerName: provider.name, result: result)
    }

    /// 子进程入口。返回 true 表示当前进程只负责执行 usage_script，不应启动界面。
    static func runWorkerIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
        guard arguments.count >= 2, arguments[1] == workerFlag else { return false }

        if arguments.count == 6 {
            runPersistentWorker(
                inputURL: URL(fileURLWithPath: arguments[2]),
                requestOutputURL: URL(fileURLWithPath: arguments[3]),
                responseInputURL: URL(fileURLWithPath: arguments[4]),
                resultOutputURL: URL(fileURLWithPath: arguments[5])
            )
            return true
        }
        guard arguments.count == 4 else { return true }

        let inputURL = URL(fileURLWithPath: arguments[2])
        let outputURL = URL(fileURLWithPath: arguments[3])
        let output: WorkerOutput
        do {
            let inputData = try BoundedFileReader.data(from: inputURL, maxBytes: workerInputLimit)
            let input = try JSONDecoder().decode(WorkerInput.self, from: inputData)
            output = try evaluateWorkerInput(input)
        } catch {
            output = WorkerOutput(error: String(describing: error))
        }
        writeWorkerOutput(output, to: outputURL)
        return true
    }

    private static func runPersistentWorker(
        inputURL: URL,
        requestOutputURL: URL,
        responseInputURL: URL,
        resultOutputURL: URL
    ) {
        var requestWasWritten = false
        do {
            let inputData = try BoundedFileReader.data(from: inputURL, maxBytes: workerInputLimit)
            let input = try JSONDecoder().decode(WorkerInput.self, from: inputData)
            let context = try makeContext(script: input.script)
            let requestOutput = try evaluateRequest(context: context)
            writeWorkerOutput(requestOutput, to: requestOutputURL)
            requestWasWritten = true

            let waitDeadline = Date().addingTimeInterval(70)
            while !FileManager.default.fileExists(atPath: responseInputURL.path), Date() < waitDeadline {
                usleep(20_000)
            }
            guard FileManager.default.fileExists(atPath: responseInputURL.path) else {
                throw RunError.workerFailed("等待接口响应超时")
            }

            let responseData = try BoundedFileReader.data(
                from: responseInputURL,
                maxBytes: workerInputLimit
            )
            let response = try JSONDecoder().decode(WorkerResponseInput.self, from: responseData)
            let result = try evaluateExtractor(context: context, responseJSON: response.responseJSON)
            writeWorkerOutput(result, to: resultOutputURL)
        } catch {
            let outputURL = requestWasWritten ? resultOutputURL : requestOutputURL
            writeWorkerOutput(WorkerOutput(error: String(describing: error)), to: outputURL)
        }
    }

    private static func evaluateWorkerInput(_ input: WorkerInput) throws -> WorkerOutput {
        let context = try makeContext(script: input.script)
        switch input.mode {
        case .request:
            return try evaluateRequest(context: context)
        case .extract:
            guard let responseJSON = input.responseJSON else { throw RunError.invalidJSON }
            return try evaluateExtractor(context: context, responseJSON: responseJSON)
        }
    }

    private static func makeContext(script: String) throws -> JSContext {
        guard let context = JSContext() else {
            throw RunError.jsEvalFailed("无法创建 JSContext")
        }
        context.exceptionHandler = { _, _ in }
        context.evaluateScript("var __spec = \(script);")
        if let exception = context.exception {
            throw RunError.jsEvalFailed(exception.toString() ?? "eval failed")
        }
        guard context.objectForKeyedSubscript("__spec") != nil else {
            throw RunError.badRequestSpec
        }
        return context
    }

    private static func evaluateRequest(context: JSContext) throws -> WorkerOutput {
        guard let spec = context.objectForKeyedSubscript("__spec"),
              let request = spec.objectForKeyedSubscript("request"),
              let url = request.objectForKeyedSubscript("url")?.toString() else {
            throw RunError.badRequestSpec
        }
        let method = request.objectForKeyedSubscript("method")?.toString() ?? "GET"
        let headers = headerMap(from: request.objectForKeyedSubscript("headers"))
        let body = try requestBodyData(from: request)
        return WorkerOutput(
            request: WorkerRequest(
                url: url,
                method: method,
                headers: headers,
                bodyBase64: body?.base64EncodedString()
            )
        )
    }

    private static func evaluateExtractor(context: JSContext, responseJSON: String) throws -> WorkerOutput {
        let extractorCall = """
        (function(){
            try {
                var response = JSON.parse(\(jsString(responseJSON)));
                var r = __spec.extractor(response);
                var json = JSON.stringify(r);
                if (typeof json !== "string" || json.length > \(workerOutputLimit / 2)) {
                    return JSON.stringify({ isValid: false, invalidMessage: "返回内容过大" });
                }
                return json;
            } catch (e) {
                return JSON.stringify({ isValid: false, invalidMessage: String(e) });
            }
        })()
        """
        guard let resultJSON = context.evaluateScript(extractorCall)?.toString() else {
            throw RunError.jsEvalFailed("extractor 失败")
        }
        return WorkerOutput(resultJSON: resultJSON)
    }

    private static func startWorkerSession(script: String) async throws -> WorkerSession {
        let inputData = try JSONEncoder().encode(
            WorkerInput(mode: .request, script: script, responseJSON: nil)
        )
        guard inputData.count <= workerInputLimit else { throw RunError.responseTooLarge }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaUsage-\(UUID().uuidString)", isDirectory: true)
        let inputURL = workspace.appendingPathComponent("input.json")
        let requestOutputURL = workspace.appendingPathComponent("request.json")
        let responseInputURL = workspace.appendingPathComponent("response.json")
        let resultOutputURL = workspace.appendingPathComponent("result.json")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        try inputData.write(to: inputURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)

        guard let executableURL = Bundle.main.executableURL else {
            try? FileManager.default.removeItem(at: workspace)
            throw RunError.workerFailed("找不到工作进程")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            workerFlag,
            inputURL.path,
            requestOutputURL.path,
            responseInputURL.path,
            resultOutputURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let output = try await waitForWorkerOutput(
                at: requestOutputURL,
                process: process,
                timeoutSeconds: scriptTimeoutSeconds
            )
            if let error = output.error {
                throw RunError.workerFailed(error)
            }
            guard let request = output.request else { throw RunError.badRequestSpec }
            return WorkerSession(
                process: process,
                workspace: workspace,
                responseInputURL: responseInputURL,
                resultOutputURL: resultOutputURL,
                request: request
            )
        } catch {
            stopWorker(process)
            try? FileManager.default.removeItem(at: workspace)
            throw error
        }
    }

    private static func finishWorkerSession(
        _ session: WorkerSession,
        responseJSON: String
    ) async throws -> WorkerOutput {
        let responseData = try JSONEncoder().encode(WorkerResponseInput(responseJSON: responseJSON))
        guard responseData.count <= workerInputLimit else { throw RunError.responseTooLarge }
        try responseData.write(to: session.responseInputURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: session.responseInputURL.path
        )

        let output = try await waitForWorkerOutput(
            at: session.resultOutputURL,
            process: session.process,
            timeoutSeconds: scriptTimeoutSeconds
        )
        if let error = output.error {
            throw RunError.workerFailed(error)
        }
        return output
    }

    private static func waitForWorkerOutput(
        at url: URL,
        process: Process,
        timeoutSeconds: TimeInterval
    ) async throws -> WorkerOutput {
        let deadline = Date().addingTimeInterval(max(0.1, timeoutSeconds))
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try BoundedFileReader.data(from: url, maxBytes: workerOutputLimit)
                return try JSONDecoder().decode(WorkerOutput.self, from: data)
            }
            guard process.isRunning else {
                throw RunError.workerFailed("工作进程异常退出")
            }
            if let residentSize = residentMemorySize(of: process), residentSize > workerMemoryLimit {
                stopWorker(process)
                throw RunError.workerMemoryLimitExceeded
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw RunError.jsTimedOut
    }

    private static func closeWorkerSession(_ session: WorkerSession) {
        stopWorker(session.process)
        try? FileManager.default.removeItem(at: session.workspace)
    }

    private static func runWorker(
        input: WorkerInput,
        timeoutSeconds: TimeInterval
    ) async throws -> WorkerOutput {
        let inputData = try JSONEncoder().encode(input)
        guard inputData.count <= workerInputLimit else { throw RunError.responseTooLarge }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuotaUsage-\(UUID().uuidString)", isDirectory: true)
        let inputURL = workspace.appendingPathComponent("input.json")
        let outputURL = workspace.appendingPathComponent("output.json")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try inputData.write(to: inputURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)

        guard let executableURL = Bundle.main.executableURL else {
            throw RunError.workerFailed("找不到工作进程")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [workerFlag, inputURL.path, outputURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(max(0.1, timeoutSeconds))
        while process.isRunning && Date() < deadline {
            if let residentSize = residentMemorySize(of: process), residentSize > workerMemoryLimit {
                stopWorker(process)
                throw RunError.workerMemoryLimitExceeded
            }
            do {
                try await Task.sleep(nanoseconds: 5_000_000)
            } catch {
                stopWorker(process)
                throw error
            }
        }
        guard !process.isRunning else {
            stopWorker(process)
            throw RunError.jsTimedOut
        }
        guard process.terminationStatus == 0 else {
            throw RunError.workerFailed("工作进程异常退出")
        }

        let outputData = try BoundedFileReader.data(from: outputURL, maxBytes: workerOutputLimit)
        let output = try JSONDecoder().decode(WorkerOutput.self, from: outputData)
        if let error = output.error {
            throw RunError.workerFailed(error)
        }
        return output
    }

    private static func stopWorker(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        usleep(50_000)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func residentMemorySize(of process: Process) -> UInt64? {
        guard process.processIdentifier > 0 else { return nil }
        var info = proc_taskinfo()
        let expectedSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let readSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(process.processIdentifier, PROC_PIDTASKINFO, 0, $0, expectedSize)
        }
        guard readSize == expectedSize else { return nil }
        return info.pti_resident_size
    }

    private static func writeWorkerOutput(_ output: WorkerOutput, to url: URL) {
        let encoder = JSONEncoder()
        var finalOutput = output
        var data = try? encoder.encode(finalOutput)
        if data == nil || data!.count > workerOutputLimit {
            finalOutput = WorkerOutput(error: "工作进程返回内容过大")
            data = try? encoder.encode(finalOutput)
        }
        try? data?.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

#if DEBUG
    static func evaluateSessionForTesting(
        script: String,
        responseJSON: String
    ) async throws -> (headers: [String: String], result: [String: Any]) {
        let session = try await startWorkerSession(script: script)
        defer { closeWorkerSession(session) }
        let output = try await finishWorkerSession(session, responseJSON: responseJSON)
        guard let resultJSON = output.resultJSON,
              let data = resultJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RunError.invalidJSON
        }
        return (session.request.headers, result)
    }

    static func evaluateRequestForTesting(
        script: String,
        timeoutSeconds: TimeInterval = 1
    ) async throws -> (url: String, method: String) {
        let output = try await runWorker(
            input: WorkerInput(mode: .request, script: script, responseJSON: nil),
            timeoutSeconds: timeoutSeconds
        )
        guard let request = output.request else { throw RunError.badRequestSpec }
        return (request.url, request.method)
    }

    static func evaluateExtractorForTesting(
        script: String,
        responseJSON: String,
        timeoutSeconds: TimeInterval = 1
    ) async throws -> [String: Any] {
        let output = try await runWorker(
            input: WorkerInput(mode: .extract, script: script, responseJSON: responseJSON),
            timeoutSeconds: timeoutSeconds
        )
        guard let resultJSON = output.resultJSON,
              let data = resultJSON.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RunError.invalidJSON
        }
        return result
    }
#endif

    private struct WorkerInput: Codable {
        enum Mode: String, Codable {
            case request
            case extract
        }

        let mode: Mode
        let script: String
        let responseJSON: String?
    }

    private struct WorkerRequest: Codable {
        let url: String
        let method: String
        let headers: [String: String]
        let bodyBase64: String?
    }

    private struct WorkerResponseInput: Codable {
        let responseJSON: String
    }

    private struct WorkerSession {
        let process: Process
        let workspace: URL
        let responseInputURL: URL
        let resultOutputURL: URL
        let request: WorkerRequest
    }

    private struct WorkerOutput: Codable {
        var request: WorkerRequest?
        var resultJSON: String?
        var error: String?

        init(request: WorkerRequest? = nil, resultJSON: String? = nil, error: String? = nil) {
            self.request = request
            self.resultJSON = resultJSON
            self.error = error
        }
    }

    /// 把任意字符串安全嵌入到 JS 源里（带引号）
    private static func jsString(_ s: String) -> String {
        // 用 JSONSerialization 编码字符串，保证转义正确
        if let data = try? JSONSerialization.data(
                withJSONObject: [s], options: [.fragmentsAllowed]),
           let arr = String(data: data, encoding: .utf8) {
            // arr = "[\"...\"]"，取中间那段
            var s = arr
            s.removeFirst(); s.removeLast()
            return s
        }
        return "\"\""
    }

    private static func headerMap(from value: JSValue?) -> [String: String] {
        guard let raw = value?.toDictionary() as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in raw {
            if let text = stringValue(value) {
                result[key] = text
            }
        }
        return result
    }

    private static func requestBodyData(from request: JSValue) throws -> Data? {
        for key in ["body", "data"] {
            guard let value = request.objectForKeyedSubscript(key),
                  !value.isUndefined,
                  !value.isNull else { continue }

            if let body = bodyData(from: value) {
                return body
            }
            throw RunError.badRequestBody
        }
        return nil
    }

    private static func bodyData(from value: JSValue) -> Data? {
        if value.isString {
            return value.toString()?.data(using: .utf8)
        }

        if let dict = value.toDictionary(),
           JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict) {
            return data
        }

        if let array = value.toArray(),
           JSONSerialization.isValidJSONObject(array),
           let data = try? JSONSerialization.data(withJSONObject: array) {
            return data
        }

        if value.isBoolean || value.isNumber {
            return value.toString()?.data(using: .utf8)
        }
        return nil
    }

    private static func parseBalance(providerName: String, result: [String: Any]) -> Balance {
        var remaining = doubleValue(result["remaining"])
        var used = doubleValue(result["used"])
        var total = doubleValue(result["total"])

        if remaining == nil, let used, let total { remaining = total - used }
        if used == nil, let remaining, let total { used = total - remaining }
        if total == nil, let remaining, let used { total = remaining + used }

        remaining = normalizeNearZero(remaining)
        used = normalizeNearZero(used)
        total = normalizeNearZero(total)

        let invalidMessage = stringValue(result["invalidMessage"]) ?? stringValue(result["message"])
        return Balance(
            providerName: providerName,
            remaining: remaining,
            used: used,
            total: total,
            unit: stringValue(result["unit"]),
            planName: stringValue(result["planName"]),
            isValid: boolValue(result["isValid"]) ?? true,
            invalidMessage: invalidMessage
        )
    }

    private static func normalizeNearZero(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return abs(value) < 0.000_001 ? 0 : value
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func boolValue(_ raw: Any?) -> Bool? {
        switch raw {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }
}
