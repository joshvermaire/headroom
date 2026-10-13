import AppKit
import HeadroomCore
import SwiftUI

enum Page {
    case main, nodeModules, settings
}

struct PanelView: View {
    @Environment(AppModel.self) private var model
    @State private var page: Page

    init(page: Page = .main) {
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .main: MainPage(page: $page)
            case .nodeModules: NodeModulesPage(page: $page)
            case .settings: SettingsPage(page: $page)
            }
        }
        .frame(width: 340)
        .animation(.snappy(duration: 0.2), value: page)
        // A confirmation shouldn't still be waiting days later when the panel reopens.
        // MenuBarExtra windows don't reliably report onDisappear, so also watch for the
        // panel losing focus, which is what closing it does.
        .onDisappear { model.pending = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            model.pending = nil
        }
    }
}

// MARK: - Main

struct MainPage: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page

    var body: some View {
        Header()
        Divider()
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SafeSection()
                ReviewSection(page: $page)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        Footer(page: $page)
    }
}

struct Header: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.volume.map { Format.bytes($0.available) } ?? "–")
                    .font(.system(size: 26, weight: .semibold).monospacedDigit())
                Text("available")
                    .foregroundStyle(.secondary)
                Spacer()
                ChangeToday()
            }
            Sparkline(
                samples: model.history.samples(inLast: 7 * 86_400, now: Date()),
                threshold: model.alertThreshold)
                .frame(height: 52)
            if let volume = model.volume {
                Text(summary(volume))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let result = model.lastResult {
                Label(result, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private func summary(_ v: VolumeStatus) -> String {
        var s = "\(Format.percent(v.availableFraction)) of \(Format.bytes(v.total)). \(Format.bytes(v.used)) used"
        if v.purgeable > 1_000_000_000 {
            s += ", including about \(Format.bytes(v.purgeable)) macOS can clear on its own"
        }
        return s + "."
    }
}

struct ChangeToday: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let change = model.availableChangeToday {
            Text("\(Format.delta(change)) today")
                .font(.callout.monospacedDigit())
                .foregroundStyle(change < 0 && Format.isNotable(change) ? .orange : .secondary)
                .help("Change in available space over the last 24 hours")
        } else {
            Text("24h trend soon")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Headroom needs a day of history to show the change.")
        }
    }
}

/// Available space over the last week, with the alert threshold as a dashed line.
struct Sparkline: View {
    let samples: [VolumeSample]
    let threshold: Int64

    var body: some View {
        GeometryReader { geo in
            if samples.count < 2 {
                Text("The trend line fills in as Headroom runs.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
            } else {
                chart(in: geo.size)
            }
        }
        .accessibilityLabel("Available space over the last 7 days")
    }

    private func chart(in size: CGSize) -> some View {
        let values = samples.map(\.available)
        let lo = Double(min(values.min()!, threshold - threshold / 5))
        let hi = Double(values.max()!) * 1.02
        let start = samples.first!.date
        let span = max(1, Date().timeIntervalSince(start))
        func point(_ s: VolumeSample) -> CGPoint {
            CGPoint(
                x: size.width * s.date.timeIntervalSince(start) / span,
                y: size.height * (1 - (Double(s.available) - lo) / max(1, hi - lo)))
        }
        let line = Path { p in
            p.move(to: point(samples[0]))
            for s in samples.dropFirst() { p.addLine(to: point(s)) }
        }
        var area = line
        area.addLine(to: CGPoint(x: point(samples.last!).x, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        let thresholdY = size.height * (1 - (Double(threshold) - lo) / max(1, hi - lo))
        let tint = Color.teal

        return ZStack(alignment: .topLeading) {
            area.fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
            line.stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            Path { p in
                p.move(to: CGPoint(x: 0, y: thresholdY))
                p.addLine(to: CGPoint(x: size.width, y: thresholdY))
            }
            .stroke(Color.red.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Text("alert at \(Format.bytes(threshold))")
                .font(.system(size: 9))
                .foregroundStyle(.red.opacity(0.8))
                .offset(x: 2, y: max(0, thresholdY - 13))
        }
    }
}

// MARK: - Sections

struct SafeSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rows = model.rows(.safe)
        let cleanable = model.cleanableSafeRows
        SectionHeader(title: "Safe to clear", subtitle: "Rebuilt or re-downloaded when needed") {
            if cleanable.count > 1 {
                Button("Clean all…") {
                    model.pending = PendingClean(categoryID: allSafeID, previewText: nil, loadingPreview: false)
                }
                .controlSize(.small)
                .disabled(!model.canClean)
            }
        }
        if model.pending?.categoryID == allSafeID {
            ConfirmBox(
                message: "Clears \(ListFormatter.localizedString(byJoining: cleanable.map(\.category.name))).",
                preview: nil, loading: false,
                actionTitle: "Clean all"
            ) {
                model.confirmClean(cleanable.map(\.id))
            }
        }
        if rows.isEmpty {
            EmptyRow(text: model.scanning ? "Measuring caches…" : "No large caches right now.")
        }
        ForEach(rows) { CategoryRow(row: $0) }
    }
}

let allSafeID = "__all_safe__"

struct ReviewSection: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page

    var body: some View {
        let rows = model.rows(.review)
        let stale = model.staleNodeModules
        SectionHeader(title: "Review first", subtitle: "May hold data you care about") { EmptyView() }
            .padding(.top, 8)
        if !model.blockedCategories.isEmpty || model.hasPartialMeasurements {
            FullDiskAccessNote()
        }
        ForEach(rows) { CategoryRow(row: $0) }
        if !model.nodeModules.isEmpty {
            Button {
                page = .nodeModules
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("node_modules")
                        Text(stale.isEmpty
                             ? "\(model.nodeModules.count) projects, none idle \(model.staleAfterDays)+ days"
                             : "\(stale.count) of \(model.nodeModules.count) projects idle \(model.staleAfterDays)+ days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Format.bytes(model.nodeModules.reduce(0) { $0 + $1.bytes }))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

struct EmptyRow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }
}

struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let row: AppModel.Row
    @State private var expanded = false

    var body: some View {
        let category = row.category
        let busy = model.cleaning.contains(category.id)
        let linked = Cleaner.isLinkedElsewhere(category)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text(category.name).lineLimit(1)
                        Spacer(minLength: 4)
                        if let g = row.growth, Format.isNotable(g) {
                            Text(Format.delta(g))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(g > 0 ? .orange : .green)
                                .help("Change since \(model.growth?.since.formatted(.relative(presentation: .named)) ?? "the last scan")")
                        }
                        SizeText(measurement: row.measurement)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows what this is")

                if busy {
                    ProgressView().controlSize(.small).frame(width: 52)
                } else if !row.measurement.complete && row.measurement.bytes == 0 {
                    Button("Allow") { model.openFullDiskAccessSettings() }
                        .controlSize(.small)
                        .frame(width: 52)
                        .help("Headroom needs Full Disk Access to measure this")
                } else if linked {
                    Button("Show") { model.reveal(category) }
                        .controlSize(.small)
                        .frame(width: 52)
                        .help("This folder is a link to another location, so Headroom won't clean it")
                } else {
                    Button(category.actionTitle) { model.requestClean(category) }
                        .controlSize(.small)
                        .frame(width: 52)
                        .disabled(category.action.isDestructive && !model.canClean)
                }
            }
            if expanded || model.pending?.categoryID == category.id {
                Text(category.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pending = model.pending, pending.categoryID == category.id {
                ConfirmBox(
                    message: nil, preview: pending.previewText, loading: pending.loadingPreview,
                    actionTitle: category.clearsEverything
                        ? "\(category.actionTitle) \(Format.bytes(row.measurement.bytes))"
                        : category.actionTitle
                ) {
                    model.confirmClean([category.id])
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(expanded ? Color.primary.opacity(0.05) : .clear))
    }
}

struct SizeText: View {
    let measurement: SizeReading
    var body: some View {
        if measurement.complete {
            Text(Format.bytes(measurement.bytes)).monospacedDigit()
        } else if measurement.bytes > 0 {
            Text("≥ \(Format.bytes(measurement.bytes))")
                .monospacedDigit()
                .help("Part of this folder couldn't be read without Full Disk Access")
        } else {
            Text("No access").foregroundStyle(.secondary)
        }
    }
}

/// Inline confirmation. Every destructive action passes through here.
struct ConfirmBox: View {
    @Environment(AppModel.self) private var model
    let message: String?
    let preview: String?
    let loading: Bool
    let actionTitle: String
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking what will be removed…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let preview {
                Text(preview)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.pending = nil }
                    .keyboardShortcut(.cancelAction)
                // No Return shortcut: destructive actions take a deliberate click.
                Button(actionTitle, role: .destructive, action: onConfirm)
                    .disabled(loading || !model.canClean)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.25)))
    }
}

struct FullDiskAccessNote: View {
    @Environment(AppModel.self) private var model

    private var message: String {
        let names = model.blockedCategories.map(\.name)
        guard !names.isEmpty else {
            return "Some folders were only partly measured. Full Disk Access lets Headroom read all of them."
        }
        return "\(ListFormatter.localizedString(byJoining: names)) need Full Disk Access to measure. "
            + "Add Headroom in Privacy & Security, then click Rescan."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .padding(.bottom, 4)
    }
}

struct Footer: View {
    @Environment(AppModel.self) private var model
    @Binding var page: Page

    var body: some View {
        HStack(spacing: 4) {
            if model.scanning {
                ProgressView().controlSize(.mini)
                Text("Scanning…")
            } else if let last = model.lastScan {
                Text("Scanned \(last.formatted(.relative(presentation: .named)))")
            }
            Spacer()
            Button("Rescan") { model.scan() }
                .disabled(model.scanning)
            Button {
                page = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Headroom")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.12))
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0)))
    }
}
