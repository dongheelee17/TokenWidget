// 앱 아이콘 생성: swift tools/make_icon.swift <출력.png>
import AppKit

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}
let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]

// path 안을 그라데이션으로 채움
func fill(_ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint) {
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: extend)
    ctx.restoreGState()
}
// path 테두리를 그라데이션으로 그림 (빛 테두리용)
func rim(_ path: CGPath, width: CGFloat, _ g: CGGradient, from a: CGPoint, to b: CGPoint, blur: CGFloat = 0, glow: CGColor? = nil) {
    ctx.saveGState()
    if let glow { ctx.setShadow(offset: .zero, blur: blur, color: glow) }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(path); ctx.setLineWidth(width); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: extend)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// MARK: 타일 (살짝 투명하지만 선명한 글래스)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 26, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0x262828, 0.9)); ctx.fillPath()
ctx.restoreGState()
fill(tilePath, gradient([rgb(0x4C5050, 0.92), rgb(0x313434, 0.9), rgb(0x1C1E1E, 0.92)], [0, 0.5, 1]),
     from: CGPoint(x: 300, y: 924), to: CGPoint(x: 724, y: 100))
// 날카로운 테두리 반사광: 왼쪽 위·오른쪽 아래가 빛남
rim(tilePath, width: 4, gradient([rgb(0xFFFFFF, 0.7), rgb(0xFFFFFF, 0.08), rgb(0xFFFFFF, 0.04), rgb(0xFFFFFF, 0.35)], [0, 0.35, 0.65, 1]),
    from: CGPoint(x: 100, y: 924), to: CGPoint(x: 924, y: 100))

// MARK: 반짝이
func sparkle(center p: CGPoint, size s: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let k = s * 0.14
    path.move(to: CGPoint(x: p.x, y: p.y + s))
    path.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: CGPoint(x: p.x + k, y: p.y + k))
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: CGPoint(x: p.x + k, y: p.y - k))
    path.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: CGPoint(x: p.x - k, y: p.y - k))
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: CGPoint(x: p.x - k, y: p.y + k))
    path.closeSubpath()
    return path
}
let sc = CGPoint(x: 320, y: 700), ss: CGFloat = 105
let star = sparkle(center: sc, size: ss)
fill(star, gradient([rgb(0xFFFFFF), rgb(0xF4F5F6), rgb(0xDADDE0)], [0, 0.5, 1]),
     from: CGPoint(x: sc.x - ss, y: sc.y + ss), to: CGPoint(x: sc.x + ss, y: sc.y - ss))
rim(star, width: 3, gradient([rgb(0xFFFFFF, 1), rgb(0xFFFFFF, 0.2), rgb(0xFFFFFF, 0.7)], [0, 0.5, 1]),
    from: CGPoint(x: sc.x - ss, y: sc.y + ss), to: CGPoint(x: sc.x + ss, y: sc.y - ss))

// MARK: 막대
let track = CGRect(x: 210, y: 300, width: 604, height: 76)
let trackPath = CGPath(roundedRect: track, cornerWidth: 38, cornerHeight: 38, transform: nil)
ctx.addPath(trackPath); ctx.setFillColor(rgb(0xFFFFFF, 0.14)); ctx.fillPath()
rim(trackPath, width: 3, gradient([rgb(0xFFFFFF, 0.05), rgb(0xFFFFFF, 0.35)], [0, 1]),
    from: CGPoint(x: 0, y: track.maxY), to: CGPoint(x: 0, y: track.minY))

var bar = track; bar.size.width *= 0.7
let barPath = CGPath(roundedRect: bar, cornerWidth: 38, cornerHeight: 38, transform: nil)
fill(barPath, gradient([rgb(0xFFFFFF), rgb(0xEEEFF0), rgb(0xDFE1E3)], [0, 0.5, 1]),
     from: CGPoint(x: 0, y: bar.maxY), to: CGPoint(x: 0, y: bar.minY))
rim(barPath, width: 3, gradient([rgb(0xFFFFFF, 1), rgb(0xFFFFFF, 0.2), rgb(0xFFFFFF, 0.6)], [0, 0.5, 1]),
    from: CGPoint(x: 0, y: bar.maxY), to: CGPoint(x: 0, y: bar.minY))

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
