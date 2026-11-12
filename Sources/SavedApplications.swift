import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension StudioStore {
    var favoriteApps: [RunningAudioApp] {
        savedApplications.compactMap { saved in apps.first { $0.id == saved.id } }
    }
    func loadApplications() {
        guard FileManager.default.fileExists(atPath: applicationsURL.path) else { return }
        do { savedApplications = try JSONDecoder().decode([SavedAudioApp].self, from: Data(contentsOf: applicationsURL)) }
        catch { self.error = "常用应用列表读取失败，原文件已保留：" + error.localizedDescription }
    }
    func saveApplications() {
        do { try JSONEncoder().encode(savedApplications).write(to: applicationsURL, options: .atomic) }
        catch { self.error = "保存常用应用失败：" + error.localizedDescription }
    }
    func bootstrapApplications() {
        guard !FileManager.default.fileExists(atPath: applicationsURL.path) else { return }
        let ids = [session.blocks.first(where: { $0.kind == .application })?.bundleID ?? "", "com.tencent.QQMusicMac", "com.lemon.lvpro", "com.apple.FinalCut", "com.google.Chrome"]
        for id in ids where !id.isEmpty {
            if let url = apps.first(where: { $0.id == id && !$0.path.isEmpty }).map({ URL(fileURLWithPath: $0.path) }) ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                _ = try? addApplication(url)
            }
        }
    }
    @discardableResult func addApplication(_ url: URL) throws -> SavedAudioApp {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else { throw FlowError("请选择有效的 Mac 应用程序（.app）。") }
        guard id != "studio.twiggy.SoundFlow" else { throw FlowError("请选择要录制的其他应用。") }
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id && $0.activationPolicy == .regular }
        let name = running?.localizedName ?? bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
        let entry = SavedAudioApp(id: id, name: name, path: url.path)
        if let i = savedApplications.firstIndex(where: { $0.id == id }) { savedApplications[i] = entry }
        else { savedApplications.append(entry) }
        saveApplications(); refreshApps(); return entry
    }
    func pinApplication(_ app: RunningAudioApp) {
        guard let url = (!app.path.isEmpty ? URL(fileURLWithPath: app.path) : NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.id)) else { return }
        do { _ = try addApplication(url) } catch { self.error = error.localizedDescription }
    }
    func unpinApplication(_ id: String) { savedApplications.removeAll { $0.id == id }; saveApplications(); refreshApps() }
    func chooseApplication(for blockID: UUID? = nil) {
        let panel = NSOpenPanel(); panel.title = "添加录制应用"; panel.prompt = "添加应用"
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false; panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                do {
                    var first: SavedAudioApp?
                    for url in panel.urls { let added = try self.addApplication(url); if first == nil { first = added } }
                    if let blockID, let first { self.selectRecordingApplication(blockID, bundleID: first.id) }
                } catch { self.error = error.localizedDescription }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    func ensureApplicationRunning(_ id: String) async throws {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return }
        let saved = savedApplications.first { $0.id == id }
        guard let url = saved.map({ URL(fileURLWithPath: $0.path) }) ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id), FileManager.default.fileExists(atPath: url.path) else { throw FlowError("目标应用尚未运行，也未找到安装位置。请重新添加应用。") }
        let config = NSWorkspace.OpenConfiguration(); config.activates = false; config.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        refreshApps()
    }
}

struct FavoriteApplicationsBar: View {
    @ObservedObject var store: StudioStore
    let sourceID: UUID
    private var selected: String { store.session.blocks.first { $0.id == sourceID }?.bundleID ?? "" }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(store.favoriteApps) { app in
                    Button { store.selectRecordingApplication(sourceID, bundleID: app.id) } label: {
                        HStack(spacing: 5) {
                            if let icon = app.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18) }
                            Text(app.name).font(.system(size: 12, weight: selected == app.id ? .semibold : .medium)).lineLimit(1)
                        }.padding(.horizontal, 9).frame(height: 28)
                            .foregroundStyle(selected == app.id ? StudioTheme.darkCyan : StudioTheme.ink)
                            .background(selected == app.id ? StudioTheme.cyan.opacity(0.16) : Color.white.opacity(0.35), in: Capsule())
                    }.buttonStyle(StudioButtonStyle(radius: 14)).disabled(store.busy)
                        .accessibilityLabel("常用录制应用：" + app.name).help("切换录制到「" + app.name + "」")
                        .contextMenu { Button("从常用应用移除") { store.unpinApplication(app.id) } }
                }
                Button { store.chooseApplication(for: sourceID) } label: { Label("添加应用", systemImage: "plus").font(.system(size: 12)).padding(.horizontal, 9).frame(height: 28) }
                    .buttonStyle(StudioButtonStyle(radius: 14)).disabled(store.busy).help("选择本机应用并保存为常用预设")
            }.padding(.horizontal, 14).padding(.vertical, 4)
        }.scrollIndicators(.hidden).frame(height: 36).background(NativePanel())
    }
}
