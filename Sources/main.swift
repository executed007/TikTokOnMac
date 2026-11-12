import Foundation

let usage = """
usage: catalyst-runner install <app.ipa | App.app> [--library <dir>] [--run]
       catalyst-runner list [--library <dir>]
       catalyst-runner run <bundle identifier> [--library <dir>]
       catalyst-runner uninstall <bundle identifier> [--delete-data] [--library <dir>]
       catalyst-runner export <bundle identifier> [--to <dir>] [--library <dir>]
       catalyst-runner inspect <mach-o file>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("catalyst-runner: \(message)\n".utf8))
    exit(1)
}

func version(_ value: UInt32) -> String { "\(value >> 16).\((value >> 8) & 0xff)" }

var arguments = Array(CommandLine.arguments.dropFirst())
var installer = Installer()
if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
    installer.library = URL(fileURLWithPath: arguments[index + 1])
    arguments.removeSubrange(index...index + 1)
}
var exportFolder = Installer.defaultApplications
if let index = arguments.firstIndex(of: "--to"), index + 1 < arguments.count {
    exportFolder = URL(fileURLWithPath: arguments[index + 1])
    arguments.removeSubrange(index...index + 1)
}
let runAfter = arguments.contains("--run")
arguments.removeAll { $0 == "--run" }
let deleteData = arguments.contains("--delete-data")
arguments.removeAll { $0 == "--delete-data" }

do {
    switch (arguments.first, arguments.count) {
    case ("install", 2):
        let app = try installer.install(URL(fileURLWithPath: arguments[1]))
        print("Installed \(app.path)")
        if runAfter { try installer.launch(app) }
    case ("list", 1):
        installer.installed().forEach { print($0.deletingPathExtension().lastPathComponent) }
    case ("run", 2):
        guard let app = installer.installed().first(where: { $0.deletingPathExtension().lastPathComponent == arguments[1] }) else {
            fail("\(arguments[1]) is not installed")
        }
        try installer.launch(app)
    case ("uninstall", 2):
        guard let app = installer.installed().first(where: { $0.deletingPathExtension().lastPathComponent == arguments[1] }) else {
            fail("\(arguments[1]) is not installed")
        }
        try installer.uninstall(app, deleteData: deleteData)
        print(deleteData ? "Uninstalled \(arguments[1]) and deleted its data" : "Uninstalled \(arguments[1]); its data was kept")
    case ("export", 2):
        guard let app = installer.installed().first(where: { $0.deletingPathExtension().lastPathComponent == arguments[1] }) else {
            fail("\(arguments[1]) is not installed")
        }
        print("Added \(try installer.addToApplications(app, folder: exportFolder).path)")
    case ("inspect", 2):
        let thin = try MachO.thinned(try Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        if let build = try MachO.buildVersion(thin) {
            print("platform \(build.platform)\(build.platform == MachO.platformMacCatalyst ? " (Mac Catalyst)" : "") minos \(version(build.minOS)) sdk \(version(build.sdk))")
        } else {
            print("no LC_BUILD_VERSION")
        }
        print("encrypted: \(try MachO.isEncrypted(thin))")
    default:
        fail(usage)
    }
} catch {
    fail("\(error)")
}
