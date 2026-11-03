import Foundation
import Testing
@testable import LSFGCore

@Test func parsesVDFValues() {
    let text = """
    "libraryfolders"
    {
        "0"
        {
            "path"		"C:\\\\Program Files (x86)\\\\Steam"
        }
        "1"
        {
            "path"		"D:\\\\SteamLibrary"
        }
    }
    """
    #expect(LosslessLocator.vdfValues(for: "path", in: text) == [#"C:\Program Files (x86)\Steam"#, #"D:\SteamLibrary"#])
}

@Test func findsSteamInstallInFakeBottle() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "lsfg-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let steamapps = root.appending(path: "Bottle/drive_c/Program Files (x86)/Steam/steamapps")
    try fm.createDirectory(at: steamapps.appending(path: "common/Lossless Scaling"), withIntermediateDirectories: true)
    try Data("\"AppState\"\n{\n\t\"installdir\"\t\t\"Lossless Scaling\"\n\t\"buildid\"\t\t\"42\"\n}\n".utf8)
        .write(to: steamapps.appending(path: "appmanifest_993090.acf"))
    try Data("MZ".utf8).write(to: steamapps.appending(path: "common/Lossless Scaling/Lossless.dll"))

    let found = LosslessLocator.findAll(roots: [root])
    #expect(found.count == 1)
    #expect(found.first?.buildID == "42")
}

@Test func noManifestMeansNoInstall() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "lsfg-test-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let common = root.appending(path: "Bottle/drive_c/Program Files (x86)/Steam/steamapps/common/Lossless Scaling")
    try fm.createDirectory(at: common, withIntermediateDirectories: true)
    try Data("MZ".utf8).write(to: common.appending(path: "Lossless.dll"))
    #expect(LosslessLocator.findAll(roots: [root]).isEmpty)
}

@Test func readsImportsOfAWindowsExecutable() throws {
    // The hook's own test program imports kernel32 only.
    let exe = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../hook/build/vertest.exe")
    guard let data = try? Data(contentsOf: exe) else { return } // hook not built: nothing to check
    let info = try PEFile.info(of: data)
    #expect(info.is64Bit)
    #expect(info.imports == ["kernel32.dll"])
}

@Test func bottleRootsFollowCrossOverConfig() throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory.appending(path: "lsfg-home-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: home) }
    // the user's CrossOver.conf sets BottlePath; an app (like a CXPatcher build) sets CX_BOTTLE_PATH
    let userConf = home.appending(path: "Library/Application Support/CrossOver/CrossOver.conf")
    try fm.createDirectory(at: userConf.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(";; \"BottlePath\" = \"/ignored\"\n[CrossOver]\n\"BottlePath\" = \"~/MyBottles\"\n".utf8).write(to: userConf)
    let app = home.appending(path: "Applications/CrossOver.app")
    let appConf = app.appending(path: "Contents/SharedSupport/CrossOver/etc/CrossOver.conf")
    try fm.createDirectory(at: appConf.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("[EnvironmentVariables]\n\"CX_BOTTLE_PATH\"=\"/Users/${USER}/CXPBottles\"\n".utf8).write(to: appConf)

    let roots = LosslessLocator.bottleRoots(environment: ["LSFG_BOTTLES": "/extra"], crossOverApps: [app], home: home).map(\.path)
    #expect(roots == ["/extra", home.appending(path: "MyBottles").path, "/Users/\(NSUserName())/CXPBottles",
                      home.appending(path: "Library/Application Support/CrossOver/Bottles").path, home.appending(path: "CXPBottles").path])
}
