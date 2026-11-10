import SwiftUI

/// The rows of the shell settings, in the game settings' own model so the same controls draw them. The game ID tells
/// the library that a change belongs to the shell and not to a game.
enum ShellSettingsRows {
    static let gameID = "shell"
    static let hud = "shell.hud"
    static let touchSize = "shell.touchSize"
    static let touchStick = "shell.touchStick"
    static let targetPrefix = "shs.row."

    static func hudRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: hud, label: ShellStrings.text("Performance overlay"), note: ShellStrings.text("Used by games that have no choice of their own."),
                   kind: .toggle(on: "1", off: "0"), value: store.performanceHUD == true ? "1" : "0")
    }

    /// The shell-wide default size for touch controls. The preview above the row shows it.
    static func touchSizeRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: touchSize, label: ShellStrings.text("Size"),
                   kind: .choice([SettingOption("small", ShellStrings.text("Small")), SettingOption("medium", ShellStrings.text("Medium")),
                                  SettingOption("large", ShellStrings.text("Large"))]),
                   value: store.touchSize)
    }

    /// The shell-wide default for the left stick's place. The buttons on the right keep their base placement.
    static func touchStickRow(_ store: ShellSettingsStore) -> SettingRow {
        SettingRow(id: touchStick, label: ShellStrings.text("Left stick"),
                   kind: .choice([SettingOption("corner", ShellStrings.text("Corner")), SettingOption("higher", ShellStrings.text("Higher")),
                                  SettingOption("inward", ShellStrings.text("Inward"))]),
                   value: store.touchStick)
    }

    /// Under the preview and in the editor options: these are shell-wide defaults that game settings or configuration files can override.
    static var touchNote: String { ShellStrings.text("Games and configuration files can override these defaults.") }

    /// A change of one of the rows, from the row itself or from the list of choices.
    static func apply(_ id: String, value: String, to store: ShellSettingsStore) {
        switch id {
        case hud: store.storePerformanceHUD(value == "1")
        case touchSize: store.storeTouchSize(value)
        case touchStick: store.storeTouchStick(value)
        default: break
        }
    }
}

/// Native grouped settings for shell-wide defaults; per-game choices retain precedence.
struct ShellSettingsView: View {
    @Environment(\.shellNativeBars) private var nativeBars
    var store: ShellSettingsStore = .current
    var actions: ShellActions
    var shellCloudSyncing: Bool = false
    var shellCloudStatus: String = ""
    var bridgeDiscovering: Bool = false
    var onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellFocus) private var focus
    /// Counts the changes in the defaults, so the rows read the store again.
    @State private var revision = 0
    @State private var urlDraft = ""
    @State private var tokenDraft = ""
    @State private var syncedStoreURL = ""
    @State private var syncedStoreToken = ""
    @FocusState private var focusedField: BridgeField?

    private enum BridgeField: Hashable { case url, token }

    var body: some View {
        let _ = revision
        ScrollViewReader { proxy in
            Form {
                if !nativeBars {
                    Section {
                        LabeledContent(ShellStrings.text("Settings")) {
                            Button(ShellStrings.text("Close"), action: onClose)
                                .accessibilityIdentifier("shellSettings.close")
                                .shellTarget("shs.close", action: onClose)
                        }
                    }.id("shs.top")
                }

                #if !os(tvOS)
                Section {
                    Button(action: actions.onPickShellData) {
                        LabeledContent {
                            Text(store.dataFolderName ?? ShellStrings.text("Choose folder…"))
                                .lineLimit(1).truncationMode(.middle)
                        } label: {
                            Label(ShellStrings.text("Game data"), systemImage: "folder")
                                .labelStyle(SettingsRowLabelStyle())
                        }
                    }
                    .accessibilityIdentifier("shellSettings.data")
                    .shellTarget("shs.data", action: actions.onPickShellData)
                    if store.dataFolderName != nil {
                        Button(ShellStrings.text("Remove"), role: .destructive, action: actions.onClearShellData)
                            .accessibilityIdentifier("shellSettings.data.remove")
                            .shellTarget("shs.data.remove", action: actions.onClearShellData)
                    }
                } footer: {
                    Text(ShellStrings.text("Games look for their data here. Keep one romfs.img per game in any folder inside. Each game is found by the image itself, so the folder names do not matter. Each game can also have a folder of its own."))
                }
                #endif

                Section {
                    #if !os(tvOS)
                    Button(action: actions.onPickShellCloud) {
                        LabeledContent {
                            Text(store.cloudSavesFolderName ?? ShellStrings.text("Choose folder…"))
                                .lineLimit(1).truncationMode(.middle)
                        } label: {
                            Label(ShellStrings.text(store.cloudSavesFolderName == nil ? "Enable Cloud saves" : "Cloud saves to"), systemImage: "icloud")
                                .labelStyle(SettingsRowLabelStyle())
                        }
                    }
                    .accessibilityIdentifier("shellSettings.cloud")
                    .shellTarget("shs.cloud", action: actions.onPickShellCloud)
                    if store.cloudSavesFolderName != nil {
                        Button(ShellStrings.text("Turn off"), role: .destructive, action: actions.onClearShellCloud)
                            .accessibilityIdentifier("shellSettings.cloud.off")
                            .accessibilityLabel(ShellStrings.text("Turn off cloud saves"))
                            .shellTarget("shs.cloud.off", action: actions.onClearShellCloud)
                    }
                    #endif
                    Button {
                        commitBridge()
                        actions.onSyncAllCloudSaves()
                    } label: {
                        Label(shellCloudSyncing ? ShellStrings.text("Syncing…") : ShellStrings.text("Sync now"), systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .disabled(shellCloudSyncing)
                    .accessibilityIdentifier("shellSettings.cloud.sync")
                    .shellTarget("shs.cloud.sync", enabled: !shellCloudSyncing) {
                        commitBridge()
                        actions.onSyncAllCloudSaves()
                    }
                    if !shellCloudStatus.isEmpty {
                        Text(shellCloudStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("shellSettings.cloud.status")
                    }
                } footer: {
                    #if os(tvOS)
                    Text(ShellStrings.text("Connect to your Mac over Wi-Fi to sync saves."))
                    #else
                    Text(ShellStrings.text("Games without a folder of their own save here. Choose the same iCloud Drive folder you use on your Mac."))
                    #endif
                }

                Section {
                    #if os(tvOS)
                    TextField(ShellStrings.text("Server address"), text: $urlDraft, prompt: Text(verbatim: "192.168.1.10:47921"))
                        .focused($focusedField, equals: .url)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit { commitBridge() }
                        .accessibilityIdentifier("shellSettings.bridge.url")
                        .shellTarget("shs.bridge.url") { focusedField = .url }
                    SecureField(ShellStrings.text("Access key"), text: $tokenDraft, prompt: Text(verbatim: "••••••"))
                        .focused($focusedField, equals: .token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { commitBridge() }
                        .accessibilityIdentifier("shellSettings.bridge.token")
                        .shellTarget("shs.bridge.token") { focusedField = .token }
                    #else
                    VStack(alignment: .leading, spacing: 8) {
                        Label(ShellStrings.text("Server address"), systemImage: "network")
                            .labelStyle(SettingsRowLabelStyle())
                        TextField(ShellStrings.text("Server address"), text: $urlDraft, prompt: Text(verbatim: "192.168.1.10:47921"))
                            .focused($focusedField, equals: .url)
                            .autocorrectionDisabled()
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                            .onSubmit { commitBridge() }
                            .accessibilityIdentifier("shellSettings.bridge.url")
                    }
                    .shellTarget("shs.bridge.url") { focusedField = .url }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(ShellStrings.text("Access key"), systemImage: "key")
                            .labelStyle(SettingsRowLabelStyle())
                        SecureField(ShellStrings.text("Access key"), text: $tokenDraft, prompt: Text(verbatim: "••••••"))
                            .focused($focusedField, equals: .token)
                            .autocorrectionDisabled()
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onSubmit { commitBridge() }
                            .accessibilityIdentifier("shellSettings.bridge.token")
                    }
                    .shellTarget("shs.bridge.token") { focusedField = .token }
                    #endif

                    Button {
                        let t = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t != (store.saveBridgeToken ?? "") {
                            actions.onSaveBridgeChange(store.saveBridgeURL ?? "", t)
                        }
                        actions.onDiscoverSaveBridge()
                    } label: {
                        Label(bridgeDiscovering ? ShellStrings.text("Searching…") : ShellStrings.text("Find Mac on Wi-Fi"), systemImage: "wifi")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .disabled(bridgeDiscovering)
                    .accessibilityIdentifier("shellSettings.bridge.scan")
                    .shellTarget("shs.bridge.scan", enabled: !bridgeDiscovering) {
                        let t = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t != (store.saveBridgeToken ?? "") {
                            actions.onSaveBridgeChange(store.saveBridgeURL ?? "", t)
                        }
                        actions.onDiscoverSaveBridge()
                    }

                    if !urlDraft.isEmpty || !tokenDraft.isEmpty {
                        Button(ShellStrings.text("Clear save server"), role: .destructive) {
                            urlDraft = ""
                            tokenDraft = ""
                            actions.onSaveBridgeChange("", "")
                        }
                        .accessibilityIdentifier("shellSettings.bridge.clear")
                        .shellTarget("shs.bridge.clear") {
                            urlDraft = ""
                            tokenDraft = ""
                            actions.onSaveBridgeChange("", "")
                        }
                    }
                } header: {
                    Text(ShellStrings.text("Save server"))
                } footer: {
                    Text(ShellStrings.text("Sync saves with your Mac over Wi-Fi when iCloud Drive is unavailable."))
                }

                #if !os(tvOS)
                Section {
                    TouchArrangeRow(arranged: !store.touchLayout.isEmpty)
                }
                #endif

                Section {
                    Toggle(isOn: Binding(get: { store.performanceHUD == true }, set: { store.storePerformanceHUD($0); revision += 1 })) {
                        Label(ShellStrings.text("Performance overlay"), systemImage: "speedometer")
                                .labelStyle(SettingsRowLabelStyle())
                    }
                    .toggleStyle(NativeCreamToggleStyle())
                    .accessibilityIdentifier("setting.shell.hud")
                    .shellTarget("shs.row.\(ShellSettingsRows.hud)") {
                        store.storePerformanceHUD(store.performanceHUD != true)
                        revision += 1
                    }
                } header: {
                    Text(ShellStrings.text("Interface"))
                } footer: {
                    Text(ShellStrings.text("Used by games that have no choice of their own."))
                }
            }
            .formStyle(.grouped)
            .labelStyle(SettingsRowLabelStyle())
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .background(ShellPalette.background)
            .onChange(of: focus.id) { _, id in
                guard let id, id.hasPrefix("shs.") else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(id == "shs.close" ? "shs.top" : id, anchor: id == "shs.close" ? .top : .center)
                }
            }
        }
        .tint(ShellPalette.cream)
        .preferredColorScheme(.dark)
        .onAppear { syncDraftsFromStore(force: true) }
        .onDisappear { commitBridge() }
        .onChange(of: focusedField) { old, new in
            if old != nil && new != old { commitBridge() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            revision += 1
            syncDraftsFromStore(force: false)
        }
    }

    private func syncDraftsFromStore(force: Bool) {
        let u = store.saveBridgeURL ?? ""
        let t = store.saveBridgeToken ?? ""
        if force || u != syncedStoreURL {
            syncedStoreURL = u
            urlDraft = u
        }
        if force || t != syncedStoreToken {
            syncedStoreToken = t
            tokenDraft = t
        }
    }

    private func commitBridge() {
        let u = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if u != (store.saveBridgeURL ?? "") || t != (store.saveBridgeToken ?? "") {
            actions.onSaveBridgeChange(u, t)
        }
    }
}

struct SettingsRowLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconSize = 30

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
                .font(.body.weight(.semibold))
                .foregroundStyle(.black)
                .frame(width: iconSize, height: iconSize)
                .background(ShellPalette.cream, in: RoundedRectangle(cornerRadius: iconSize * 0.23))
                .accessibilityHidden(true)
            configuration.title
                .foregroundStyle(.primary)
        }
    }
}
