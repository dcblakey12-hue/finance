import Foundation
import Security

/// Direct OFX server client (OFXHome). Many banks no longer support this;
/// file import is the reliable path. This client exists so both modes work
/// where a bank still exposes OFX.
actor OFXClient {
    private let session: URLSession
    private let parser = OFXParser.shared

    init(session: URLSession = .shared) { self.session = session }

    func downloadStatement(profile: OFXProfile, password: String) async throws -> ParsedOFXFile {
        guard let url = URL(string: profile.ofxHomeURL) else {
            throw NSError(domain: "OFX", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid OFX URL"])
        }
        // Replace placeholder password safely by rebuilding body.
        let body = OFXRequestBuilder.buildStatementRequest(profile: profile)
            .replacingOccurrences(of: "***STORED_IN_KEYCHAIN***", with: password)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-ofx", forHTTPHeaderField: "Content-Type")
        req.setValue("application/x-ofx", forHTTPHeaderField: "Accept")
        req.httpBody = body.data(using: .utf8)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "OFX", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "OFX server returned HTTP \(http.statusCode). Your bank may have disabled direct OFX — use file import instead."])
        }
        return try parser.parse(data: data)
    }
}

/// Stores OFX passwords in macOS Keychain per profile. Never persists plaintext to disk.
final class KeychainStore: Sendable {
    static let shared = KeychainStore()
    private init() {}

    private func key(for profileID: UUID) -> String { "finance.ofx.password.\(profileID.uuidString)" }

    func savePassword(_ password: String, for profileID: UUID) throws {
        let service = "com.finance.app"
        let data = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key(for: profileID),
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Cannot save password to Keychain"])
        }
    }

    func password(for profileID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.finance.app",
            kSecAttrAccount as String: key(for: profileID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    func deletePassword(for profileID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.finance.app",
            kSecAttrAccount as String: key(for: profileID),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
