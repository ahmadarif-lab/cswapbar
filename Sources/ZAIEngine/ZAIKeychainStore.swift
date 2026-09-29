import Foundation
import ProviderKit

struct ZAIKeychainStore {
    private let keychain = ProviderKeychain(service: "cswapbar-zai")

    func getAPIKey() throws -> String? { try keychain.getPassword() }
    func setAPIKey(_ key: String) throws { try keychain.setPassword(key) }
    func deleteAPIKey() throws { try keychain.deletePassword() }
}
