import AppKit
import SwiftUI
import NXCore
import NXLauncher
import NXModel

/// Settings card for the Mac Save Bridge server and per-player save profiles shared with iPhone / Apple TV.
struct SaveBridgeCard: View {
    let saveBridge: SaveSyncBridge?
    var chooseFolder: (URL?) -> URL? = CloudSavesCard.openPanel
    @EnvironmentObject var loc: Localizer

    @State private var revision = 0
    @State private var defaultNameInput = ""
    @State private var newProfileName = ""
    @State private var showToken = false
    @State private var copiedURL = false
    @State private var copiedToken = false

    private var defaults: UserDefaults { saveBridge?.defaults ?? .standard }

    var body: some View {
        let _ = revision
        let urlText = saveBridge?.primaryURL() ?? "http://127.0.0.1:\(SaveSyncBridge.defaultPort)/saves/"
        let tokenText = saveBridge?.token ?? ""
        let bridgeReady = saveBridge?.isRunning ?? false
        let profiles = SaveBridgeProfileStore.allProfiles(fallbackDefaultName: loc.t("bridge.defaultProfile"), defaults: defaults)
        let customProfiles = profiles.filter { $0.id != SaveBridgeProfileStore.defaultProfileID }
        let activeID = SaveBridgeProfileStore.activeMacProfileID(defaults: defaults)

        CardGroup(loc.t("bridge.section"), footnote: loc.t("bridge.footnote")) {
            CardRow(loc.t("bridge.serverUrl"), detail: urlText,
                    dot: bridgeReady ? LauncherPalette.ready : LauncherPalette.unbuilt, help: urlText) {
                Button(loc.t(copiedURL ? "bridge.copied" : "bridge.copy")) {
                    copyToPasteboard(urlText, mark: $copiedURL)
                }
                .disabled(saveBridge == nil)
                .padTarget("set.bridgeCopyUrl", scope: "main") {
                    if saveBridge != nil { copyToPasteboard(urlText, mark: $copiedURL) }
                }
            }
            CardDivider()
            tokenRow(tokenText)
            CardDivider()
            CardRow(loc.t("bridge.activeMacProfile"), detail: loc.t("bridge.activeMacProfileNote")) {
                LauncherDropdown(
                    options: profiles.map { (value: $0.id, label: $0.name) },
                    selection: activeID,
                    label: loc.t("bridge.activeMacProfile"),
                    style: .button
                ) { chosen in
                    SaveBridgeProfileStore.setActiveMacProfileID(chosen, defaults: defaults)
                    revision += 1
                }
                .padTarget("set.bridgeMacProfile", scope: "main") {
                    guard !profiles.isEmpty else { return }
                    let idx = profiles.firstIndex { $0.id == activeID } ?? 0
                    let next = profiles[(idx + 1) % profiles.count]
                    SaveBridgeProfileStore.setActiveMacProfileID(next.id, defaults: defaults)
                    revision += 1
                }
            }
            CardDivider()
            defaultProfileRow
            ForEach(customProfiles) { profile in
                CardDivider()
                customProfileRow(profile)
            }
            CardDivider()
            addProfileRow
        }
        .onAppear(perform: loadFields)
    }

    private func tokenRow(_ token: String) -> some View {
        let masked = token.isEmpty ? "—" : "••••••••••••••••"
        let display = showToken && !token.isEmpty ? token : masked
        return CardRow(loc.t("bridge.token"), detail: display,
                       dot: token.isEmpty ? LauncherPalette.unbuilt : LauncherPalette.ready) {
            if !token.isEmpty {
                Button(loc.t(showToken ? "bridge.hide" : "bridge.show")) { showToken.toggle() }
                    .padTarget("set.bridgeRevealToken", scope: "main") { showToken.toggle() }
            }
            Button(loc.t(copiedToken ? "bridge.copied" : "bridge.copy")) {
                copyToPasteboard(token, mark: $copiedToken)
            }
            .disabled(token.isEmpty)
            .padTarget("set.bridgeCopyToken", scope: "main") {
                if !token.isEmpty { copyToPasteboard(token, mark: $copiedToken) }
            }
        }
    }

    private var defaultProfileRow: some View {
        HStack(spacing: 12) {
            Circle().fill(LauncherPalette.ready).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("bridge.defaultProfileName")).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                Text(loc.t("bridge.defaultProfileNameNote")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            TextField(loc.t("bridge.defaultProfile"), text: $defaultNameInput)
                .textFieldStyle(.plain)
                .font(.manrope(13))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(width: 184)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10)))
                .onSubmit(saveDefaultName)
            Button(loc.t("bridge.save"), action: saveDefaultName)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
    }

    private func customProfileRow(_ profile: SaveBridgeProfile) -> some View {
        let resolved = SaveBridgeProfileStore.resolvedFolder(for: profile.id, defaults: defaults).path
        return CardRow(profile.name, detail: CloudSavesCard.shown(resolved), detail2: "id: \(profile.id)",
                       dot: LauncherPalette.ready, help: resolved) {
            Button(loc.t("library.chooseFolder")) {
                let start = URL(fileURLWithPath: resolved)
                if let picked = chooseFolder(start) {
                    SaveBridgeProfileStore.setFolderPath(id: profile.id, path: picked.path, defaults: defaults)
                    revision += 1
                }
            }
            Button(loc.t("bridge.removeProfile")) {
                SaveBridgeProfileStore.removeProfile(id: profile.id, defaults: defaults)
                revision += 1
            }
        }
    }

    private var addProfileRow: some View {
        HStack(spacing: 12) {
            Circle().fill(.clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(loc.t("bridge.addProfileTitle")).font(.manrope(14)).fixedSize(horizontal: false, vertical: true)
                Text(loc.t("bridge.addProfileNote")).font(.manrope(12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            TextField(loc.t("bridge.profilePlaceholder"), text: $newProfileName)
                .textFieldStyle(.plain)
                .font(.manrope(13))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(width: 184)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10)))
                .onSubmit(addProfile)
            Button(loc.t("bridge.addProfile"), action: addProfile)
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 52)
    }

    private func loadFields() {
        defaultNameInput = defaults.string(forKey: SaveBridgeProfileStore.defaultNameKey) ?? ""
    }

    private func saveDefaultName() {
        SaveBridgeProfileStore.setDefaultProfileName(defaultNameInput, defaults: defaults)
        loadFields()
        revision += 1
    }

    private func addProfile() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = SaveBridgeProfileStore.addProfile(name: trimmed, defaults: defaults)
        newProfileName = ""
        revision += 1
    }

    private func copyToPasteboard(_ text: String, mark: Binding<Bool>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        mark.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            mark.wrappedValue = false
        }
    }
}
