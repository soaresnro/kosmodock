import AppKit
import SwiftUI

/// Settings › Appearance › App Icons: the packs in the packs folder, the one
/// in use, and each app's icon.
struct IconPackSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.icons
        let theme = model.theme
        Section {
            if library.packs.isEmpty {
                Text("No icon packs yet. A pack is a folder of PNG images in the packs folder, named after the apps: Safari.png, com.apple.Terminal.png, visual-studio-code.png.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ForEach(library.packs) { pack in
                        IconPackCard(pack: pack)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack {
                Button("Reload Packs") { library.reload() }
                Button("Open Packs Folder") { library.openFolder() }
                Spacer()
                Button("Restore System Icons") { library.restoreSystemIcons() }
                    .disabled(theme.iconPack == nil && theme.appIcons.isEmpty)
            }
            AppIconChoices()
        } header: {
            Text("App Icons")
        } footer: {
            Text("Icons change only on the Dock: the apps themselves stay as they are. An optional pack.json gives the pack a name, an author, a padding from 0 to 0.4 and the file of each app.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct IconPackCard: View {
    @Environment(AppModel.self) private var model
    let pack: IconPack

    var body: some View {
        let library = model.icons
        let isActive = model.theme.iconPack == pack.id
        let coverage = library.coverage(of: pack)
        let accent = model.accent
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(previewURLs, id: \.self) { url in
                    if let image = library.thumbnail(url, padding: pack.padding) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 26, height: 26)
                    }
                }
            }
            .frame(height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(pack.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if let author = pack.author {
                    Text(L10n.tr("by %@", author))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(L10n.tr("Covers %lld of your %lld apps", coverage.covered, coverage.total))
                .font(.caption)
                .foregroundStyle(coverage.covered > 0 ? .primary : .secondary)
            if let problem = pack.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(HealthLevel.warning.color)
                    .lineLimit(3)
            }
            Button(isActive ? L10n.tr("Stop Using") : L10n.tr("Use")) {
                library.use(isActive ? nil : pack)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isActive ? accent.opacity(0.12) : Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isActive ? accent : Color.primary.opacity(0.1), lineWidth: isActive ? 2 : 1)
        }
        .help(pack.folder.path)
    }

    /// The pack's icons for apps on the dock first, then any others.
    private var previewURLs: [URL] {
        let library = model.icons
        let own = library.dockApps.compactMap { library.packIconURL(pack, for: $0) }
        var seen = Set<URL>()
        return (own + pack.sampleURLs(limit: 6)).filter { seen.insert($0).inserted }.prefix(6).map { $0 }
    }
}

/// Every app on the dock with the icon it shows and a menu to change it.
private struct AppIconChoices: View {
    @Environment(AppModel.self) private var model
    @ViewState private var isExpanded = false

    var body: some View {
        let library = model.icons
        let apps = library.dockApps
        let custom = apps.filter(library.hasCustomIcon).count
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(apps) { app in
                HStack(spacing: 10) {
                    AppIconView(app: app, size: 24, showsIndicator: false, badgeStyle: .hidden)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.workspace.displayName(for: app)).lineLimit(1)
                        Text(source(of: app))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Menu("Change") {
                        Button("Choose Image…") { library.chooseIcon(for: app) }
                        let packs = library.packs.filter { library.packIconURL($0, for: app) != nil }
                        if !packs.isEmpty {
                            Section("From an Icon Pack") {
                                ForEach(packs) { pack in
                                    Button(pack.name) {
                                        if let url = library.packIconURL(pack, for: app) { library.setIcon(url.path, for: app) }
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Keep the App's Own Icon") { library.setIcon("", for: app) }
                        if library.hasCustomIcon(app) {
                            Button("Reset") { library.setIcon(nil, for: app) }
                        }
                    }
                    .fixedSize()
                }
            }
        } label: {
            Text(custom == 0 ? L10n.tr("Icon for each app") : L10n.tr("Icon for each app (%lld custom)", custom))
        }
    }

    private func source(of app: DockApp) -> String {
        let library = model.icons
        switch library.choice(for: app) {
        case .custom(let url): return L10n.tr("Custom: %@", url.lastPathComponent)
        case .pack: return L10n.tr("From %@", library.activePack?.name ?? "")
        case .app: return library.hasCustomIcon(app) ? L10n.tr("The app's own icon, over the pack") : L10n.tr("The app's own icon")
        }
    }
}
