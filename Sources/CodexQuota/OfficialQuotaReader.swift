import Foundation

/// 直接使用 Codex 官方登录态请求最新额度，避免只能等 session 文件落盘。
enum OfficialQuotaReader {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private static let authFileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/auth.json", isDirectory: false)
    }()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    static func loadLatest() async -> QuotaSnapshot? {
        guard let auth = loadAuthContext() else { return nil }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accountId = auth.accountId, !accountId.isEmpty {
            // 显式绑定当前 Codex 账号，避免多账号机器读到默认账号的额度。
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue(accountId, forHTTPHeaderField: "openai-account-id")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return parseSnapshot(from: data, capturedAt: Date())
        } catch {
            return nil
        }
    }

    static func parseSnapshot(from data: Data, capturedAt: Date = Date()) -> QuotaSnapshot? {
        let decoder = JSONDecoder()
        guard let usage = try? decoder.decode(UsageResponse.self, from: data) else { return nil }

        let primary = makeWindow(from: usage.rateLimit?.primaryWindow, capturedAt: capturedAt)
        let secondary = makeWindow(from: usage.rateLimit?.secondaryWindow, capturedAt: capturedAt)
        guard primary != nil || secondary != nil else { return nil }

        let limits = RateLimits(
            limitId: nil,
            limitName: nil,
            individualLimit: nil,
            primary: primary,
            secondary: secondary,
            planType: usage.planType
        )
        return QuotaSnapshot(limits: limits, capturedAt: capturedAt)
    }

    private static func makeWindow(from source: RemoteWindow?, capturedAt: Date) -> RateWindow? {
        guard let source else { return nil }
        let resetsAt: TimeInterval
        if let resetAt = source.resetAt {
            resetsAt = resetAt
        } else if let resetAfterSeconds = source.resetAfterSeconds {
            resetsAt = capturedAt.addingTimeInterval(TimeInterval(resetAfterSeconds)).timeIntervalSince1970
        } else {
            return nil
        }

        return RateWindow(
            usedPercent: source.usedPercent,
            windowMinutes: max(0, source.limitWindowSeconds / 60),
            resetsAt: resetsAt
        )
    }

    private static func loadAuthContext() -> AuthContext? {
        guard let data = try? Data(contentsOf: authFileURL),
              let authFile = try? JSONDecoder().decode(AuthFile.self, from: data),
              let accessToken = authFile.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }

        let accountId = authFile.tokens?.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AuthContext(
            accessToken: accessToken,
            accountId: accountId?.isEmpty == true ? nil : accountId
        )
    }
}

private extension OfficialQuotaReader {
    struct AuthContext {
        let accessToken: String
        let accountId: String?
    }

    struct AuthFile: Decodable {
        let tokens: Tokens?
    }

    struct Tokens: Decodable {
        let accessToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }

    struct UsageResponse: Decodable {
        let planType: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: RemoteWindow?
        let secondaryWindow: RemoteWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct RemoteWindow: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Int
        let resetAt: TimeInterval?
        let resetAfterSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
            case resetAfterSeconds = "reset_after_seconds"
        }
    }
}
