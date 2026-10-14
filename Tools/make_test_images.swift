// 生成自检所需的测试图（全部是本工具现造的合成图，不含任何第三方素材）。
//
// 用法: swiftc -O -o make_test_images Tools/make_test_images.swift && ./make_test_images 输出目录
//
// 注意渐变方向：自检会验证「图像没有被上下画反」，依赖这里的
// 「顶部暗、底部亮」。CGContext 原点在左下、y 向上，而 CGImage 第 0 行是顶行，
// 所以 y 越大的位置要越暗。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test-images")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func makeGradient(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    for y in 0..<height {
        let t = CGFloat(y) / CGFloat(height)          // 0 = 底部, 1 = 顶部
        context.setFillColor(CGColor(red: 1 - t, green: 0.4, blue: 0.2 + 0.6 * t, alpha: 1))
        context.fill(CGRect(x: 0, y: y, width: width, height: 1))
    }
    // 加一个白色内框，让画面有非渐变特征（也便于人工肉眼确认方向）
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.setLineWidth(CGFloat(max(width, height)) / 200)
    context.stroke(CGRect(x: CGFloat(width) * 0.1, y: CGFloat(height) * 0.1,
                          width: CGFloat(width) * 0.8, height: CGFloat(height) * 0.8))
    return context.makeImage()!
}

@discardableResult
func write(_ image: CGImage, to name: String, type: UTType, quality: Double = 0.9, properties: [CFString: Any] = [:]) -> Bool {
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
        print("✗ 无法写入 \(name)"); return false
    }
    var merged = properties
    if type == .jpeg { merged[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, merged as CFDictionary)
    let ok = CGImageDestinationFinalize(destination)
    print(ok ? "✓ \(name)" : "✗ \(name)")
    return ok
}

// 1) 常规尺寸：横向 / 纵向 / 小图 / 大图
write(makeGradient(width: 2400, height: 1400), to: "01-landscape.png", type: .png)
write(makeGradient(width: 900, height: 1600), to: "02-portrait.png", type: .png)
write(makeGradient(width: 320, height: 200), to: "03-small.png", type: .png)
write(makeGradient(width: 6000, height: 4000), to: "04-huge.jpg", type: .jpeg, quality: 0.85)

// 2) 带 EXIF 的样本。必须用 ImageIO 自己写：
//    PIL 等库写出的 rational（FNumber/ExposureTime/FocalLength）类型不合规，
//    ImageIO 会静默丢弃这三个标签，导致自检出现假失败。
let exif: [CFString: Any] = [
    kCGImagePropertyExifFNumber: 2.8,
    kCGImagePropertyExifExposureTime: 1.0 / 250.0,
    kCGImagePropertyExifFocalLength: 35.0,
    kCGImagePropertyExifISOSpeedRatings: [400],
    kCGImagePropertyExifDateTimeOriginal: "2026:10:14 15:30:00",
    kCGImagePropertyExifFlash: 0
]
let tiff: [CFString: Any] = [
    kCGImagePropertyTIFFMake: "TestCamera",
    kCGImagePropertyTIFFModel: "Model X100",
    kCGImagePropertyTIFFSoftware: "TestSoft 1.0",
    kCGImagePropertyTIFFOrientation: 1
]
write(
    makeGradient(width: 880, height: 620),
    to: "05-exif.jpg",
    type: .jpeg,
    quality: 0.9,
    properties: [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff
    ]
)

print("完成，输出目录: \(outputDirectory.path)")
