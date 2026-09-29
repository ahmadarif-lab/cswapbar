import Foundation
import ProviderKit

struct DeepSeekKeychainStore {
    private let keychain = ProviderKeychain(service: "cswapbar-deepseek")

    func getAPIKey() throws -> String? { try keychain.getPassword() }
    func setAPIKey(_ key: String) throws { try keychain.setPassword(key) }
    func deleteAPIKey() throws { try keychain.deletePassword() }
}
