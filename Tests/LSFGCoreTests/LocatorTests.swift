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
