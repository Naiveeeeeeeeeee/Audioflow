import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16,32,64,128,256,512,1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    rep.size = NSSize(width: size, height: size)
    rep.bitmapData!.initialize(repeating: 0, count: rep.bytesPerRow * size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let box = NSRect(x: s*0.08, y: s*0.08, width: s*0.84, height: s*0.84)
    let shape = NSBezierPath(roundedRect: box, xRadius: s*0.18, yRadius: s*0.18)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowOffset = NSSize(width: 0, height: -s*0.018); shadow.shadowBlurRadius = s*0.025; shadow.set()
    NSColor.black.setFill(); shape.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.055, green: 0.057, blue: 0.065, alpha: 1)])!.draw(in: shape, angle: -75)
    let edge = NSBezierPath(roundedRect: box.insetBy(dx: s*0.012, dy: s*0.012), xRadius: s*0.17, yRadius: s*0.17)
    edge.lineWidth = max(0.5, s*0.007); NSColor(srgbRed: 0.62, green: 0.52, blue: 0.31, alpha: 0.65).setStroke(); edge.stroke()
    let gold = NSColor(srgbRed: 0.94, green: 0.77, blue: 0.39, alpha: 1)
    let bright = NSColor(srgbRed: 1, green: 0.91, blue: 0.62, alpha: 1)
    let mic = NSBezierPath(roundedRect: NSRect(x:s*0.425,y:s*0.43,width:s*0.15,height:s*0.29),xRadius:s*0.075,yRadius:s*0.075)
    NSGradient(starting: bright, ending: NSColor(srgbRed: 0.63, green: 0.43, blue: 0.13, alpha: 1))!.draw(in: mic, angle: -50)
    for y: CGFloat in [0.49,0.535,0.58,0.625] {
        let slit = NSBezierPath(roundedRect: NSRect(x:s*0.451,y:s*y,width:s*0.098,height:max(0.7,s*0.012)),xRadius:s*0.006,yRadius:s*0.006)
        NSColor(srgbRed: 0.24, green: 0.18, blue: 0.09, alpha: 0.8).setFill(); slit.fill()
    }
    let cradle = NSBezierPath(); cradle.lineWidth = max(0.9,s*0.022); cradle.lineCapStyle = .round; cradle.lineJoinStyle = .round
    cradle.move(to: NSPoint(x:s*0.37,y:s*0.55)); cradle.line(to:NSPoint(x:s*0.37,y:s*0.46))
    cradle.curve(to:NSPoint(x:s*0.63,y:s*0.46),controlPoint1:NSPoint(x:s*0.37,y:s*0.29),controlPoint2:NSPoint(x:s*0.63,y:s*0.29))
    cradle.line(to:NSPoint(x:s*0.63,y:s*0.55)); gold.setStroke(); cradle.stroke()
    let stand = NSBezierPath(); stand.lineWidth = max(0.9,s*0.022); stand.lineCapStyle = .round
    stand.move(to:NSPoint(x:s*0.5,y:s*0.355));stand.line(to:NSPoint(x:s*0.5,y:s*0.29))
    stand.move(to:NSPoint(x:s*0.415,y:s*0.285));stand.line(to:NSPoint(x:s*0.585,y:s*0.285));gold.setStroke();stand.stroke()
    let incoming = NSBezierPath(); incoming.lineWidth = max(0.8,s*0.018); incoming.lineCapStyle = .round; incoming.lineJoinStyle = .round
    incoming.move(to:NSPoint(x:s*0.225,y:s*0.56));incoming.line(to:NSPoint(x:s*0.315,y:s*0.56))
    incoming.move(to:NSPoint(x:s*0.28,y:s*0.605));incoming.line(to:NSPoint(x:s*0.325,y:s*0.56));incoming.line(to:NSPoint(x:s*0.28,y:s*0.515));gold.setStroke();incoming.stroke()
    let record = NSBezierPath(ovalIn:NSRect(x:s*0.65,y:s*0.275,width:s*0.115,height:s*0.115));gold.setFill();record.fill()
    let inner = NSBezierPath(ovalIn:NSRect(x:s*0.679,y:s*0.304,width:s*0.057,height:s*0.057));NSColor(srgbRed: 0.09, green: 0.085, blue: 0.07, alpha: 1).setFill();inner.fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16.png"]
    case 32: names = ["icon_16x16@2x.png","icon_32x32.png"]
    case 64: names = ["icon_32x32@2x.png"]
    case 128: names = ["icon_128x128.png"]
    case 256: names = ["icon_128x128@2x.png","icon_256x256.png"]
    case 512: names = ["icon_256x256@2x.png","icon_512x512.png"]
    default: names = ["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to: root.appendingPathComponent(name)) }
}
