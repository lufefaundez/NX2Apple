import SwiftUI

/// Selector and manager for per-user save profiles (`default` + custom profiles synced with Mac).
struct ProfilesView: View {
    @Environment(\.shellNativeBars) private var nativeBars
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellFocus) private var focus

    let profiles: [SaveProfile]
    let activeProfileID: String
    var refreshing: Bool = false
    var statusText: String = ""
    let onSelect: (String) -> Void
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    let onRefresh: () -> Void
    let onClose: () -> Void

    @State private var newName = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if !nativeBars {
                    Section {
                        LabeledContent(ShellStrings.text("Player profile")) {
                            Button(ShellStrings.text("Close"), action: onClose)
                                .accessibilityIdentifier("profiles.close")
                                .shellTarget("prf.close", action: onClose)
                        }
                    }
                    .id("prf.top")
                }

                Section {
                    ForEach(profiles) { profile in
                        let isActive = profile.id == activeProfileID
                        HStack(spacing: 12) {
                            Button {
                                onSelect(profile.id)
                            } label: {
                                HStack(spacing: 12) {
                                    Label(profile.name, systemImage: isActive ? "person.crop.circle.fill" : "person.crop.circle")
                                        .labelStyle(SettingsRowLabelStyle())
                                    Spacer(minLength: 8)
                                    if isActive {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(ShellPalette.cream)
                                            .accessibilityLabel(ShellStrings.text("Active profile"))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("profiles.select.\(profile.id)")
                            .accessibilityAddTraits(isActive ? .isSelected : [])
                            .shellTarget("prf.select.\(profile.id)") { onSelect(profile.id) }

                            if profile.id != ShellSettingsStore.defaultProfileID {
                                Button(ShellStrings.text("Remove"), role: .destructive) {
                                    onRemove(profile.id)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(DeleteStyle.red)
                                .accessibilityIdentifier("profiles.remove.\(profile.id)")
                                .shellTarget("prf.remove.\(profile.id)") { onRemove(profile.id) }
                            }
                        }
                    }
                } header: {
                    Text(ShellStrings.text("Profiles"))
                } footer: {
                    Text(ShellStrings.text("Each profile keeps its own game saves while sharing the same game files."))
                }
                .id("prf.list")

                Section {
                    TextField(ShellStrings.text("Profile name"), text: $newName)
                        .focused($nameFieldFocused)
                        #if !os(macOS)
                        .textInputAutocapitalization(.words)
                        #endif
                        .onSubmit { submitNewProfile() }
                        .accessibilityIdentifier("profiles.nameField")
                        .shellTarget("prf.field") { nameFieldFocused = true }

                    Button {
                        submitNewProfile()
                    } label: {
                        Label(ShellStrings.text("Add profile"), systemImage: "person.badge.plus")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .disabled(trimmedNewName.isEmpty)
                    .accessibilityIdentifier("profiles.add")
                    .shellTarget("prf.add", enabled: !trimmedNewName.isEmpty) { submitNewProfile() }
                } header: {
                    Text(ShellStrings.text("Add profile"))
                }

                Section {
                    Button(action: onRefresh) {
                        Label(refreshing ? ShellStrings.text("Refreshing…") : ShellStrings.text("Refresh from Mac"),
                              systemImage: "arrow.triangle.2.circlepath")
                            .labelStyle(SettingsRowLabelStyle())
                    }
                    .disabled(refreshing)
                    .accessibilityIdentifier("profiles.refresh")
                    .shellTarget("prf.refresh", enabled: !refreshing, action: onRefresh)

                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("profiles.status")
                    }
                }
            }
            .formStyle(.grouped)
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
            .background(ShellPalette.background)
            .onChange(of: focus.id) { _, id in
                guard let id, id.hasPrefix("prf.") else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    proxy.scrollTo(id == "prf.close" ? (nativeBars ? "prf.list" : "prf.top") : id,
                                   anchor: id == "prf.close" ? .top : .center)
                }
            }
        }
        .tint(ShellPalette.cream)
        .preferredColorScheme(.dark)
    }

    private var trimmedNewName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submitNewProfile() {
        let trimmed = trimmedNewName
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        newName = ""
        nameFieldFocused = false
    }
}
