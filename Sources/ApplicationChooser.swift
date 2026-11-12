import SwiftUI
import AppKit

struct ApplicationChooser: View {
    @ObservedObject var store: StudioStore
    let blockID: UUID
    var onCard = false
    @State private var choosing = false
    private var source: AudioBlock? { store.session.blocks.first { $0.id == blockID } }
    private var chosen: RunningAudioApp? { store.apps.first { $0.id == source?.bundleID } }
    var body: some View {
        Button { store.refreshApps(); choosing = true } label: {
            if onCard {
                VStack(spacing: 5) {
                    if let icon = chosen?.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 39, height: 39) }
                    else { Image(systemName: "macwindow").font(.system(size: 31)).frame(height: 39) }
                    HStack(spacing: 3) {
                        Text(chosen?.name ?? "选择应用").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }.font(.system(size: 11, weight: .semibold))
                }.foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 61)
            } else {
                HStack(spacing: 6) {
                    if let icon = chosen?.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 17, height: 17) }
                    Text("录制：" + (chosen?.name ?? "选择应用")).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.foregroundStyle(StudioTheme.ink).padding(.horizontal, 10).frame(height: 30)
            }
        }
        .buttonStyle(StudioButtonStyle(light: onCard)).disabled(store.busy)
        .popover(isPresented: $choosing, arrowEdge: onCard ? .bottom : .top) {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.apps) { app in
                            Button {
                                choosing = false
                                store.selectRecordingApplication(blockID, bundleID: app.id)
                            } label: {
                                HStack(spacing: 9) {
                                    if let icon = app.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 24, height: 24) }
                                    Text(app.name).font(.system(size: 13)).lineLimit(1)
                                    Spacer()
                                    if app.id == source?.bundleID { Image(systemName: "checkmark").foregroundStyle(StudioTheme.cyan) }
                                }.padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
                            }.buttonStyle(StudioButtonStyle()).accessibilityLabel("录制 " + app.name)
                                .contextMenu { Button("加入常用应用") { store.pinApplication(app) } }
                        }
                    }.padding(6)
                }.frame(maxHeight: 340)
                Divider()
                HStack {
                    Button { choosing = false; store.chooseApplication(for: blockID) } label: { Label("添加应用…", systemImage: "plus") }
                    Spacer()
                    Button("刷新") { store.refreshApps() }
                }.buttonStyle(StudioButtonStyle()).padding(10)
            }.frame(width: 250).foregroundStyle(StudioTheme.ink).preferredColorScheme(.light)
        }
        .accessibilityLabel("切换录制应用：" + (chosen?.name ?? "尚未选择"))
        .help("选择要录制的应用，录制中也可以切换")
    }
}
