import Foundation
import NetworkExtension

struct LumixWiFiConnector {
    func join(using qrPayload: String) async throws -> String {
        let credentials = try LumixWiFiCredentials(qrPayload: qrPayload)
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

    private init(ssid: String, password: String?, isWEP: Bool) {
        self.ssid = ssid
        self.password = password
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

        throw LumixWiFiError.unsupportedQRCode
    }

    private static func parseStandardWiFiPayload(_ payload: String) -> Self? {
        guard let prefixRange = payload.range(of: "WIFI:", options: .caseInsensitive) else { return nil }
        let body = String(payload[prefixRange.upperBound...])
        var fields: [String: String] = [:]

        for component in splitUnescaped(body, separator: ";") {
            guard let (key, value) = splitKeyValue(component) else { continue }
            fields[key.uppercased()] = unescape(value)
        }

        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        let security = fields["T"]?.uppercased() ?? "WPA"
        return Self(
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
        return Self(ssid: ssid, password: password, isWEP: values["type"]?.uppercased() == "WEP")
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

private enum LumixWiFiError: LocalizedError {
    case unsupportedQRCode

    var errorDescription: String? {
        "This camera QR format is not recognized yet. Join the displayed SSID manually in iPhone Wi-Fi Settings."
    }
}
