import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum StudioTheme {
    static let cyan = Color(red: 0.0, green: 0.686, blue: 0.843)
    static let darkCyan = Color(red: 0.0, green: 0.522, blue: 0.647)
    static let ink = Color(red: 0.15, green: 0.19, blue: 0.22)
    static let muted = Color(red: 0.38, green: 0.43, blue: 0.47)
    static let canvas = Color(red: 0.933, green: 0.933, blue: 0.933)
    static let line = Color(red: 0.87, green: 0.90, blue: 0.91)
    static let panel = Color(red: 0.985, green: 0.988, blue: 0.99)
}

enum StudioLayout {
    static let nodeWidth: Double = 106
    static let nodeHeight: Double = 106
    static let column: Double = 156
    static let row: Double = 148
    static let sidebar: Double = 148
    static let inspector: Double = 268
}

// Only the sidebar samples behind the window. The window and toolbar remain opaque.
struct NativePanel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); configure(view); return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { configure(view) }
    private func configure(_ view: NSVisualEffectView) {
        view.material = .underWindowBackground; view.blendingMode = .behindWindow
        view.isEmphasized = true; view.state = .active; view.appearance = NSAppearance(named: .aqua)
    }
}

struct StudioGlass: ViewModifier {
    var radius: CGFloat = 12
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.foregroundStyle(StudioTheme.ink)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.foregroundStyle(StudioTheme.ink)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }
}

struct FlowCanvas: View {
    @ObservedObject var store: StudioStore
    @State private var dropTarget = false
    private let nodeWidth = StudioLayout.nodeWidth
    private let nodeHeight = StudioLayout.nodeHeight
    var graphWidth: Double { store.session.blocks.map { $0.x + nodeWidth + 24 }.max() ?? 360 }
    var graphHeight: Double { store.session.blocks.map { $0.y + nodeHeight + 28 }.max() ?? 280 }
    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(geometry.size.width / store.zoom, graphWidth)
            let contentHeight = max(geometry.size.height / store.zoom, graphHeight)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { store.selectedBlockID = nil; store.selectedWireID = nil; store.pendingConnection = nil }
                    ForEach(store.session.wires) { wire in
                        if let from = store.session.blocks.first(where: { $0.id == wire.from }), let to = store.session.blocks.first(where: { $0.id == wire.to }) {
                            WireView(from: CGPoint(x: from.x + nodeWidth, y: from.y + nodeHeight / 2), to: CGPoint(x: to.x, y: to.y + nodeHeight / 2), selected: store.selectedWireID == wire.id, live: store.running && (store.levels[from.id]?.left ?? -90) > -70)
                                .onTapGesture { store.selectedWireID = wire.id; store.selectedBlockID = nil }
                                .contextMenu { Button("删除连线", role: .destructive) { store.selectedWireID = wire.id; store.deleteSelection() }.disabled(store.running || store.busy) }
                        }
                    }
                    ForEach(store.session.blocks) { block in
                        AudioBlockView(store: store, block: block)
                            .position(x: block.x + nodeWidth / 2, y: block.y + nodeHeight / 2)
                    }
                    if store.session.blocks.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "square.stack.3d.up").font(.system(size: 38, weight: .light)).foregroundStyle(StudioTheme.cyan)
                            Text("从一个声音来源开始").font(.system(size: 19, weight: .semibold))
                            Text("把右侧模块拖到画布，再连接圆形端口。").foregroundStyle(StudioTheme.muted)
                            Button("添加应用声音") { store.addBlock(.application) }.buttonStyle(.borderedProminent)
                        }.position(x: 430, y: 260)
                    }
                }
                .frame(width: contentWidth, height: contentHeight)
                .scaleEffect(store.zoom, anchor: .topLeading)
                .frame(width: contentWidth * store.zoom, height: contentHeight * store.zoom, alignment: .topLeading)
                .onDrop(of: [UTType.plainText], isTargeted: $dropTarget) { providers, point in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: String.self) { value, _ in
                        guard let value, value.hasPrefix("soundflow:"), let kind = BlockKind(rawValue: String(value.dropFirst(10))) else { return }
                        Task { @MainActor in store.addBlock(kind, at: CGPoint(x: max(24, point.x / store.zoom - nodeWidth / 2), y: max(24, point.y / store.zoom - nodeHeight / 2))) }
                    }
                    return true
                }
            }
            .scrollIndicators(.hidden)
            .background(StudioTheme.canvas)
            .overlay(alignment: .topLeading) {
                if let from = store.pendingConnection, let block = store.session.blocks.first(where: { $0.id == from }) {
                    Label("\(block.name) → 点击目标模块左侧圆点 · Esc 取消", systemImage: "link")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9)
                        .modifier(StudioGlass(radius: 16)).padding(12)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !store.toast.isEmpty {
                    Text(store.toast).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(StudioTheme.ink.opacity(0.9), in: Capsule()).foregroundStyle(.white).padding(18)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 0) {
                    Button { store.zoom = max(0.5, store.zoom - 0.1) } label: { Image(systemName: "minus").frame(width: 30, height: 28) }.help("缩小")
                    Text("\(Int(store.zoom * 100))%").font(.system(size: 12, weight: .medium, design: .monospaced)).frame(width: 46)
                    Button { store.zoom = min(1.5, store.zoom + 0.1) } label: { Image(systemName: "plus").frame(width: 30, height: 28) }.help("放大")
                    Divider().frame(height: 16)
                    Button { store.zoom = max(0.5, min(1.15, (geometry.size.width - 8) / graphWidth)) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 32, height: 28) }.help("适合画布")
                }.buttonStyle(StudioButtonStyle()).padding(4).modifier(StudioGlass()).shadow(color: .black.opacity(0.1), radius: 8, y: 3).padding(12)
            }
        }
    }
}

struct WireView: View {
    var from: CGPoint
    var to: CGPoint
    var selected: Bool
    var live: Bool
    var path: Path {
        var p = Path(); p.move(to: from)
        let bend = to.x > from.x ? max(8, min(80, (to.x - from.x) * 0.45)) : max(55, abs(to.x - from.x) * 0.45)
        p.addCurve(to: to, control1: CGPoint(x: from.x + bend, y: from.y), control2: CGPoint(x: to.x - bend, y: to.y))
        return p
    }
    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.001), style: StrokeStyle(lineWidth: 18))
            path.stroke(selected ? StudioTheme.darkCyan : StudioTheme.cyan.opacity(live ? 1 : 0.68), style: StrokeStyle(lineWidth: selected ? 3.5 : 2.5, lineCap: .round))
        }.contentShape(path.strokedPath(StrokeStyle(lineWidth: 18)))
    }
}

struct AudioBlockView: View {
    @ObservedObject var store: StudioStore
    let block: AudioBlock
    @State private var dragOrigin: CGPoint?
    @State private var hovered = false
    var selected: Bool { store.selectedBlockID == block.id }
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(block.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if !block.enabled { Image(systemName: "power").font(.system(size: 10)) }
                }.padding(.horizontal, 9).frame(height: 22).background(StudioTheme.darkCyan)
                VStack(spacing: 4) {
                    if block.kind == .application { ApplicationChooser(store: store, blockID: block.id, onCard: true) }
                    else {
                        visual.frame(height: 32)
                        Text(subtitle).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 5)
                    }
                    if block.kind == .recorder && store.running {
                        HStack(spacing: 8) {
                            Text(timeString(store.recorderTimes[block.id] ?? 0)).monospacedDigit()
                            Button { store.pauseRecorder(block.id) } label: { Image(systemName: store.recordingPausedIDs.contains(block.id) ? "play.fill" : "pause.fill") }.buttonStyle(StudioButtonStyle()).help("暂停／继续此录音机")
                        }.font(.system(size: 11, weight: .medium))
                    } else if store.running {
                        TinyMeter(level: store.levels[block.id] ?? Level(), white: true).frame(width: 80, height: 4)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: StudioLayout.nodeWidth, height: StudioLayout.nodeHeight)
            .foregroundStyle(.white)
            .background(StudioTheme.cyan, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(selected ? StudioTheme.darkCyan.opacity(0.6) : .clear, lineWidth: 1.5).padding(-3))
            .shadow(color: .black.opacity(selected || hovered ? 0.27 : 0.22), radius: 13, x: 0, y: 7)
            .shadow(color: .black.opacity(0.13), radius: 3, x: 0, y: 2)
            .onHover { hovered = $0 }
            .opacity(block.enabled ? 1 : 0.52)
            .onTapGesture { store.selectedBlockID = block.id; store.selectedWireID = nil; store.inspectorTab = "模块" }
            .gesture(DragGesture(minimumDistance: 5).onChanged { value in
                guard !store.running && !store.busy else { return }
                if dragOrigin == nil { dragOrigin = CGPoint(x: block.x, y: block.y); store.selectedBlockID = block.id }
                if let origin = dragOrigin { store.updateBlock(block.id) { $0.x = max(18, min(4500, origin.x + value.translation.width / store.zoom)); $0.y = max(18, min(3500, origin.y + value.translation.height / store.zoom)) } }
            }.onEnded { _ in dragOrigin = nil; store.saveSoon() })
            .contextMenu {
                Button("编辑模块") { store.selectedBlockID = block.id; store.inspectorTab = "模块" }
                Button("复制模块") { var b = block; b.id = UUID(); b.x += 24; b.y += StudioLayout.row; store.updateSession { $0.blocks.append(b) }; store.selectedBlockID = b.id }.disabled(store.running || store.busy)
                Button("删除模块", role: .destructive) { store.selectedBlockID = block.id; store.deleteSelection() }.disabled(store.running || store.busy)
            }
            if !block.kind.isSource {
                Button { store.connect(to: block.id) } label: {
                    Circle().fill(StudioTheme.cyan.opacity(0.45)).frame(width: 7, height: 7).overlay(Circle().stroke(StudioTheme.darkCyan, lineWidth: 1)).frame(width: 24, height: 28)
                }.buttonStyle(StudioButtonStyle()).position(x: 0, y: StudioLayout.nodeHeight / 2).help("输入端口：连接选中的声音来源")
            }
            if block.kind != .output {
                Button {
                    guard !store.running && !store.busy else { store.showToast("停止后即可修改连线。"); return }
                    store.pendingConnection = store.pendingConnection == block.id ? nil : block.id
                } label: {
                    Circle().fill(store.pendingConnection == block.id ? StudioTheme.ink : StudioTheme.cyan.opacity(0.45)).frame(width: 7, height: 7).overlay(Circle().stroke(StudioTheme.darkCyan, lineWidth: 1)).frame(width: 24, height: 28)
                }.buttonStyle(StudioButtonStyle()).position(x: StudioLayout.nodeWidth, y: StudioLayout.nodeHeight / 2).help("输出端口：点选后连接目标的输入端口")
            }
        }.frame(width: StudioLayout.nodeWidth, height: StudioLayout.nodeHeight).accessibilityElement(children: .contain).accessibilityLabel("\(block.name)，\(subtitle)")
    }
    @ViewBuilder var visual: some View {
        if block.kind == .application, let app = store.apps.first(where: { $0.id == block.bundleID }), let icon = app.icon {
            Image(nsImage: icon).resizable().scaledToFit().frame(width: 42, height: 42).shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        } else if block.kind == .recorder {
            Text(block.format.rawValue.uppercased()).font(.system(size: 20, weight: .bold, design: .rounded))
        } else if block.kind == .gain || block.kind == .mixer {
            Text(String(format: "%+.1f", block.gain)).font(.system(size: 22, weight: .semibold, design: .rounded)) + Text(" dB").font(.system(size: 10, weight: .medium))
        } else if block.kind == .equalizer {
            HStack(alignment: .center, spacing: 3) { ForEach(0..<10, id: \.self) { i in Capsule().fill(.white.opacity(0.9)).frame(width: 4, height: 8 + abs(block.bands[i]) * 0.75 + Double(i % 3) * 4) } }.frame(height: 32)
        } else if block.kind == .meter {
            StereoMeter(level: store.levels[block.id] ?? Level(), white: true).frame(width: 88, height: 28)
        } else { Image(systemName: block.kind.symbol).font(.system(size: 31, weight: .regular)) }
    }
    var subtitle: String {
        switch block.kind {
        case .application: return store.apps.first(where: { $0.id == block.bundleID })?.name ?? (block.bundleID.isEmpty ? "点击选择应用" : "应用未运行")
        case .system: return "系统播放音频"
        case .microphone: return "系统默认输入"
        case .file: return block.filePath.isEmpty ? "点击选择音频文件" : (block.loop ? "循环播放" : "文件播放")
        case .tone: return "\(Int(block.frequency)) Hz · 正弦波"
        case .recorder: return "\(block.format.lossy ? "\(block.bitRate) kbps" : "\(block.bitDepth) bit") · \(block.channels == 2 ? "立体声" : "单声道")"
        case .output: return block.monitor ? (store.devices.first { $0.id == block.outputDeviceID }?.name ?? "系统默认输出") : "监听关闭"
        case .compressor: return "阈值 \(Int(block.threshold)) dB"
        case .limiter: return "峰值保护"
        case .meter: return String(format: "RMS %.1f dB", (store.levels[block.id] ?? Level()).rms)
        case .gain, .mixer: return block.pan == 0 ? "左右居中" : (block.pan < 0 ? "声像偏左" : "声像偏右")
        case .equalizer: return block.bands.allSatisfy { $0 == 0 } ? "平直" : "自定义均衡"
        }
    }
}

struct TinyMeter: View {
    var level: Level
    var white = false
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(white ? Color.white.opacity(0.22) : Color.black.opacity(0.07))
                Capsule().fill(level.clipped ? Color.red : (white ? Color.white.opacity(0.9) : StudioTheme.cyan))
                    .frame(width: max(0, g.size.width * CGFloat(min(1, max(0, (max(level.left, level.right) + 60) / 60)))))
            }
        }
    }
}

struct StereoMeter: View {
    var level: Level
    var white = false
    var dark = false
    var detailed = false
    @State private var left: Float = -90
    @State private var right: Float = -90
    @State private var holdLeft: Float = -90
    @State private var holdRight: Float = -90
    @State private var leftAt = Date.distantPast
    @State private var rightAt = Date.distantPast
    @State private var updatedAt = Date()
    @State private var clipUntil = Date.distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var foreground: Color { white || dark ? .white : StudioTheme.ink }
    var body: some View {
        VStack(spacing: detailed ? 4 : 3) {
            channel("L", db: left, held: holdLeft)
            channel("R", db: right, held: holdRight)
            if detailed {
                HStack(spacing: 5) {
                    Color.clear.frame(width: 8)
                    GeometryReader { geo in
                        ForEach([-60, -24, -12, 0], id: \.self) { db in
                            Text("\(db)").font(.system(size: 7, design: .monospaced))
                                .position(x: max(8, min(geo.size.width - 5, geo.size.width * CGFloat(db + 60) / 60)), y: 4)
                        }
                    }.frame(height: 8)
                    Color.clear.frame(width: 34)
                }.foregroundStyle(foreground.opacity(0.5))
            }
        }
        .onChange(of: level, initial: true) { _, incoming in update(incoming) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("左右声道电平")
        .accessibilityValue(String(format: "左 %.1f dB，右 %.1f dB%@", level.left, level.right, level.clipped ? "，过载" : ""))
    }
    private func normalized(_ db: Float) -> CGFloat { CGFloat(min(1, max(0, ((db.isFinite ? db : -90) + 60) / 60))) }
    private var gradient: LinearGradient {
        LinearGradient(stops: white ? [.init(color: .white.opacity(0.72), location: 0), .init(color: .white, location: 0.78), .init(color: .yellow, location: 0.91), .init(color: .red, location: 1)] : [.init(color: StudioTheme.cyan, location: 0), .init(color: .mint, location: 0.65), .init(color: .yellow, location: 0.9), .init(color: .red, location: 1)], startPoint: .leading, endPoint: .trailing)
    }
    private func channel(_ name: String, db: Float, held: Float) -> some View {
        HStack(spacing: 5) {
            Text(name).font(.system(size: 8, weight: .semibold, design: .monospaced)).foregroundStyle(foreground.opacity(0.65)).frame(width: 8)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(white || dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                    gradient.clipShape(Capsule()).mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * normalized(db)) }
                    if held > -60 {
                        Capsule().fill(held >= -0.2 ? Color.red : foreground.opacity(0.88))
                            .frame(width: 1.5).offset(x: max(0, min(geo.size.width - 1.5, geo.size.width * normalized(held))))
                    }
                }.clipShape(Capsule())
            }.frame(height: detailed ? 6 : 5)
            if detailed {
                Text(Date() < clipUntil ? "CLIP" : db <= -60 ? "−∞" : String(format: "%.1f", db))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Date() < clipUntil ? Color.red : foreground.opacity(0.9)).frame(width: 34, alignment: .trailing)
            }
        }
    }
    private func update(_ incoming: Level) {
        let now = Date(), delta = Float(min(0.2, now.timeIntervalSince(updatedAt))); updatedAt = now
        let newLeft = incoming.left.isFinite ? incoming.left : -90, newRight = incoming.right.isFinite ? incoming.right : -90
        if newLeft >= holdLeft { holdLeft = newLeft; leftAt = now }
        else if now.timeIntervalSince(leftAt) > 0.8 { holdLeft = max(newLeft, holdLeft - delta * 18) }
        if newRight >= holdRight { holdRight = newRight; rightAt = now }
        else if now.timeIntervalSince(rightAt) > 0.8 { holdRight = max(newRight, holdRight - delta * 18) }
        if incoming.clipped { clipUntil = now.addingTimeInterval(1) }
        if newLeft <= -89 && newRight <= -89 { holdLeft = -90; holdRight = -90; clipUntil = .distantPast }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) { left = newLeft; right = newRight }
    }
}

struct WaveformView: View {
    var points: [Float]
    var progress: Double = 0
    var active = false
    var body: some View {
        Canvas { context, size in
            guard !points.isEmpty else {
                context.stroke(Path { p in p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2)) }, with: .color(StudioTheme.line), lineWidth: 1)
                return
            }
            let step = size.width / CGFloat(points.count)
            for (i, value) in points.enumerated() {
                let height = max(1, CGFloat(value) * size.height)
                let rect = CGRect(x: CGFloat(i) * step, y: (size.height - height) / 2, width: max(1, step - 1), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Double(i) / Double(points.count) <= progress && active ? StudioTheme.cyan : StudioTheme.ink.opacity(0.35)))
            }
        }.accessibilityLabel("录音波形")
    }
}
