import Foundation

struct CodexAccountProfile: Codable, Equatable {
    let accountId: String?
    let name: String?
    let email: String?

    var displayText: String? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedName, !trimmedName.isEmpty,
           let trimmedEmail, !trimmedEmail.isEmpty,
           trimmedName.caseInsensitiveCompare(trimmedEmail) != .orderedSame {
            return "\(trimmedName) (\(trimmedEmail))"
        }
        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }
        if let trimmedEmail, !trimmedEmail.isEmpty {
            return trimmedEmail
        }
        return nil
    }
}

enum CodexAccountProfileReader {
    private static let authFileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex/auth.json", isDirectory: false)
    }()

    static var watchRootPath: String {
        authFileURL.deletingLastPathComponent().path
    }

    static var authModifiedAt: Date? {
        try? authFileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func loadCurrent() -> CodexAccountProfile? {
        guard let data = try? Data(contentsOf: authFileURL),
              let authFile = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            return nil
        }

        let accountId = trimmed(authFile.tokens?.accountId)
        let claims = decodeJWTClaims(from: authFile.tokens?.idToken)

        let name = trimmed(stringValue(for: "name", in: claims))
        let email = trimmed(stringValue(for: "email", in: claims))

        if accountId == nil, name == nil, email == nil {
            return nil
        }
        return CodexAccountProfile(accountId: accountId, name: name, email: email)
    }

    private static func decodeJWTClaims(from token: String?) -> [String: Any]? {
        guard let token,
              !token.isEmpty else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingCount = (4 - payload.count % 4) % 4
        if paddingCount > 0 {
            payload += String(repeating: "=", count: paddingCount)
        }

        guard let payloadData = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func stringValue(for key: String, in object: [String: Any]?) -> String? {
        object?[key] as? String
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private extension CodexAccountProfileReader {
    struct AuthFile: Decodable {
        let tokens: Tokens?
    }

    struct Tokens: Decodable {
        let idToken: String?
        let accountId: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accountId = "account_id"
        }
    }
}
