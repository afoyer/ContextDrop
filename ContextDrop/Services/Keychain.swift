import Foundation
import Security

/// Minimal generic-password Keychain wrapper for the OpenAI API key.
enum Keychain {
    private static let service = "edu.cmu.hackathon.ContextDrop"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum OpenAISettings {
    static let keyAccount = "openai-api-key"
    static let modelDefaultsKey = "ContextDrop.openAIModel"
    static let defaultModel = "gpt-4.1-mini"

    /// In-memory copy of the Keychain item. Keychain reads can block on a system approval prompt
    /// (every ad-hoc rebuild is a "new app" to the Keychain), so they never happen on the main thread.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var stored: String?
        var loaded = false
        var loading: Task<String?, Never>?
    }
    private static let cache = Cache()

    /// Loads the key off the main thread once at launch.
    static func preload() async {
        let pending: Task<String?, Never>? = cache.lock.withLock {
            if cache.loaded { return nil }
            if let loading = cache.loading { return loading }
            let task = Task.detached(priority: .userInitiated) {
                Keychain.read(keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            cache.loading = task
            return task
        }
        guard let pending else { return }
        let value = await pending.value
        cache.lock.withLock {
            if !cache.loaded {
                cache.stored = (value?.isEmpty ?? true) ? nil : value
                cache.loaded = true
            }
            cache.loading = nil
        }
    }

    static var hasStoredKey: Bool {
        cache.lock.lock(); defer { cache.lock.unlock() }
        return cache.stored != nil
    }

    static var isLoaded: Bool {
        cache.lock.lock(); defer { cache.lock.unlock() }
        return cache.loaded
    }

    /// Saves (or removes, when empty) the key in the Keychain and the in-memory cache.
    @discardableResult
    static func store(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = Keychain.write(trimmed, account: keyAccount)
        cache.lock.lock(); cache.stored = trimmed.isEmpty ? nil : trimmed; cache.loaded = true; cache.lock.unlock()
        return ok
    }

    /// Keychain (cached) first, then the environment (dev fallback when launched from a terminal).
    static func apiKey() -> String? {
        cache.lock.lock(); let stored = cache.stored; cache.lock.unlock()
        if let stored { return stored }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    static var model: String {
        let stored = UserDefaults.standard.string(forKey: modelDefaultsKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? defaultModel : stored
    }
}
