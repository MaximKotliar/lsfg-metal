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
    /// Where CrossOver is usually installed.
    public static var defaultCrossOverApps: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appending(path: "Applications/CrossOver.app"), URL(fileURLWithPath: "/Applications/CrossOver.app")]
    }

    /// Bottle roots to scan, in order, without duplicates:
    /// 1. `LSFG_BOTTLES` (colon-separated),
    /// 2. the folders CrossOver itself uses: `CX_BOTTLE_PATH` from the environment or from an `[EnvironmentVariables]`
    ///    section, else `[CrossOver] BottlePath`, in the user's CrossOver.conf or the app's own (where tools such as
    ///    CXPatcher set `~/CXPBottles`),
    /// 3. CrossOver's default `~/Library/Application Support/CrossOver/Bottles`, and `~/CXPBottles`.
    public static func bottleRoots(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   crossOverApps: [URL] = defaultCrossOverApps,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var roots = paths(environment["LSFG_BOTTLES"] ?? "", home: home)
        roots += paths(environment["CX_BOTTLE_PATH"] ?? "", home: home)
        let confs = [home.appending(path: "Library/Application Support/CrossOver/CrossOver.conf")]
            + crossOverApps.map { $0.appending(path: "Contents/SharedSupport/CrossOver/etc/CrossOver.conf") }
        for conf in confs {
            guard let text = try? String(contentsOf: conf, encoding: .utf8) else { continue }
            let values = confValues(text)
            roots += paths(values["EnvironmentVariables"]?["CX_BOTTLE_PATH"] ?? "", home: home)
            roots += paths(values["CrossOver"]?["BottlePath"] ?? "", home: home)
        }
        roots.append(home.appending(path: "Library/Application Support/CrossOver/Bottles"))
        roots.append(home.appending(path: "CXPBottles"))
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// `"Key" = "Value"` entries of a CrossOver .conf file, by section (`;` lines are comments).
    static func confValues(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()); continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let unquote = { (s: String) in s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") ? String(s.dropFirst().dropLast()) : s }
            result[section, default: [:]][unquote(parts[0])] = unquote(parts[1])
        }
        return result
    }

    /// Colon-separated folders, with `~`, `${HOME}` and `${USER}` expanded.
    static func paths(_ list: String, home: URL) -> [URL] {
        list.split(separator: ":").map { item in
            var p = String(item).replacingOccurrences(of: "${HOME}", with: home.path)
                .replacingOccurrences(of: "${USER}", with: NSUserName())
            if p == "~" || p.hasPrefix("~/") { p = home.path + p.dropFirst() }
            return URL(fileURLWithPath: p)
        }
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
