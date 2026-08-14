import Foundation
import Security

struct RememberedCameraNetwork: Codable, Equatable {
    let ssid: String
    let password: String?
    let isWEP: Bool

    init(credentials: LumixWiFiCredentials) {
        ssid = credentials.ssid
        password = credentials.password
        isWEP = credentials.isWEP
    }

    var credentials: LumixWiFiCredentials {
        get throws {
            try LumixWiFiCredentials(ssid: ssid, password: password, isWEP: isWEP)
        }
    }
}

protocol CameraNetworkStoring {
    func load() throws -> RememberedCameraNetwork?
    func save(_ network: RememberedCameraNetwork) throws
    func remove() throws
}

struct KeychainCameraNetworkStore: CameraNetworkStoring {
    private let service: String
    private let account: String

    init(
        service: String = "com.web3.gm1sync.camera-network",
        account: String = "remembered-camera-v1"
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> RememberedCameraNetwork? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CameraNetworkStoreError.keychain(status)
        }

        do {
            return try JSONDecoder().decode(RememberedCameraNetwork.self, from: data)
        } catch {
            throw CameraNetworkStoreError.invalidRecord
        }
    }

    func save(_ network: RememberedCameraNetwork) throws {
        let data = try JSONEncoder().encode(network)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CameraNetworkStoreError.keychain(updateStatus)
        }

        var addition = itemQuery
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addition[kSecValueData as String] = data
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CameraNetworkStoreError.keychain(addStatus)
        }
    }

    func remove() throws {
        let status = SecItemDelete(itemQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CameraNetworkStoreError.keychain(status)
        }
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private var readQuery: [String: Any] {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}

enum CameraNetworkStoreError: LocalizedError {
    case invalidRecord
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            "The remembered camera network could not be read. Scan the camera QR code again."
        case .keychain:
            "The camera network could not be saved securely."
        }
    }
}
