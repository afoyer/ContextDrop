import Foundation

/// Friendly Mac model name ("MacBook Pro") shown under each avatar on other Macs.
enum MachineInfo {
    private static let cacheKey = "ContextDrop.deviceModel"

    static var cachedModel: String? { UserDefaults.standard.string(forKey: cacheKey) }

    /// Returns the cached value, or asks system_profiler once (≈1 s, off the main thread).
    static func modelName() async -> String {
        if let cached = cachedModel { return cached }
        let name = await Task.detached(priority: .utility) { () -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPHardwareDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = json["SPHardwareDataType"] as? [[String: Any]],
                   let machine = items.first?["machine_name"] as? String, !machine.isEmpty {
                    return machine
                }
            } catch {}
            return "Mac"
        }.value
        UserDefaults.standard.set(name, forKey: cacheKey)
        return name
    }
}
