import CryptoKit
import Foundation
import NetworkExtension
import Security

struct LumixWiFiConnector {
    func join(using qrPayload: String) async throws -> String {
        let credentials = try LumixWiFiCredentials(qrPayload: qrPayload)
        return try await join(using: credentials)
    }

    func join(ssid: String, password: String?, isWEP: Bool = false) async throws -> String {
        try await join(using: LumixWiFiCredentials(ssid: ssid, password: password, isWEP: isWEP))
    }

    private func join(using credentials: LumixWiFiCredentials) async throws -> String {
        let configuration: NEHotspotConfiguration

        if let password = credentials.password, !password.isEmpty {
            configuration = NEHotspotConfiguration(
                ssid: credentials.ssid,
                passphrase: password,
                isWEP: credentials.isWEP
            )
        } else {
            configuration = NEHotspotConfiguration(ssid: credentials.ssid)
        }

        configuration.joinOnce = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == NEHotspotConfigurationErrorDomain,
                       nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume()
                }
            }
        }

        return credentials.ssid
    }
}

struct LumixWiFiCredentials {
    let ssid: String
    let password: String?
    let isWEP: Bool

    init(ssid: String, password: String?, isWEP: Bool) throws {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty else { throw LumixWiFiError.missingSSID }
        self.ssid = trimmedSSID
        self.password = password?.isEmpty == true ? nil : password
        self.isWEP = isWEP
    }

    init(qrPayload: String) throws {
        if let standard = Self.parseStandardWiFiPayload(qrPayload) {
            self = standard
            return
        }

        if let queryBased = Self.parseURLQueryPayload(qrPayload) {
            self = queryBased
            return
        }

        throw LumixWiFiError.unsupportedQRCode(reference: LumixQRCodeFingerprint.reference(for: qrPayload))
    }

    private static func parseStandardWiFiPayload(_ payload: String) -> Self? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefixRange = trimmed.range(of: "WIFI:", options: [.anchored, .caseInsensitive]) else { return nil }
        let body = String(trimmed[prefixRange.upperBound...])
        var fields: [String: String] = [:]

        for component in splitUnescaped(body, separator: ";") {
            guard let (key, value) = splitKeyValue(component) else { continue }
            fields[key.uppercased()] = unescape(value)
        }

        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        let security = fields["T"]?.uppercased() ?? "WPA"
        if security != "NOPASS", fields["P"]?.isEmpty != false { return nil }
        return try? Self(
            ssid: ssid,
            password: security == "NOPASS" ? nil : fields["P"],
            isWEP: security == "WEP"
        )
    }

    private static func parseURLQueryPayload(_ payload: String) -> Self? {
        guard let components = URLComponents(string: payload),
              let queryItems = components.queryItems else { return nil }
        let values = queryItems.reduce(into: [String: String]()) { result, item in
            guard let value = item.value else { return }
            result[item.name.lowercased()] = value
        }
        let ssid = values["ssid"] ?? values["network"]
        guard let ssid, !ssid.isEmpty else { return nil }
        let password = values["password"] ?? values["passphrase"] ?? values["pwd"] ?? values["key"]
        return try? Self(ssid: ssid, password: password, isWEP: values["type"]?.uppercased() == "WEP")
    }

    private static func splitUnescaped(_ value: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false

        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        if escaped { current.append("\\") }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func splitKeyValue(_ value: String) -> (String, String)? {
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == ":" {
                return (String(value[..<index]), String(value[value.index(after: index)...]))
            }
        }
        return nil
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}

enum LumixWiFiError: LocalizedError {
    case missingSSID
    case unsupportedQRCode(reference: String)

    var errorDescription: String? {
        switch self {
        case .missingSSID:
            return "Enter the Wi-Fi network name shown by the camera."
        case let .unsupportedQRCode(reference):
            return "This camera QR format is not recognized yet (reference \(reference)). Enter the displayed network details manually."
        }
    }
}

enum LumixQRCodeFingerprint {
    private static let key = SymmetricKey(data: loadOrCreateKey())

    static func reference(for payload: String) -> String {
        reference(for: payload, key: key)
    }

    static func reference(for payload: String, key: SymmetricKey) -> String {
        let digest = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let prefix = digest.prefix(5).map { String(format: "%02X", $0) }.joined()
        return "\(prefix)-\(payload.utf8.count)"
    }

    private static func loadOrCreateKey() -> Data {
        let service = "com.web3.gm1sync.qr-fingerprint"
        let account = "local-reference-key-v1"
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var existing: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &existing) == errSecSuccess,
           let data = existing as? Data,
           data.count == 32 {
            return data
        }

        var keyData = Data(count: 32)
        let randomStatus = keyData.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, address)
        }
        if randomStatus != errSecSuccess {
            keyData = Data(SHA256.hash(data: Data(UUID().uuidString.utf8)))
        }

        let addition: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: keyData
        ]
        let addStatus = SecItemAdd(addition as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            existing = nil
            if SecItemCopyMatching(lookup as CFDictionary, &existing) == errSecSuccess,
               let data = existing as? Data,
               data.count == 32 {
                return data
            }
        }

        return keyData
    }
}
