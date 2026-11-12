import Foundation

/// Per-app options. The helper library reads this file at launch; `sandbox` is applied
/// when the app is signed, so changing it needs a reinstall.
struct AppSettings: Codable, Equatable {
    var hideTitleBar = true
    var lockCameraOrientation = true
    var cropCameraToPortrait = true
    var windowSize = "default"          // "default", "phone" or "tablet"
    var arrowKeysScrollFeed = true
    var volume = 1.0                    // 0...1, scales what the app plays
    var showVolumeButton = true
    var sandbox = true

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CatalystRunner/Settings")

    static func file(for identifier: String) -> URL { folder.appendingPathComponent("\(identifier).plist") }

    static func load(_ identifier: String) -> AppSettings {
        guard let data = try? Data(contentsOf: file(for: identifier)),
              let settings = try? PropertyListDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    func save(_ identifier: String) throws {
        try FileManager.default.createDirectory(at: AppSettings.folder, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: AppSettings.file(for: identifier))
        // Running apps pick up the change (the volume applies straight away).
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("dev.catalyst-runner.settings-changed" as CFString), nil, nil, true)
    }

    // Keys added later must not make older files unreadable.
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hideTitleBar = try values.decodeIfPresent(Bool.self, forKey: .hideTitleBar) ?? true
        lockCameraOrientation = try values.decodeIfPresent(Bool.self, forKey: .lockCameraOrientation) ?? true
        cropCameraToPortrait = try values.decodeIfPresent(Bool.self, forKey: .cropCameraToPortrait) ?? true
        windowSize = try values.decodeIfPresent(String.self, forKey: .windowSize) ?? "default"
        arrowKeysScrollFeed = try values.decodeIfPresent(Bool.self, forKey: .arrowKeysScrollFeed) ?? true
        volume = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        showVolumeButton = try values.decodeIfPresent(Bool.self, forKey: .showVolumeButton) ?? true
        sandbox = try values.decodeIfPresent(Bool.self, forKey: .sandbox) ?? true
    }
}

/// Installs a decrypted iOS app (.ipa or .app) so macOS on Apple silicon will launch it.
/// Same pipeline as PlayCover's installer (unzip, copy, convert Mach-Os, sign), minus
/// PlayTools injection. See EVIDENCE.md.
struct Installer {
    enum Failure: Error, CustomStringConvertible {
        case noAppInPayload, missingInfo(String), tool(String, Int32, String), dataNotRemoved([String])

        var description: String {
            switch self {
            case .noAppInPayload: "no .app found in the archive's Payload folder"
            case .missingInfo(let key): "Info.plist is missing \(key)"
            case .dataNotRemoved(let names): "the app was removed, but macOS did not allow deleting some of its data: \(names.joined(separator: ", "))"
            case .tool(let path, let status, let output): "\(path) exited with \(status): \(output)"
            }
        }
    }

    static let defaultLibrary = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CatalystRunner/Applications")

    static let entitlements = [
        "com.apple.security.app-sandbox",
        "com.apple.security.network.client",
        "com.apple.security.network.server",
        "com.apple.security.device.camera",
        "com.apple.security.device.audio-input",
        "com.apple.security.device.microphone",
        "com.apple.security.device.bluetooth",
        "com.apple.security.device.usb",
        "com.apple.security.personal-information.location",
        "com.apple.security.personal-information.addressbook",
        "com.apple.security.personal-information.calendars",
        "com.apple.security.personal-information.photos-library",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.print",
    ]

    static let cameraEffectKeys = [
        "NSCameraPortraitEffectEnabled",
        "NSCameraBackgroundReplacementEnabled",
        "NSCameraStudioLightEnabled",
        "NSCameraReactionEffectsEnabled",
        "NSCameraReactionEffectGesturesEnabledDefault",
    ]

    /// RunnerShim.dylib, shipped in the app's Resources or next to the command-line tool.
    static let bundledShim: URL? = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()]
        .compactMap { $0?.appendingPathComponent("RunnerShim.dylib") }
        .first { FileManager.default.fileExists(atPath: $0.path) }

    var library = Installer.defaultLibrary
    var shim = Installer.bundledShim
    var log: (String) -> Void = { print($0) }
    private let files = FileManager.default

    /// Returns the installed bundle, named `<bundle identifier>.app` inside `library`.
    @discardableResult
    func install(_ source: URL) throws -> URL {
        let scratch = files.temporaryDirectory.appendingPathComponent("catalyst-runner-\(UUID().uuidString)")
        defer { try? files.removeItem(at: scratch) }

        var bundle = source
        if source.pathExtension.lowercased() == "ipa" {
            log("Extracting app from .ipa file...")
            try files.createDirectory(at: scratch, withIntermediateDirectories: true)
            try run("/usr/bin/unzip", ["-q", source.path, "-d", scratch.path])
            let payload = scratch.appendingPathComponent("Payload")
            let apps = (try? files.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
            guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw Failure.noAppInPayload }
            bundle = app
        }

        let info = try plist(bundle.appendingPathComponent("Info.plist"))
        guard let identifier = info["CFBundleIdentifier"] as? String else { throw Failure.missingInfo("CFBundleIdentifier") }
        guard let executable = info["CFBundleExecutable"] as? String else { throw Failure.missingInfo("CFBundleExecutable") }

        // Convert a private copy first so a failure never leaves a half-installed app.
        log("Copying app...")
        let staged = scratch.appendingPathComponent("staged/\(identifier).app")
        try files.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.copyItem(at: bundle, to: staged)

        // macOS adds its own camera effects (Portrait blur, reactions, Studio Light) to iOS apps.
        // Their teardown crashes inside the system frameworks, so opt the app out of them.
        let infoURL = staged.appendingPathComponent("Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        if var edited = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), options: [], format: &format) as? [String: Any] {
            for key in Installer.cameraEffectKeys { edited[key] = false }
            // A Mac-style icon, so the Dock, Finder, Launchpad and Spotlight show the real one.
            if let png = MacIcon.sourcePNG(in: staged, info: edited) {
                do {
                    try MacIcon.makeICNS(from: png, to: staged.appendingPathComponent("AppIcon.icns"), scratch: scratch)
                    edited["CFBundleIconFile"] = "AppIcon"
                } catch {
                    log("Could not build a Mac icon; keeping the default one")
                }
            }
            if edited["LSApplicationCategoryType"] == nil {
                edited["LSApplicationCategoryType"] = "public.app-category.entertainment"
            }
            try PropertyListSerialization.data(fromPropertyList: edited, format: format, options: 0).write(to: infoURL)
        }

        var binaries = try machOFiles(in: staged)
        guard binaries.contains(where: { $0.lastPathComponent == executable }) else { throw Failure.missingInfo("a Mach-O at \(executable)") }
        for binary in binaries {
            log("Converting MachO at \(binary.pathComponents.dropFirst(staged.pathComponents.count).joined(separator: "/"))")
            let converted = try MachO.convertedToCatalyst(try Data(contentsOf: binary))
            try converted.write(to: binary)          // non-atomic: keeps the executable bit
        }

        if let shim, files.fileExists(atPath: shim.path) {
            // Best effort: an app whose header has no spare room simply runs without the helper.
            let main = staged.appendingPathComponent(executable)
            if let patched = try? MachO.addingDylib(try Data(contentsOf: main), path: "@executable_path/Frameworks/RunnerShim.dylib") {
                let frameworks = staged.appendingPathComponent("Frameworks")
                try files.createDirectory(at: frameworks, withIntermediateDirectories: true)
                let copy = frameworks.appendingPathComponent("RunnerShim.dylib")
                if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
                try files.copyItem(at: shim, to: copy)
                try patched.write(to: main)
                binaries.append(copy)
            } else {
                log("No room to add the helper library; continuing without it")
            }
        }

        // Archives made without Unix permissions leave the executable unrunnable.
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.appendingPathComponent(executable).path)

        log("Signing app...")
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        // `codesign --deep` skips code it does not expect in an iOS-layout bundle, which leaves
        // converted binaries with stale signatures. Sign every one explicitly, innermost first.
        var targets: [URL] = []
        for binary in binaries.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            let parent = binary.deletingLastPathComponent()
            let isBundleExecutable = ["framework", "appex", "app", "xctest", "bundle"].contains(parent.pathExtension)
                && parent.deletingPathExtension().lastPathComponent == binary.lastPathComponent
            let target = isBundleExecutable ? parent : binary
            if target.path != staged.path, !targets.contains(target) { targets.append(target) }
        }
        for target in targets {
            try run("/usr/bin/codesign", ["--force", "--sign", "-", target.path])
        }
        // Sandbox the app, as PlayCover does. It gets its own container instead of the real
        // home folder, so macOS never asks for Documents/Desktop/Downloads access, and the
        // camera, microphone and other answers the user gives are remembered.
        var entitlementValues: [String: Any] = [:]
        if AppSettings.load(identifier).sandbox {
            for key in Installer.entitlements { entitlementValues[key] = true }
            // Lets the sandboxed helper library read this app's settings, and save the volume back.
            entitlementValues["com.apple.security.temporary-exception.files.home-relative-path.read-write"] =
                ["/Library/Application Support/CatalystRunner/Settings/"]
        }
        let entitlements = scratch.appendingPathComponent("entitlements.plist")
        try PropertyListSerialization.data(fromPropertyList: entitlementValues, format: .xml, options: 0).write(to: entitlements)
        try run("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, staged.path])

        log("Adding app to library...")
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        let destination = library.appendingPathComponent(staged.lastPathComponent)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: staged, to: destination)
        if let exported = exportedCopy(of: destination) {
            log("Updating \(exported.lastPathComponent)...")
            try copyClone(destination, to: exported)
        }
        return destination
    }

    // MARK: - Standalone copies

    static let defaultApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    private static let exportsFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CatalystRunner/Exports.plist")

    private func exports() -> [String: String] {
        (try? PropertyListSerialization.propertyList(from: Data(contentsOf: Installer.exportsFile), format: nil)) as? [String: String] ?? [:]
    }

    private func saveExports(_ value: [String: String]) throws {
        try files.createDirectory(at: Installer.exportsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: Installer.exportsFile)
    }

    /// The copy made by `addToApplications`, if it still exists.
    func exportedCopy(of app: URL) -> URL? {
        guard let path = exports()[app.deletingPathExtension().lastPathComponent], files.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Puts a standalone copy of the app, named after it, in `folder` (~/Applications by default)
    /// so it can be opened from Launchpad, Spotlight and the Dock without Catalyst Runner.
    /// The copy is an APFS clone, so it takes no extra disk space, and it shares the app's data.
    @discardableResult
    func addToApplications(_ app: URL, folder: URL = Installer.defaultApplications) throws -> URL {
        let info = try plist(app.appendingPathComponent("Info.plist"))
        let raw = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent
        let name = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destination = folder.appendingPathComponent("\(name).app")
        if let previous = exportedCopy(of: app), previous != destination { try? files.trashItem(at: previous, resultingItemURL: nil) }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        try copyClone(app, to: destination)
        var all = exports()
        all[app.deletingPathExtension().lastPathComponent] = destination.path
        try saveExports(all)
        // Let Launchpad and Spotlight know about it straight away.
        _ = try? run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                     ["-f", destination.path])
        return destination
    }

    /// Moves the standalone copy to the Trash. The app stays installed in Catalyst Runner.
    func removeFromApplications(_ app: URL) throws {
        if let copy = exportedCopy(of: app) { try files.trashItem(at: copy, resultingItemURL: nil) }
        var all = exports()
        all[app.deletingPathExtension().lastPathComponent] = nil
        try saveExports(all)
    }

    private func copyClone(_ source: URL, to destination: URL) throws {
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try run("/bin/cp", ["-cR", source.path, destination.path])     // -c: APFS clone, no extra space
    }

    func installed() -> [URL] {
        ((try? files.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Where a sandboxed app keeps everything it saves. macOS ties this folder to the bundle
    /// identifier, not to the installed copy, so it survives reinstalling and updating.
    func dataFolder(for app: URL) -> URL {
        files.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(app.deletingPathExtension().lastPathComponent)/Data")
    }

    /// Moves the app to the Trash. Its data is kept unless `deleteData` is set, in which case
    /// everything inside its data folder is permanently removed.
    func uninstall(_ app: URL, deleteData: Bool) throws {
        let data = dataFolder(for: app)
        try? removeFromApplications(app)
        try files.trashItem(at: app, resultingItemURL: nil)
        guard deleteData, let items = try? files.contentsOfDirectory(at: data, includingPropertiesForKeys: nil) else { return }
        // Entries such as Desktop and Downloads are links to the real folders; removeItem
        // deletes the link itself and never follows it.
        var failed: [String] = []
        for item in items {
            do { try files.removeItem(at: item) } catch { failed.append(item.lastPathComponent) }
        }
        // iOS apps assume these folders exist, so leave an empty skeleton for a later reinstall.
        for folder in ["Documents", "Library/Caches", "Library/Preferences", "Library/Application Support", "tmp"] {
            try? files.createDirectory(at: data.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try? files.removeItem(at: AppSettings.file(for: app.deletingPathExtension().lastPathComponent))
        if !failed.isEmpty { throw Failure.dataNotRemoved(failed) }
    }

    func launch(_ app: URL) throws { try run("/usr/bin/open", [app.path]) }

    private func machOFiles(in bundle: URL) throws -> [URL] {
        guard let walker = files.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var result: [URL] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = (try? handle.read(upToCount: MachO.headerSize)) ?? Data()
            try? handle.close()
            if MachO.isMachO(head) { result.append(url) }
        }
        return result
    }

    private func plist(_ url: URL) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return object as? [String: Any] ?? [:]
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.tool(path, process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
