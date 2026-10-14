// 探针：ImageIO 对 EXIF 字典里的 rational（光圈/快门/焦距）究竟返回什么类型？
import Foundation
import ImageIO

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test-images/06-exif.jpg"
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
    print("无法读取"); exit(1)
}

print("顶层键:", props.keys.map { $0 as String }.sorted().joined(separator: ", "))
for (key, value) in props {
    guard let dict = value as? [CFString: Any] else { continue }
    print("\n== \(key)（\(dict.count) 项）")
    for (subKey, subValue) in dict.sorted(by: { ($0.key as String) < ($1.key as String) }) {
        let typeName = String(describing: type(of: subValue))
        let asNumber = (subValue as? NSNumber)?.doubleValue
        print("   \(subKey as String) = \(subValue)   type=\(typeName)   asNSNumber=\(asNumber.map { String($0) } ?? "nil")")
    }
}
