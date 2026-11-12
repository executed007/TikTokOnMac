import SwiftUI

struct InstalledApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let identifier: String
    let version: String
    let icon: NSImage
    var id: URL { url }

    init(url: URL) {
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
        self.url = url
        identifier = url.deletingPathExtension().lastPathComponent
        name = info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String ?? identifier
        version = info?["CFBundleShortVersionString"] as? String ?? ""
        icon = InstalledApp.icon(for: url, info: info)
    }

    /// The largest icon PNG the iOS bundle declares, or the Finder icon if none can be read.
    static func icon(for url: URL, info: NSDictionary?) -> NSImage {
        let primary = (info?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        let names = primary?["CFBundleIconFiles"] as? [String] ?? info?["CFBundleIconFiles"] as? [String] ?? []
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let images = files
            .filter { file in file.hasSuffix(".png") && names.contains { file.hasPrefix($0) } }
            .compactMap { NSImage(contentsOf: url.appendingPathComponent($0)) }
            .filter { $0.isValid && ($0.representations.first?.pixelsWide ?? 0) > 0 }
        let best = images.max { ($0.representations.first?.pixelsWide ?? 0) < ($1.representations.first?.pixelsWide ?? 0) }
        return best ?? NSWorkspace.shared.icon(forFile: url.path)
    }
}

@MainActor
final class Library: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var running: Set<String> = []
    @Published var status = "" { didSet { scheduleClear() } }
    @Published var isBusy = false
    @Published var failure: String?
    private var clearTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        refreshRunning()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshRunning() }
            })
        }
    }

    func reload() { apps = Installer().installed().map(InstalledApp.init) }

    private func refreshRunning() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Installs the .ipa (or .app) and, unless it is a reinstall, launches it.
    func install(_ source: URL, launch: Bool = true) {
        guard !isBusy else { return }
        isBusy = true
        status = "Installing \(source.lastPathComponent)..."
        Task.detached(priority: .userInitiated) {
            var installer = Installer()
            installer.log = { message in Task { @MainActor in self.status = message } }
            do {
                let app = try installer.install(source)
                if launch { try installer.launch(app) }
                await self.finish(launch ? "Launched \(source.lastPathComponent)" : "Reinstalled", failure: nil)
            } catch {
                await self.finish("", failure: "\(source.lastPathComponent): \(error)")
            }
        }
    }

    func run(_ app: InstalledApp) {
        do {
            try Installer().launch(app.url)
            status = "Launched \(app.name)"
        } catch {
            failure = "\(app.name): \(error)"
        }
    }

    func remove(_ app: InstalledApp, deleteData: Bool) {
        do {
            try Installer().uninstall(app.url, deleteData: deleteData)
            status = deleteData ? "Uninstalled \(app.name) and deleted its data" : "Uninstalled \(app.name); its data is kept"
        } catch {
            failure = "\(app.name): \(error)"
        }
        reload()
    }

    func exportedCopy(of app: InstalledApp) -> URL? { Installer().exportedCopy(of: app.url) }

    func addToApplications(_ app: InstalledApp) {
        do {
            let copy = try Installer().addToApplications(app.url)
            status = "Added \(app.name) to Applications"
            NSWorkspace.shared.activateFileViewerSelecting([copy])
        } catch {
            failure = "\(app.name): \(error)"
        }
        objectWillChange.send()
    }

    func removeFromApplications(_ app: InstalledApp) {
        do {
            try Installer().removeFromApplications(app.url)
            status = "Removed \(app.name) from Applications"
        } catch {
            failure = "\(app.name): \(error)"
        }
        objectWillChange.send()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose an iOS app"
        panel.allowedContentTypes = [.init(filenameExtension: "ipa"), .applicationBundle].compactMap { $0 }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { install(url) }
    }

    /// Status messages fade away on their own once nothing is in progress.
    private func scheduleClear() {
        clearTask?.cancel()
        guard !status.isEmpty else { return }
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, !self.isBusy else { return }
            self.status = ""
        }
    }

    private func finish(_ message: String, failure: String?) {
        isBusy = false
        status = message
        self.failure = failure
        reload()
    }
}

struct AppIcon: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable().interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

struct AppCard: View {
    let app: InstalledApp
    let isRunning: Bool
    let run: () -> Void
    let configure: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            AppIcon(image: app.icon, size: 76)
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.16), radius: hovering ? 10 : 5, y: hovering ? 6 : 3)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title3).foregroundStyle(.white)
                        .padding(11).background(.black.opacity(0.5), in: Circle())
                        .opacity(hovering ? 1 : 0)
                }
                .scaleEffect(hovering ? 1.05 : 1)
            VStack(spacing: 2) {
                HStack(spacing: 5) {
                    if isRunning { Circle().fill(.green).frame(width: 6, height: 6).help("Running") }
                    Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                }
                Text(app.version.isEmpty ? " " : app.version).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18).padding(.bottom, 12).padding(.horizontal, 8)
        .background(.background.opacity(hovering ? 0.9 : 0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(hovering ? 0.14 : 0.07)))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: run)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(app.name)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Run", run)
        // Kept outside the combined element above so it stays a button of its own.
        .overlay(alignment: .topTrailing) {
            Button(action: configure) {
                Image(systemName: "slider.horizontal.3").font(.caption).padding(6)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Settings for \(app.name)")
            .accessibilityLabel("Settings for \(app.name)")
            .padding(7)
            .opacity(hovering ? 1 : 0.45)
        }
    }
}

struct AppSettingsSheet: View {
    let app: InstalledApp
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var settings: AppSettings
    @State private var installedSandbox: Bool
    @State private var confirmingDelete = false

    init(app: InstalledApp, library: Library) {
        self.app = app
        self.library = library
        let loaded = AppSettings.load(app.identifier)
        _settings = State(initialValue: loaded)
        _installedSandbox = State(initialValue: loaded.sandbox)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AppIcon(image: app.icon, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.title3.weight(.semibold))
                    Text(app.identifier).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if !app.version.isEmpty { Text("Version \(app.version)").font(.caption).foregroundStyle(.tertiary) }
                }
                Spacer()
                Button("Run") { library.run(app); dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
            .padding(20)

            Form {
                Section("Window") {
                    Toggle("Hide the title bar", isOn: $settings.hideTitleBar)
                    Picker("Size at launch", selection: $settings.windowSize) {
                        Text("Let the app decide").tag("default")
                        Text("Phone (430 × 932)").tag("phone")
                        Text("Tablet (1024 × 768)").tag("tablet")
                    }
                }
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: settings.volume == 0 ? "speaker.slash.fill" : "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.volume, in: 0...1, step: 0.05)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                        Text("\(Int((settings.volume * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Toggle("Show a volume button in the app", isOn: $settings.showVolumeButton)
                } header: {
                    Text("Volume")
                } footer: {
                    Text("The level applies straight away. In the app, use the speaker button in the top-right corner, the Volume menu, or ⌘↑, ⌘↓ and ⌘0 to mute.")
                }
                Section {
                    Toggle("Arrow keys move through feeds", isOn: $settings.arrowKeysScrollFeed)
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("Up and Down go to the previous or next item in a full-screen swipe feed, unless you are typing.")
                }
                Section {
                    if let copy = library.exportedCopy(of: app) {
                        LabeledContent("In Applications") {
                            HStack {
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([copy]) }
                                Button("Remove") { library.removeFromApplications(app) }
                            }
                        }
                    } else {
                        LabeledContent("Standalone app") {
                            Button("Add to Applications") { library.addToApplications(app) }
                        }
                    }
                } header: {
                    Text("Mac app")
                } footer: {
                    Text("Adds \(app.name) to your Applications folder so you can open it from Launchpad, Spotlight or the Dock without Catalyst Runner. It shares the same data and takes no extra disk space.")
                }
                Section {
                    Toggle("Keep the picture upright", isOn: $settings.lockCameraOrientation)
                    Toggle("Crop to a portrait frame", isOn: $settings.cropCameraToPortrait)
                } header: {
                    Text("Camera")
                } footer: {
                    Text("Turn these off for apps that expect a landscape camera, such as video calls.")
                }
                Section {
                    Toggle("Run in a sandbox", isOn: $settings.sandbox)
                    LabeledContent("App") {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                    }
                    LabeledContent("Saved data") {
                        Button("Show in Finder") { NSWorkspace.shared.open(Installer().dataFolder(for: app.url)) }
                    }
                    LabeledContent("Signature") {
                        Button("Reinstall") { library.install(app.url, launch: false); dismiss() }
                            .disabled(library.isBusy)
                    }
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Without the sandbox the app saves into your real home folder and macOS asks before it reads your files. Changing this, or reinstalling, re-signs the app, so macOS asks for its permissions again.")
                }
                Section {
                    Button("Uninstall") { library.remove(app, deleteData: false); dismiss() }
                    Button("Uninstall and Delete Data…", role: .destructive) { confirmingDelete = true }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Text("Volume applies straight away; other changes the next time the app is launched.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 460, height: 700)
        .onChange(of: settings) { _, value in
            do { try value.save(app.identifier) } catch { library.failure = "\(app.name): \(error)" }
        }
        .confirmationDialog("Uninstall \(app.name) and delete its data?", isPresented: $confirmingDelete) {
            Button("Delete App and Data", role: .destructive) { library.remove(app, deleteData: true); dismiss() }
        } message: {
            Text("The app goes to the Trash. Its saved data, including logins and downloads inside the app, is deleted permanently.")
        }
    }

    private func close() {
        // The sandbox is part of the signature, so a change only takes effect after re-signing.
        if settings.sandbox != installedSandbox { library.install(app.url, launch: false) }
        dismiss()
    }
}

struct ContentView: View {
    @StateObject private var library = Library()
    @State private var query = ""
    @State private var dropping = false
    @State private var configuring: InstalledApp?

    private var shown: [InstalledApp] {
        query.isEmpty ? library.apps : library.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if library.apps.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                    Text("Drop an .ipa to get started").font(.title3.weight(.medium))
                    Text("Catalyst Runner installs decrypted iOS apps and runs them natively on this Mac.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                    Button("Choose a File…") { library.chooseFile() }.controlSize(.large).disabled(library.isBusy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                        .padding(24)
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Library").font(.title2.weight(.semibold))
                            Text("\(shown.count) \(shown.count == 1 ? "app" : "apps")").font(.callout).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 168), spacing: 14)], spacing: 14) {
                            ForEach(shown) { app in
                                AppCard(app: app, isRunning: library.running.contains(app.identifier),
                                        run: { library.run(app) }, configure: { configuring = app })
                                    .contextMenu {
                                        Button("Run") { library.run(app) }
                                        Button("Settings…") { configuring = app }
                                        Divider()
                                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                                        Button("Show App Data in Finder") { NSWorkspace.shared.open(Installer().dataFolder(for: app.url)) }
                                        if library.exportedCopy(of: app) == nil {
                                            Button("Add to Applications") { library.addToApplications(app) }
                                        } else {
                                            Button("Remove from Applications") { library.removeFromApplications(app) }
                                        }
                                        Divider()
                                        Button("Uninstall") { library.remove(app, deleteData: false) }
                                    }
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 340, maxHeight: .infinity)
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .center)
                .ignoresSafeArea()
        }
        .overlay(alignment: .bottom) {
            if library.isBusy || !library.status.isEmpty {
                HStack(spacing: 8) {
                    if library.isBusy { ProgressView().controlSize(.small) }
                    Text(library.status).font(.callout).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: library.status)
        .animation(.easeOut(duration: 0.18), value: library.isBusy)
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar {
            Button("Open IPA", systemImage: "plus") { library.chooseFile() }
                .help("Install and run an .ipa")
                .disabled(library.isBusy)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { ["ipa", "app"].contains($0.pathExtension.lowercased()) }) else { return false }
            library.install(url)
            return true
        } isTargeted: { dropping = $0 }
        .sheet(item: $configuring) { app in AppSettingsSheet(app: app, library: library) }
        .alert("Something went wrong", isPresented: Binding(get: { library.failure != nil }, set: { if !$0 { library.failure = nil } })) {
            Button("OK") {}
        } message: {
            Text(library.failure ?? "")
        }
    }
}

@main
struct CatalystRunnerApp: App {
    var body: some Scene {
        Window("Catalyst Runner", id: "main") { ContentView() }
            .defaultSize(width: 620, height: 480)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .newItem) {}
            }
    }
}
