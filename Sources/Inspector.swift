import SwiftUI
import AppKit

struct InspectorPanel: View {
    @ObservedObject var store: StudioStore
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach([("模块", "square.stack.3d.up"), ("录音", "recordingtape")], id: \.0) { title, symbol in
                    Button { store.inspectorTab = title; if title == "模块" { store.selectedBlockID = nil } } label: {
                        HStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 16, weight: .regular)); Text(title).font(.system(size: 13, weight: .medium)) }
                            .foregroundStyle(store.inspectorTab == title ? StudioTheme.cyan : StudioTheme.muted)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(store.inspectorTab == title ? StudioTheme.cyan.opacity(0.055) : Color.clear)
                            .overlay(alignment: .bottom) { if store.inspectorTab == title { Rectangle().fill(StudioTheme.cyan).frame(height: 2) } }
                    }.buttonStyle(StudioButtonStyle())
                }
            }
            Divider()
            if store.inspectorTab == "模块" {
                ScrollView {
                    VStack(alignment: .leading, spacing: 13) {
                        if let block = store.block { BlockInspector(store: store, block: block) }
                        else { BlockLibrary(store: store) }
                    }.padding(12)
                }
            } else { RecordingLibrary(store: store) }
        }.frame(width: StudioLayout.inspector).background(NativePanel())
    }
}

struct BlockLibrary: View {
    @ObservedObject var store: StudioStore
    @State private var filter = ""
    @State private var expanded: Set<String> = ["声音来源", "录制与输出", "处理与分析"]
    private let order: [BlockKind] = [.application,.microphone,.system,.file,.tone,.output,.recorder,.mixer,.gain,.equalizer,.compressor,.limiter,.meter]
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(StudioTheme.muted)
                TextField("筛选模块", text: $filter).textFieldStyle(.plain)
            }.font(.system(size: 13)).padding(.horizontal, 10).padding(.vertical, 7).background(.black.opacity(0.045), in: Capsule())
            ForEach(["声音来源", "录制与输出", "处理与分析"], id: \.self) { category in
                let items = order.filter { $0.category == category && (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.detail.localizedCaseInsensitiveContains(filter)) }
                if !items.isEmpty {
                    DisclosureGroup(isExpanded: Binding(get: { !filter.isEmpty || expanded.contains(category) }, set: { if $0 { expanded.insert(category) } else { expanded.remove(category) } })) {
                        VStack(spacing: 2) {
                            ForEach(items) { kind in
                                Button { store.addBlock(kind) } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: kind.symbol).font(.system(size: 20, weight: .regular)).foregroundStyle(.white).frame(width: 34, height: 34).background(StudioTheme.cyan, in: RoundedRectangle(cornerRadius: 7))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(kind.title).font(.system(size: 13, weight: .medium)).foregroundStyle(StudioTheme.ink)
                                            Text(kind.detail).font(.system(size: 11)).foregroundStyle(StudioTheme.muted).lineLimit(2)
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 40).padding(.vertical, 2).contentShape(Rectangle())
                                }.buttonStyle(StudioButtonStyle()).help(kind.detail).accessibilityLabel(kind.title + "，" + kind.detail)
                                    .onDrag { NSItemProvider(object: ("soundflow:" + kind.rawValue) as NSString) }.disabled(store.running || store.busy)
                            }
                        }.padding(.top, 6)
                    } label: { Text(category).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.ink) }
                }
            }
        }
    }
}

struct BlockInspector: View {
    @ObservedObject var store: StudioStore
    let block: AudioBlock
    func double(_ key: WritableKeyPath<AudioBlock, Double>) -> Binding<Double> { Binding(get: { (store.session.blocks.first { $0.id == block.id } ?? block)[keyPath: key] }, set: { value in store.updateBlock(block.id) { $0[keyPath: key] = value } }) }
    func bool(_ key: WritableKeyPath<AudioBlock, Bool>) -> Binding<Bool> { Binding(get: { (store.session.blocks.first { $0.id == block.id } ?? block)[keyPath: key] }, set: { value in store.updateBlock(block.id) { $0[keyPath: key] = value } }) }
    func string(_ key: WritableKeyPath<AudioBlock, String>) -> Binding<String> { Binding(get: { (store.session.blocks.first { $0.id == block.id } ?? block)[keyPath: key] }, set: { value in store.updateBlock(block.id) { $0[keyPath: key] = value } }) }
    var locked: Bool { store.running || store.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: block.kind.symbol).font(.system(size: 20)).foregroundStyle(StudioTheme.cyan)
                Text(block.kind.title).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { store.selectedBlockID = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(StudioTheme.muted.opacity(0.6)) }.buttonStyle(StudioButtonStyle()).help("返回模块库")
            }
            TextField("模块名称", text: string(\.name)).textFieldStyle(.roundedBorder)
            Toggle(block.kind.isSource || block.kind == .recorder || block.kind == .output ? "启用模块" : "启用处理", isOn: bool(\.enabled)).toggleStyle(.switch).controlSize(.small).disabled(locked && (block.kind.isSource || block.kind == .recorder || block.kind == .output))
            Divider()
            parameters
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("实时电平").font(.system(size: 13, weight: .semibold)); Spacer(); Text(String(format: "%.1f dB", max(store.levels[block.id]?.left ?? -90, store.levels[block.id]?.right ?? -90))).font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioTheme.muted) }
                StereoMeter(level: store.levels[block.id] ?? Level()).frame(height: 24)
                Text("−60                       −24               −6    0 dB").font(.system(size: 10, design: .monospaced)).foregroundStyle(StudioTheme.muted)
            }
            if !locked {
                Button(role: .destructive) { store.deleteSelection() } label: { Label("删除模块", systemImage: "trash").font(.system(size: 13)) }.buttonStyle(.borderless)
            }
        }.foregroundStyle(StudioTheme.ink)
    }
    @ViewBuilder var parameters: some View {
        switch block.kind {
        case .application:
            VStack(alignment: .leading, spacing: 9) {
                fieldLabel("录制应用")
                Picker("应用", selection: Binding(get: { block.bundleID }, set: { store.selectRecordingApplication(block.id, bundleID: $0) })) {
                    Text("选择正在运行的应用").tag("")
                    ForEach(store.apps) { app in Text(app.name).tag(app.id) }
                    if !block.bundleID.isEmpty && !store.apps.contains(where: { $0.id == block.bundleID }) { Text("\(block.bundleID) · 未运行").tag(block.bundleID) }
                }.labelsHidden().disabled(store.busy)
                Button { store.chooseApplication(for: block.id) } label: { Label("添加应用…", systemImage: "plus") }.disabled(store.busy)
                Button { store.refreshApps() } label: { Label("刷新应用列表", systemImage: "arrow.clockwise").font(.system(size: 12)) }.buttonStyle(.borderless)
                note("只采集所选应用的声音；原应用仍通过它原来的设备播放。")
            }
            sourceGain
        case .system:
            note("采集 Mac 播放的系统音频，排除声流自身的回放，避免循环录入。麦克风需要单独添加。")
            sourceGain
        case .microphone:
            Label("系统默认输入设备", systemImage: "mic").font(.system(size: 14))
            note("输入设备跟随 macOS「声音 → 输入」设置。首次运行需允许麦克风权限。")
            sourceGain
        case .file:
            VStack(alignment: .leading, spacing: 10) {
                Text(block.filePath.isEmpty ? "尚未选择文件" : URL(fileURLWithPath: block.filePath).lastPathComponent).font(.system(size: 13)).lineLimit(2)
                Button("选择音频文件…") { store.chooseSourceFile(block.id) }.disabled(locked)
                Toggle("循环播放", isOn: bool(\.loop)).disabled(locked)
                note("连接处理模块与录音机，可处理本地音频并另存新文件。")
            }
            sourceGain
        case .tone:
            VStack(alignment: .leading, spacing: 9) {
                SliderRow(title: "频率", value: double(\.frequency), range: 20...20000, unit: "Hz", decimals: 0).disabled(locked)
                note("真实正弦波音源。监听默认关闭，可用它验证电平、处理与录音。")
            }
            sourceGain
        case .gain, .mixer:
            sourceGain
            if block.kind == .mixer { note("多条连线接入时会叠加。可在上游分别调节每路音源，预留峰值余量。") }
        case .equalizer:
            EQControls(store: store, block: block)
        case .compressor:
            SliderRow(title: "阈值", value: double(\.threshold), range: -50...0, unit: "dB")
            SliderRow(title: "动态余量", value: double(\.headroom), range: 0.1...20, unit: "dB")
            SliderRow(title: "起音", value: double(\.attack), range: 0.001...0.2, unit: "s", decimals: 3)
            SliderRow(title: "释放", value: double(\.release), range: 0.01...1, unit: "s", decimals: 2)
            note("动态余量越小，压缩越明显。使用系统原生 Dynamics Processor。")
        case .limiter:
            note("使用系统原生 Peak Limiter 控制峰值。过高输入仍可能失真，请观察上游电平。")
            SliderRow(title: "输入增益", value: double(\.gain), range: -24...18, unit: "dB")
        case .meter:
            note("显示当前模块实际通过的左右声道峰值与平均 RMS。红色表示采样值触及或超过 0 dBFS。")
        case .recorder:
            RecorderControls(store: store, block: block)
        case .output:
            Toggle("监听处理后的声音", isOn: bool(\.monitor)).disabled(!block.enabled)
            Picker("设备", selection: Binding(get: { block.outputDeviceID }, set: { value in store.updateBlock(block.id) { $0.outputDeviceID = value } })) {
                Text("系统默认输出").tag(UInt32(0))
                ForEach(store.devices) { device in Text(device.name).tag(device.id) }
            }.disabled(locked)
            sourceGain
            note("应用／系统原声本来就能听见时，开启监听会叠加延迟后的处理音。请用耳机，避免麦克风反馈。设备选择只作用于声流。")
        }
    }
    var sourceGain: some View {
        VStack(spacing: 15) {
            SliderRow(title: "增益", value: double(\.gain), range: -60...18, unit: "dB")
            SliderRow(title: "声像", value: double(\.pan), range: -1...1, unit: "", decimals: 2)
            Button("恢复 0 dB / 居中") { store.updateBlock(block.id) { $0.gain = 0; $0.pan = 0 } }.font(.system(size: 12)).buttonStyle(.borderless)
        }
    }
    func fieldLabel(_ text: String) -> some View { Text(text).font(.system(size: 13, weight: .semibold)) }
    func note(_ text: String) -> some View { Text(text).font(.system(size: 12)).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true).lineSpacing(3) }
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String
    var decimals = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)); Spacer()
                TextField("", value: $value, formatter: formatter).font(.system(size: 12, design: .monospaced)).multilineTextAlignment(.trailing).frame(width: 60).textFieldStyle(.roundedBorder)
                    .onChange(of: value) { _, new in if !new.isFinite || !range.contains(new) { value = min(range.upperBound, max(range.lowerBound, new.isFinite ? new : 0)) } }
                Text(unit).font(.system(size: 11)).foregroundStyle(StudioTheme.muted).frame(minWidth: 10)
            }
            Slider(value: $value, in: range).controlSize(.small).accessibilityLabel(title)
        }
    }
    var formatter: NumberFormatter { let f = NumberFormatter(); f.minimumFractionDigits = decimals; f.maximumFractionDigits = decimals; return f }
}

struct EQControls: View {
    @ObservedObject var store: StudioStore
    let block: AudioBlock
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("十段均衡").font(.system(size: 14, weight: .semibold)); Spacer(); Button("平直") { store.updateBlock(block.id) { $0.bands = Array(repeating: 0, count: 10) } }.buttonStyle(.borderless).font(.system(size: 12)) }
            EQCurve(bands: block.bands).frame(height: 90).background(StudioTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
            Menu("均衡预设") {
                Button("平直") { set(Array(repeating: 0, count: 10)) }
                Button("人声清晰") { set([-6,-4,-2,0,1,2,3,2,0,-1]) }
                Button("温暖") { set([1,2,2,1,0,0,-1,-2,-2,-2]) }
                Button("低频增强") { set([4,4,3,1,0,0,0,0,0,0]) }
                Button("减少低频轰鸣") { set([-12,-8,-4,-2,0,0,0,0,0,0]) }
            }.font(.system(size: 13))
            ForEach(0..<10, id: \.self) { i in
                HStack(spacing: 8) {
                    Text(eqLabels[i]).font(.system(size: 11, design: .monospaced)).foregroundStyle(StudioTheme.muted).frame(width: 26, alignment: .trailing)
                    Slider(value: Binding(get: { block.bands[i] }, set: { v in store.updateBlock(block.id) { $0.bands[i] = v } }), in: -18...18).controlSize(.mini).accessibilityLabel("均衡 \(eqLabels[i]) Hz")
                    Text(String(format: "%+.0f", block.bands[i])).font(.system(size: 11, design: .monospaced)).frame(width: 24)
                }
            }
        }
    }
    func set(_ values: [Double]) { store.updateBlock(block.id) { $0.bands = values } }
}

struct EQCurve: View {
    let bands: [Double]
    var body: some View {
        Canvas { context, size in
            for i in 1...3 {
                let y = size.height * CGFloat(i) / 4
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(p, with: .color(StudioTheme.line), lineWidth: 1)
            }
            var path = Path()
            for i in 0..<bands.count {
                let p = CGPoint(x: 10 + (size.width - 20) * Double(i) / 9, y: size.height / 2 - bands[i] / 24 * size.height / 2)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(StudioTheme.cyan))
            }
            context.stroke(path, with: .color(StudioTheme.cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

struct RecorderControls: View {
    @ObservedObject var store: StudioStore
    let block: AudioBlock
    var locked: Bool { store.running || store.busy }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Picker("格式", selection: Binding(get: { block.format }, set: { f in store.updateBlock(block.id) { $0.format = f; if f.lossy && $0.sampleRate == 96000 { $0.sampleRate = 48000 }; if [.alac, .flac].contains(f) && $0.bitDepth == 32 { $0.bitDepth = 24 } } })) { ForEach(RecordingFormat.allCases) { f in Text(f.label).tag(f) } }
            Picker("采样率", selection: Binding(get: { block.sampleRate }, set: { v in store.updateBlock(block.id) { $0.sampleRate = v } })) {
                Text("44.1 kHz").tag(44100.0); Text("48 kHz").tag(48000.0)
                if !block.format.lossy { Text("96 kHz").tag(96000.0) }
            }
            Picker("声道", selection: Binding(get: { block.channels }, set: { v in store.updateBlock(block.id) { $0.channels = v } })) { Text("立体声").tag(2); Text("单声道").tag(1) }
            if block.format.lossy {
                Picker("目标比特率", selection: Binding(get: { block.bitRate }, set: { v in store.updateBlock(block.id) { $0.bitRate = v } })) { ForEach([128,192,256,320], id: \.self) { Text("\($0) kbps").tag($0) } }
            } else {
                Picker("位深", selection: Binding(get: { block.bitDepth }, set: { v in store.updateBlock(block.id) { $0.bitDepth = v } })) {
                    Text("16 bit").tag(16); Text("24 bit").tag(24)
                    if block.format == .wav || block.format == .aiff { Text("32 bit float").tag(32) }
                }
            }
            Picker("自动分段", selection: Binding(get: { block.splitMinutes }, set: { v in store.updateBlock(block.id) { $0.splitMinutes = v } })) {
                Text("不自动分段").tag(0.0); Text("每 1 分钟").tag(1.0); Text("每 5 分钟").tag(5.0); Text("每 15 分钟").tag(15.0); Text("每 30 分钟").tag(30.0); Text("每 60 分钟").tag(60.0)
            }
        }.font(.system(size: 13)).disabled(locked)
        VStack(alignment: .leading, spacing: 7) {
            Text("保存位置").font(.system(size: 13, weight: .semibold))
            Text(store.recordFolder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.system(size: 12)).foregroundStyle(StudioTheme.muted).lineLimit(2)
            HStack { Button("更改…") { store.chooseFolder() }.disabled(locked); Button("打开文件夹") { try? FileManager.default.createDirectory(at: store.recordFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(store.recordFolder) } }.font(.system(size: 12))
            Text("参数在开始时确定；运行中可暂停和分段，停止后可另存其他格式。").font(.system(size: 12)).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

