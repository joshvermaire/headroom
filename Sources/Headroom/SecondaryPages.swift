import AppKit
import HeadroomCore
import SwiftUI

struct PageHeader: View {
    let title: String
    @Binding var page: Page

    var body: some View {
        HStack {
            Button {
                page = .main
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text(title).font(.headline)
            Spacer()
            // Balances the back button so the title stays centered.
            Label("Back", systemImage: "chevron.left").hidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - node_modules

struct NodeModulesPage: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page
    @State private var confirmingAll = false
    @State private var confirmingPath: String?

    var body: some View {
        let stale = model.staleNodeModules
        PageHeader(title: "node_modules", page: $page)
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Text("Your package manager's install brings node_modules back, minus any files you edited in it by hand. Idle means no commits, checkouts, or lockfile changes for \(model.staleAfterDays) days.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !stale.isEmpty {
                if confirmingAll {
                    ConfirmBox(
                        message: "Deletes node_modules in \(stale.map(\.projectName).joined(separator: ", ")).",
                        preview: nil, loading: false,
                        actionTitle: "Delete \(Format.bytes(stale.reduce(0) { $0 + $1.bytes }))"
                    ) {
                        confirmingAll = false
                        model.deleteNodeModules(stale)  // also clears model.pending
                    }
                    .onChange(of: model.pending) { _, new in if new == nil { confirmingAll = false } }
                } else {
                    Button("Delete all idle (\(Format.bytes(stale.reduce(0) { $0 + $1.bytes })))…") {
                        confirmingAll = true
                        confirmingPath = nil
                        model.pending = PendingClean(categoryID: "__node_modules__", previewText: nil, loadingPreview: false)
                    }
                    .controlSize(.small)
                    .disabled(!model.canClean)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.nodeModules) { folder in
                    row(folder)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ folder: NodeModulesFolder) -> some View {
        let isStale = folder.isStale(now: Date(), after: model.staleAfterDays)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.projectName).lineLimit(1).truncationMode(.middle)
                        .help((folder.path as NSString).abbreviatingWithTildeInPath)
                    Text(folder.lastActive == .distantPast
                         ? "No activity found"
                         : "Active \(folder.lastActive.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(isStale ? .orange : .secondary)
                }
                Spacer()
                Text(Format.bytes(folder.bytes)).monospacedDigit()
                Button {
                    model.reveal(path: folder.path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                if model.cleaning.contains(folder.path) {
                    ProgressView().controlSize(.small).frame(width: 52)
                } else {
                    Button("Delete") {
                        confirmingPath = folder.path
                        confirmingAll = false
                        model.pending = PendingClean(categoryID: folder.path, previewText: nil, loadingPreview: false)
                    }
                    .controlSize(.small)
                    .frame(width: 52)
                    .disabled(!model.canClean)
                }
            }
            if confirmingPath == folder.path && model.pending?.categoryID == folder.path {
                ConfirmBox(
                    message: (folder.path as NSString).abbreviatingWithTildeInPath,
                    preview: nil, loading: false, actionTitle: "Delete \(Format.bytes(folder.bytes))"
                ) {
                    confirmingPath = nil
                    model.deleteNodeModules([folder])
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page

    private let thresholds: [Int64] = [10, 25, 50, 100].map { $0 * 1_000_000_000 }
    private let staleOptions = [14, 30, 60, 90]

    var body: some View {
        @Bindable var model = model
        PageHeader(title: "Settings", page: $page)
        Divider()
        Form {
            Picker("Menu bar shows", selection: $model.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Notify when space is low", isOn: $model.alertsEnabled)
            Picker("Low means under", selection: $model.alertThreshold) {
                ForEach(thresholds, id: \.self) { Text(Format.bytes($0)).tag($0) }
            }
            .disabled(!model.alertsEnabled)
            Picker("Project idle after", selection: $model.staleAfterDays) {
                ForEach(staleOptions, id: \.self) { Text("\($0) days").tag($0) }
            }
            LabeledContent("Project folders") {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(model.projectRoots, id: \.self) { root in
                        HStack(spacing: 4) {
                            Text(root).font(.callout).lineLimit(1).truncationMode(.middle)
                            Button {
                                model.projectRoots.removeAll { $0 == root }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop scanning \(root)")
                        }
                    }
                    Button("Add…") { addRoot() }
                        .controlSize(.small)
                }
            }
            Toggle("Open at login", isOn: Binding(
                get: { _ = model.loginItemRevision; return model.launchAtLogin },
                set: { model.launchAtLogin = $0 }))
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan Folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        if !model.projectRoots.contains(path) { model.projectRoots.append(path) }
        model.scan()
    }
}
