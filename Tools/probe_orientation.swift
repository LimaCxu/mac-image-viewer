// 判定「用 CGContext.draw 画 CGImage」是否与 AppKit 原生绘制的上下方向一致。
// 与坐标约定无关的判据：同一 readback 行上，左右两半的颜色必须相同。
import AppKit

final class ProbeView: NSView {
    let source: CGImage

    init(frame: NSRect, source: CGImage) {
        self.source = source
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width
        let h = bounds.height

        // 左半：AppKit 原生填充。flipped 视图里 y=0 在顶部。
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: w / 2, height: h / 2).fill()      // 左上 = 红
        NSColor.blue.setFill()
        NSRect(x: 0, y: h / 2, width: w / 2, height: h / 2).fill()  // 左下 = 蓝

        // 右半：用与 App 完全相同的代码路径绘制 CGImage（顶行红、底行蓝）
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: w * 0.75, y: h / 2)
        ctx.draw(source, in: CGRect(x: -w / 4, y: -h / 2, width: w / 2, height: h))
        ctx.restoreGState()
    }
}

// 2×1 源图：顶行红，底行蓝
var bytes: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255,
                      0, 0, 255, 255, 0, 0, 255, 255]
let provider = CGDataProvider(data: Data(bytes) as CFData)!
let source = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false,
                     intent: .defaultIntent)!

let view = ProbeView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), source: source)
let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: rep)

func describe(_ x: Int, _ y: Int) -> String {
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return "nil" }
    if color.redComponent > 0.5 && color.blueComponent < 0.5 { return "红" }
    if color.blueComponent > 0.5 && color.redComponent < 0.5 { return "蓝" }
    return String(format: "(%.2f,%.2f,%.2f)", color.redComponent, color.greenComponent, color.blueComponent)
}

let upper = 25, lower = 75
// 回读位图可能带 Retina 倍率，必须按真实像素尺寸换算采样点
let leftX = Int(0.25 * Double(rep.pixelsWide))
let rightX = Int(0.75 * Double(rep.pixelsWide))
let upperY = Int(0.25 * Double(rep.pixelsHigh))
let lowerY = Int(0.75 * Double(rep.pixelsHigh))

let leftUpper = describe(leftX, upperY), leftLower = describe(leftX, lowerY)
let rightUpper = describe(rightX, upperY), rightLower = describe(rightX, lowerY)

print("readback 尺寸: \(rep.pixelsWide)×\(rep.pixelsHigh)  采样: 左x=\(leftX) 右x=\(rightX) 上y=\(upperY) 下y=\(lowerY)")
print("左半(AppKit 填充)  上=\(leftUpper)  下=\(leftLower)")
print("右半(CGImage 绘制) 上=\(rightUpper)  下=\(rightLower)")
print("---")
if rightUpper == leftUpper && rightLower == leftLower {
    print("结论：CGImage 绘制方向与 AppKit 一致 → 屏幕上是正立的")
} else {
    print("结论：CGImage 绘制与 AppKit 不一致 → 屏幕上上下颠倒，需要修正绘制代码")
}
