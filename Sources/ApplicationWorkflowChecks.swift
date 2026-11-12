import AppKit

@MainActor enum ApplicationWorkflowChecks {
    static func run(folder: URL) async throws -> [[String: Any]] {
        let state = folder.appendingPathComponent("ApplicationWorkflow")
        let store = StudioStore(baseOverride: state, registerSystemEvents: false)
        let fixture = folder.appendingPathComponent("OfflineRecordingTarget.app")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String:Any] = ["CFBundleIdentifier":"studio.twiggy.SoundFlow.WorkflowFixture", "CFBundleName":"Offline Recording Target", "CFBundlePackageType":"APPL", "CFBundleIconFile":"AppIcon.icns"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: fixture.appendingPathComponent("Contents/Info.plist"))
        if let icon = Bundle.main.url(forResource:"AppIcon",withExtension:"icns") { try FileManager.default.copyItem(at:icon,to:fixture.appendingPathComponent("Contents/Resources/AppIcon.icns")) }
        let added = try store.addApplication(fixture)
        _ = try store.addApplication(fixture)
        try SelfTest.check(store.savedApplications.filter { $0.id == added.id }.count == 1, "重复添加产生重复预设")
        guard let app = store.favoriteApps.first(where: { $0.id == added.id }) else { throw FlowError("未运行的手动应用未出现在常用预设") }
        try SelfTest.check(app.pid == 0 && app.icon != nil, "未运行应用无法读取图标")
        guard let source = store.session.blocks.first(where: { $0.kind == .application }) else { throw FlowError("没有应用来源") }
        store.selectRecordingApplication(source.id, bundleID: added.id)
        store.save()
        let reloaded = StudioStore(baseOverride: state, registerSystemEvents: false)
        try SelfTest.check(reloaded.savedApplications.contains(added), "应用预设未持久保存")
        try SelfTest.check(reloaded.session.blocks.first(where: { $0.id == source.id })?.bundleID == added.id, "录制目标未持久保存")
        if let main = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.lemon.lvpro" && $0.activationPolicy == .regular }), let url = main.bundleURL {
            let real = try reloaded.addApplication(url)
            try SelfTest.check(real.name == main.localizedName && !real.name.contains("TrayHelper"), "剪映预设误读了辅助进程名称")
            try SelfTest.check(reloaded.favoriteApps.first(where: { $0.id == real.id })?.icon != nil, "剪映主应用图标未加载")
        }
        let count = reloaded.savedApplications.count
        do { _ = try reloaded.addApplication(folder.appendingPathComponent("not-an-app.txt")); throw FlowError("意外接受无效应用") }
        catch { try SelfTest.check(reloaded.savedApplications.count == count, "拒绝无效应用时损坏预设") }
        reloaded.unpinApplication(added.id)
        let removed = StudioStore(baseOverride: state, registerSystemEvents: false)
        try SelfTest.check(!removed.savedApplications.contains(where: { $0.id == added.id }), "移除预设未保存")
        try SelfTest.check(removed.session.blocks.first(where: { $0.id == source.id })?.bundleID == added.id, "移除预设意外删除现有录制目标")
        await store.shutdown(); await reloaded.shutdown(); await removed.shutdown()
        return [["test":"offline_application_add_pin_persistence_and_removal", "passed":true, "offline_icon_loaded":true, "duplicate_prevented":true]]
    }
}
