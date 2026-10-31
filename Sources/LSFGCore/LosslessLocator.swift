import Foundation

/// Finds the user's own Steam copy of Lossless Scaling inside a CrossOver bottle.
///
/// lsfg-metal only supports Steam installs: we look for Steam's
/// `appmanifest_993090.acf` next to `common/<installdir>/Lossless.dll`.
public struct LosslessInstall: Sendable {
    public static let steamAppID = 993090

    public let bottle: URL
    public let manifest: URL
    public let dll: URL
    public let buildID: String?
}

public enum LosslessLocator {
    /// Bottle roots to scan. `LSFG_BOTTLES` (colon-separated) is checked first.
    public static func bottleRoots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots = (environment["LSFG_BOTTLES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        roots.append(home.appending(path: "Library/Application Support/CrossOver/Bottles"))
        roots.append(home.appending(path: "CXPBottles"))
        return roots
    }

    /// Every Lossless Scaling Steam install found across all bottles.
    public static func findAll(roots: [URL] = bottleRoots()) -> [LosslessInstall] {
        let fm = FileManager.default
        var found: [LosslessInstall] = []
        for root in roots {
            let bottles = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for bottle in bottles where fm.fileExists(atPath: bottle.appending(path: "drive_c").path) {
                for library in steamLibraries(in: bottle) {
                    // Bottles can link drives into each other; report each DLL once.
                    if let install = install(inLibrary: library, bottle: bottle),
                       !found.contains(where: { $0.dll.resolvingSymlinksInPath() == install.dll.resolvingSymlinksInPath() }) {
                        found.append(install)
                    }
                }
            }
        }
        return found
    }

    /// `steamapps` folders for every Steam library listed in a bottle.
    public static func steamLibraries(in bottle: URL) -> [URL] {
        let defaults = ["Program Files (x86)/Steam", "Program Files/Steam"].map {
            bottle.appending(path: "drive_c/\($0)/steamapps")
        }
        var libraries = defaults.filter { FileManager.default.fileExists(atPath: $0.path) }
        for steamapps in libraries {
            let vdf = steamapps.appending(path: "libraryfolders.vdf")
            guard let text = try? String(contentsOf: vdf, encoding: .utf8) else { continue }
            for winPath in vdfValues(for: "path", in: text) {
                if let mac = macPath(forWindowsPath: winPath, bottle: bottle) {
                    let lib = mac.appending(path: "steamapps")
                    if !libraries.contains(where: { $0.standardizedFileURL == lib.standardizedFileURL }) {
                        libraries.append(lib)
                    }
                }
            }
        }
        return libraries
    }

    static func install(inLibrary steamapps: URL, bottle: URL) -> LosslessInstall? {
        let manifest = steamapps.appending(path: "appmanifest_\(LosslessInstall.steamAppID).acf")
        guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { return nil }
        let installDir = vdfValues(for: "installdir", in: text).first ?? "Lossless Scaling"
        let dll = steamapps.appending(path: "common/\(installDir)/Lossless.dll")
        guard FileManager.default.fileExists(atPath: dll.path) else { return nil }
        return LosslessInstall(bottle: bottle, manifest: manifest, dll: dll,
                               buildID: vdfValues(for: "buildid", in: text).first)
    }

    /// Values of `"key" "value"` pairs in a Valve KeyValues file (flat scan is enough here).
    static func vdfValues(for key: String, in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: false)
            // "key"<ws>"value" splits into ["", key, ws, value, ""]
            if parts.count >= 5, parts[1].lowercased() == key.lowercased() {
                out.append(parts[3].replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return out
    }

    /// Maps `D:\SteamLibrary` to a macOS path through the bottle's `dosdevices` links.
    static func macPath(forWindowsPath path: String, bottle: URL) -> URL? {
        guard path.count >= 2, path.dropFirst().first == ":" else { return nil }
        let drive = path.prefix(1).lowercased()
        let rest = path.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
        let device = bottle.appending(path: "dosdevices/\(drive):")
        return device.resolvingSymlinksInPath().appending(path: String(rest.drop(while: { $0 == "/" })))
    }
}
