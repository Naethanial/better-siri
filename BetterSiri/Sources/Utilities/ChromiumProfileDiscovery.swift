import Foundation

struct ChromiumProfile: Identifiable, Hashable, Sendable {
    let dirName: String
    let displayName: String

    var id: String { dirName }
}

enum ChromiumProfileDiscovery {
    static func discoverProfiles(userDataDir: URL) async -> [ChromiumProfile] {
        await Task.detached(priority: .utility) {
            let infoCacheNames = readProfileNamesFromLocalState(userDataDir: userDataDir)
            let dirs = listProfileDirectories(userDataDir: userDataDir)

            let profiles: [ChromiumProfile] = dirs.map { dirName in
                let display = infoCacheNames[dirName] ?? dirName
                return ChromiumProfile(dirName: dirName, displayName: display)
            }

            return sortProfiles(profiles)
        }.value
    }

    private static func listProfileDirectories(userDataDir: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: userDataDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var dirs: [String] = []
        for url in items {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { continue }

            let name = url.lastPathComponent
            if name == "Default" || name.hasPrefix("Profile ") {
                dirs.append(name)
            }
        }

        // Always include Default as a reasonable choice even if it doesn't exist yet.
        if !dirs.contains("Default") {
            dirs.append("Default")
        }

        return dirs
    }

    private static func readProfileNamesFromLocalState(userDataDir: URL) -> [String: String] {
        let localStateURL = userDataDir.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: localStateURL) else { return [:] }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        guard let profile = json["profile"] as? [String: Any] else { return [:] }
        guard let infoCache = profile["info_cache"] as? [String: Any] else { return [:] }

        var result: [String: String] = [:]
        for (dirName, value) in infoCache {
            guard let dict = value as? [String: Any] else { continue }
            if let name = dict["name"] as? String, !name.isEmpty {
                result[dirName] = name
            }
        }
        return result
    }

    private static func sortProfiles(_ profiles: [ChromiumProfile]) -> [ChromiumProfile] {
        func numericSuffix(_ s: String) -> Int? {
            guard s.hasPrefix("Profile ") else { return nil }
            return Int(s.replacingOccurrences(of: "Profile ", with: ""))
        }

        return profiles.sorted { a, b in
            if a.dirName == "Default" { return true }
            if b.dirName == "Default" { return false }

            let an = numericSuffix(a.dirName)
            let bn = numericSuffix(b.dirName)
            if let an, let bn { return an < bn }
            if an != nil { return true }
            if bn != nil { return false }
            return a.dirName < b.dirName
        }
    }
}

