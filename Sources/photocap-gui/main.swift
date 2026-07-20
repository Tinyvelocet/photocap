//  main.swift — photocap-gui
//
//  SwiftUI menu-bar app wrapping the photocap engine.
//
//  SAFETY: this GUI only ever triggers deletion of the two REBUILDABLE cache
//  folders (Spotlight index + derivative caches). It never touches originals,
//  the metadata DB, or iCloud. iCloud Photos is always the source of truth.

import SwiftUI
import AppKit
import ServiceManagement
import PhotocapEngine

@main
struct PhotoCapGUI: App {
    @StateObject private var model = LibraryModel()

    var body: some Scene {
        MenuBarExtra("photocap", systemImage: model.statusIcon) {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Observable model that drives all engine calls on a background task.
@MainActor
final class LibraryModel: ObservableObject {
    @Published var libraryPath: String = LibraryModel.defaultLibraryPath()
    @Published var totalBytes: UInt64 = 0
    @Published var categories: [CategorySize] = []
    @Published var daemonsRunning: Bool = false
    @Published var lastMessage: String = "Ready."
    @Published var errorMessage: String? = nil   // non-nil => error state, with explanation
    @Published var isBusy: Bool = false
    @Published var lastUpdated = Date()

    /// Cap target in GB, user-configurable. Defaults to 60.
    @Published var capGB: Double = 60.0
    var capBytes: UInt64 { UInt64(capGB * 1024 * 1024 * 1024) }

    @Published var confirmTarget: String? = nil   // non-nil => show prune confirmation

    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    var safeCaches: [CategorySize] { categories.filter { $0.safeToPrune } }

    /// Distinct menu-bar state: normal / scanning / attention (error | warning).
    private enum MenuStatus: Equatable {
        case normal
        case scanning(String)               // in-progress label
        case attention(reason: String, isError: Bool)
    }

    /// Derives the current state from the model's flags. Priority:
    /// busy > explicit error > daemons-blocked warning > healthy.
    private var menuStatus: MenuStatus {
        if isBusy {
            return .scanning(lastMessage.isEmpty ? "Working…" : lastMessage)
        }
        if let err = errorMessage {
            return .attention(reason: err, isError: true)
        }
        if daemonsRunning {
            return .attention(reason: "Photos background daemons are running. Quit Photos.app and stop photolibraryd/photoanalysisd to enable pruning.", isError: false)
        }
        return .normal
    }

    /// Icon per state: normal = 📷, scanning = refresh arrow, attention = ⚠️.
    var statusIcon: String {
        switch menuStatus {
        case .normal:    return "photo.on.rectangle.angled"
        case .scanning:  return "arrow.clockwise"
        case .attention: return "exclamationmark.triangle"
        }
    }

    /// Tint per state: normal = accent, scanning = blue, error = red, warning = orange.
    var statusColor: Color {
        switch menuStatus {
        case .normal:                   return .accentColor
        case .scanning:                 return .blue
        case .attention(_, let isError):
            return isError ? .red : .orange
        }
    }

    /// Plain-language explanation for the current icon — always shown in the menu.
    var statusSummary: String {
        switch menuStatus {
        case .normal:
            return "Healthy — library ready."
        case .scanning(let label):
            return label
        case .attention(let reason, _):
            return reason
        }
    }

    /// Fraction of the 60 GB quota in use (0...1+).
    var capFraction: Double {
        guard capBytes > 0 else { return 0 }
        return Double(totalBytes) / Double(capBytes)
    }

    /// Best guess at the library the user actually wants managed:
    /// prefer the capped PhotoCap volume if it's mounted, else the default.
    static func defaultLibraryPath() -> String {
        let photoCap = "/Volumes/PhotoCap/Photos Library.photoslibrary"
        if FileManager.default.fileExists(atPath: photoCap) { return photoCap }
        return "\(NSHomeDirectory())/Pictures/Photos Library.photoslibrary"
    }

    func refresh() {
        guard !isBusy else { return }
        isBusy = true
        lastMessage = "Scanning…"
        let path = libraryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let lib = Self.makeLibrary(path)
            let cats = lib.categorySizes()
            let total = lib.totalSizeBytes
            let daemons = Pruner.libraryInUse()
            let message = daemons
                ? "Photos daemons running — live pruning blocked until Photos quits."
                : "Ready. \(formatBytes(total)) total."
            Task { @MainActor in
                self.categories = cats
                self.totalBytes = total
                self.daemonsRunning = daemons
                self.lastUpdated = Date()
                self.lastMessage = message
                self.errorMessage = nil   // refresh succeeded => clear prior error
                self.isBusy = false
            }
        }
    }

    /// Prune a rebuildable cache. force=true bypasses the daemon check; the GUI
    /// always passes false so the engine's libraryInUse guard is enforced.
    func prune(_ target: String, force: Bool) {
        guard !isBusy, !target.isEmpty else { return }
        isBusy = true
        lastMessage = "Pruning \(target)…"
        let path = libraryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let lib = Self.makeLibrary(path)
            let result: String
            var errorMsg: String? = nil
            do {
                let r = try Pruner.prune(library: lib, target: target, force: force)
                result = "Pruned \(r.target): \(r.message)"
            } catch {
                let caughtErr = error
                result = "Error: \(caughtErr)"
                errorMsg = "Prune failed: \(String(describing: caughtErr)). No caches were deleted. Try refreshing, then prune again."
            }
            Task { @MainActor in
                self.lastMessage = result
                self.errorMessage = errorMsg
                self.isBusy = false
                self.refresh()
            }
        }
    }

    /// Prune every allowed cache in one background pass. (Calling `prune` in a
    /// loop doesn't work: the first call sets isBusy, so later calls bail out.)
    func pruneAll(force: Bool) {
        guard !isBusy else { return }
        isBusy = true
        lastMessage = "Pruning all caches…"
        let path = libraryPath
        DispatchQueue.global(qos: .userInitiated).async {
            let lib = Self.makeLibrary(path)
            let result: String
            var errorMsg: String? = nil
            do {
                var freed: UInt64 = 0
                for target in Pruner.allowedTargets {
                    let r = try Pruner.prune(library: lib, target: target, force: force)
                    freed += r.bytesFreed
                }
                result = "Pruned all caches: freed \(formatBytes(freed))."
            } catch {
                let caughtErr = error
                result = "Error: \(caughtErr)"
                errorMsg = "Prune failed: \(String(describing: caughtErr)). Try refreshing, then prune again."
            }
            Task { @MainActor in
                self.lastMessage = result
                self.errorMessage = errorMsg
                self.isBusy = false
                self.refresh()
            }
        }
    }

    /// Aggressive: prune rebuildable caches down to the 60 GB cap.
    func pruneToCap(force: Bool) {
        guard !isBusy else { return }
        isBusy = true
        lastMessage = "Capping to \(formatBytes(capBytes))…"
        let path = libraryPath
        let cap = capBytes
        DispatchQueue.global(qos: .userInitiated).async {
            let lib = Self.makeLibrary(path)
            let result: String
            var errorMsg: String? = nil
            do {
                let rs = try Pruner.pruneToCap(library: lib, capBytes: cap, force: force)
                let freed = rs.reduce(0) { $0 + $1.bytesFreed }
                result = freed > 0
                    ? "Capped: freed \(formatBytes(freed)) across \(rs.count) cache(s)."
                    : "Already under the cap — nothing to prune."
            } catch {
                let caughtErr = error
                result = "Error: \(caughtErr)"
                errorMsg = "Cap failed: \(String(describing: caughtErr)). No caches were deleted. Try refreshing, then cap again."
            }
            Task { @MainActor in
                self.lastMessage = result
                self.errorMessage = errorMsg
                self.isBusy = false
                self.refresh()
            }
        }
    }

    /// Present an Open panel so the user can point at a different library.
    func browseForLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "photoslibrary")!]
        panel.directoryURL = URL(fileURLWithPath: (libraryPath as NSString).deletingLastPathComponent)
        panel.message = "Choose a Photos Library"
        if panel.runModal() == .OK, let url = panel.url {
            libraryPath = url.path
            refresh()
        }
    }

    /// Build a PhotoLibrary from a (possibly tilde-prefixed) path without
    /// capturing any actor-isolated state.
    private nonisolated static func makeLibrary(_ path: String) -> PhotoLibrary {
        let expanded = (path as NSString).expandingTildeInPath
        return PhotoLibrary(url: URL(fileURLWithPath: expanded))
    }

    /// Register/unregister the app with the system login items so it starts at login.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            lastMessage = "Launch-at-login: \(error.localizedDescription)"
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusBanner
            libraryRow
            usageBar
            Divider()
            cacheSection
            Divider()
            capRow
            Divider()
            iCloudNote
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { model.refresh() }
        .alert("Prune caches?", isPresented: Binding(
            get: { model.confirmTarget != nil },
            set: { if !$0 { model.confirmTarget = nil } }
        )) {
            Button("Prune", role: .destructive) {
                if let t = model.confirmTarget {
                    if t == "__ALL__" {
                        model.pruneAll(force: false)
                    } else {
                        model.prune(t, force: false)
                    }
                }
                model.confirmTarget = nil
            }
            Button("Cancel", role: .cancel) { model.confirmTarget = nil }
        } message: {
            if model.confirmTarget == "__ALL__" {
                Text("This deletes the Spotlight index and derivative caches. Photos regenerates them automatically. Continue?")
            } else if let t = model.confirmTarget {
                Text("This deletes the rebuildable cache \"\(t)\". Photos will regenerate it. Continue?")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: model.statusIcon)
                .foregroundColor(model.statusColor)
            Text("photocap").font(.headline)
            Spacer()
            Button(action: { model.refresh() }) { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
                .disabled(model.isBusy)
        }
    }

    /// Plain-language explanation of the current menu-bar icon, shown right
    /// under the title so the status is never unexplained.
    @ViewBuilder
    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: model.statusIcon)
                .foregroundColor(model.statusColor)
            Text(model.statusSummary)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(model.statusColor.opacity(0.10))
        .cornerRadius(6)
    }

    private var libraryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "folder").foregroundColor(.secondary)
                Text(model.libraryPath)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Browse…", action: { model.browseForLibrary() })
                    .font(.caption2)
            }
        }
    }

    private var usageBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Usage vs \(model.capGB, specifier: "%.0f") GB cap")
                Spacer()
                Text("\(formatBytes(model.totalBytes)) / \(formatBytes(model.capBytes))")
                    .font(.caption2).foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.capFraction > 1 ? Color.red : Color.accentColor)
                        .frame(width: min(CGFloat(model.capFraction) * geo.size.width, geo.size.width))
                }
            }
            .frame(height: 8)
        }
    }

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rebuildable caches (safe to prune)").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button(action: { model.confirmTarget = "__ALL__" }) {
                    Text("Prune all")
                }
                .font(.caption)
                .disabled(model.isBusy || model.safeCaches.isEmpty)
            }
            ForEach(model.safeCaches, id: \.name) { c in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.name)
                        Text(formatBytes(c.bytes)).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { model.confirmTarget = cTarget(for: c.name) }) {
                        Text("Prune")
                    }
                    .disabled(model.isBusy)
                }
            }
            if model.safeCaches.isEmpty {
                Text("No rebuildable caches found.").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var capRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundColor(.secondary)
                Text("Aggressively cap to")
                TextField("GB", value: $model.capGB, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                Text("GB")
                Spacer()
                Button(action: { model.pruneToCap(force: false) }) {
                    Text("Cap now")
                }
                .disabled(model.isBusy)
            }
        }
    }

    private func cTarget(for name: String) -> String {
        if name.contains("Spotlight") { return "database/search/Spotlight" }
        if name.contains("Derivative") { return "resources/derivatives" }
        return ""
    }

    private var iCloudNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "icloud").foregroundColor(.blue)
            Text("iCloud Photos is never modified. Only regenerable caches are pruned; originals re-download from iCloud on demand.")
                .font(.caption2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .onChange(of: model.launchAtLogin) { _, newValue in model.setLaunchAtLogin(newValue) }
                .font(.caption2)
            if !model.lastMessage.isEmpty {
                Text(model.lastMessage)
                    .font(.caption2)
                    .foregroundColor(model.lastMessage.hasPrefix("Error") ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Updated \(model.lastUpdated, style: .time)")
                .font(.caption2).foregroundColor(.secondary)
        }
    }
}
