// 判定 NSBitmapImageRep.colorAt(x:y:) 的 y 轴方向：y=0 是顶行还是底行？
// 构造一张 2×2 图：第 0 行（CGImage 语义下的顶行）= 纯红，第 1 行 = 纯蓝。
import AppKit

var bytes: [UInt8] = [
    255, 0, 0, 255,   255, 0, 0, 255,   // 顶行：红
    0, 0, 255, 255,   0, 0, 255, 255    // 底行：蓝
]

let space = CGColorSpaceCreateDeviceRGB()
let provider = CGDataProvider(data: Data(bytes) as CFData)!
let image = CGImage(
    width: 2, height: 2,
    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
    space: space,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
)!

let rep = NSBitmapImageRep(cgImage: image)

func describe(_ color: NSColor?) -> String {
    guard let color = color?.usingColorSpace(.deviceRGB) else { return "nil" }
    if color.redComponent > 0.5 && color.blueComponent < 0.5 { return "红(RED)" }
    if color.blueComponent > 0.5 && color.redComponent < 0.5 { return "蓝(BLUE)" }
    return String(format: "其他(%.2f, %.2f, %.2f)", color.redComponent, color.greenComponent, color.blueComponent)
}

print("colorAt(0, 0) =", describe(rep.colorAt(x: 0, y: 0)))
print("colorAt(0, 1) =", describe(rep.colorAt(x: 0, y: 1)))
print("---")
print("若 (0,0) 是红色 → y=0 为顶行（图像坐标系，y 向下）")
print("若 (0,0) 是蓝色 → y=0 为底行（数学坐标系，y 向上）")
