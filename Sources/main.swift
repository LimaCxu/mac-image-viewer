// 看图 — 一个原生 macOS 图片浏览器
// 目标：翻页 / 旋转 / 缩放 / 全屏 / 拖放，全部键盘可达。
// 解码完全交给系统 ImageIO（EXIF 方向自动应用），不自己写解码器。

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 常量与工具

private let kPreviewMaxPixel = 1600
private let kMaxMagnification: CGFloat = 32.0
private let kDefaultSlideshowInterval: TimeInterval = 3.0
private let kMaxFolderFiles = 5000

/// 用户偏好键
private enum DefaultsKey {
    static let slideshowInterval = "slideshowInterval"
    static let openAtActualSize = "openAtActualSize"
    static let darkBackground = "darkBackground"
}

private func isImageURL(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    let ext = url.pathExtension.lowercased()
    guard !ext.isEmpty else { return false }
    if let type = UTType(filenameExtension: ext) {
        return type.conforms(to: .image) || type.conforms(to: .rawImage) || type.conforms(to: .pdf)
    }
    return false
}

// MARK: - 画布

final class ImageCanvas: NSView {
    weak var controller: ViewerController?

    var image: CGImage? {
        didSet { needsDisplay = true }
    }
    var quarterTurns: Int = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        (controller?.canvasBackgroundColor ?? NSColor.underPageBackgroundColor).setFill()
        bounds.fill()

        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let scale = controller?.scaleFactor ?? 2.0
        let w = CGFloat(image.width) / scale
        let h = CGFloat(image.height) / scale

        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: CGFloat(quarterTurns) * .pi / 2)
        // 注意：在 flipped 视图里 CGContext.draw 会把 CGImage 上下画反（已由 --selftest 验证），
        // 这里在图像本地坐标系内抵消，旋转任意 90° 倍数都正确。
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: 缩放手势

    override func magnify(with event: NSEvent) {
        controller?.zoom(by: 1 + event.magnification,
                         atPoint: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command), abs(event.scrollingDeltaY) > 0.001 {
            controller?.zoom(by: exp(event.scrollingDeltaY * 0.01),
                             atPoint: convert(event.locationInWindow, from: nil))
            return
        }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            controller?.toggleFitActual()
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: 拖放

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        controller?.open(urls: urls)
        return true
    }
}

// MARK: - 让图片在窗口里居中

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if doc.frame.height < rect.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

// MARK: - 窗口（兜住没有被画布处理的按键）

final class ViewerWindow: NSWindow {
    weak var controller: ViewerController?

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - 主控制器

final class ViewerController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate {

    private enum ZoomMode { case fit, custom }

    private enum ToolbarID {
        static let open = NSToolbarItem.Identifier("open")
        static let prev = NSToolbarItem.Identifier("prev")
        static let next = NSToolbarItem.Identifier("next")
        static let rotateLeft = NSToolbarItem.Identifier("rotateLeft")
        static let rotateRight = NSToolbarItem.Identifier("rotateRight")
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
        static let actual = NSToolbarItem.Identifier("actual")
        static let fit = NSToolbarItem.Identifier("fit")
        static let slideshow = NSToolbarItem.Identifier("slideshow")
        static let info = NSToolbarItem.Identifier("info")
        static let settings = NSToolbarItem.Identifier("settings")
    }

    private var window: ViewerWindow!
    private var scrollView: NSScrollView!
    private var canvas: ImageCanvas!
    private var emptyLabel: NSTextField!

    private var urls: [URL] = []
    private var index: Int = -1
    private var generation: Int = 0
    private var zoomMode: ZoomMode = .fit
    private var slideshowTimer: Timer?
    private var slideshowActive = false
    private var slideshowItem: NSMenuItem?
    private var preloading: Set<URL> = []
    private let cache = NSCache<NSURL, CGImage>()

    private var pendingInitialActualSize = false
    private var settingsWindow: NSWindow?
    private var intervalPopUp: NSPopUpButton?
    private var zoomPopUp: NSPopUpButton?
    private var darkCheckbox: NSButton?
    private var infoWindow: NSWindow?
    private var infoTextView: NSTextView?

    // MARK: 偏好读取

    private var slideshowInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: DefaultsKey.slideshowInterval)
        return value > 0.2 ? value : kDefaultSlideshowInterval
    }

    private var openAtActualSize: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.openAtActualSize)
    }

    private var usesDarkBackground: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.darkBackground)
    }

    var canvasBackgroundColor: NSColor {
        usesDarkBackground ? NSColor(calibratedWhite: 0.09, alpha: 1) : .underPageBackgroundColor
    }

    private func applyBackground() {
        let color = canvasBackgroundColor
        scrollView?.backgroundColor = color
        scrollView?.contentView.backgroundColor = color
        emptyLabel?.textColor = usesDarkBackground ? NSColor(white: 1, alpha: 0.55) : .secondaryLabelColor
        canvas?.needsDisplay = true
    }

    var scaleFactor: CGFloat {
        // 优先用窗口所在屏幕的倍率：窗口还没上屏时 window.backingScaleFactor 会误报 1
        let value = window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        return value > 0 ? value : 2
    }

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        cache.countLimit = 16
        UserDefaults.standard.register(defaults: [
            DefaultsKey.slideshowInterval: kDefaultSlideshowInterval,
            DefaultsKey.openAtActualSize: false,
            DefaultsKey.darkBackground: false
        ])
        buildMenu()
        buildWindow()
        applyBackground()

        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if !args.isEmpty {
            open(urls: args.map { URL(fileURLWithPath: $0) })
        } else {
            updateStatus()
        }

        if CommandLine.arguments.contains("--selftest") {
            scheduleSelfTest()
        }
    }

    // MARK: 自检模式（--selftest，用于无人值守验证真实 UI 逻辑）

    private var selfTestFailures: [String] = []

    private func scheduleSelfTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { exit(1) }
            self.runSelfTest()
            self.reportSelfTest()
        }
    }

    private func check(_ condition: Bool, _ label: String) {
        print(condition ? "PASS  \(label)" : "FAIL  \(label)")
        if !condition { selfTestFailures.append(label) }
    }

    /// 把画布真实渲染结果读回位图，验证「确实画出了像素」以及「没有上下颠倒」。
    private func renderedColor(_ fx: Double, _ fy: Double) -> (CGFloat, CGFloat, CGFloat)? {
        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let x = Int(Double(rep.pixelsWide) * fx)
        let y = Int(Double(rep.pixelsHigh) * fy)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    /// 回读整个滚动视图：角落是真正的背景（图像按适合窗口显示时会留边）
    private func renderedScrollViewColor(_ fx: Double, _ fy: Double) -> (CGFloat, CGFloat, CGFloat)? {
        guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) else { return nil }
        scrollView.cacheDisplay(in: scrollView.bounds, to: rep)
        let x = Int(Double(rep.pixelsWide) * fx)
        let y = Int(Double(rep.pixelsHigh) * fy)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh,
              let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    private func runRenderChecks() {
        guard let center = renderedColor(0.5, 0.5), let corner = renderedColor(0.02, 0.02) else {
            print("SKIP  渲染回读不可用（窗口未上屏）")
            return
        }

        let delta = abs(center.0 - corner.0) + abs(center.1 - corner.1) + abs(center.2 - corner.2)
        check(delta > 0.05, String(format: "画布上确实有内容（中心与角落像素不同，差值 %.3f）", delta))

        // 测试图是「上暗下亮」的纵向渐变（顶行 R=0，底行 R=255）
        if let upper = renderedColor(0.5, 0.25), let lower = renderedColor(0.5, 0.75) {
            print(String(format: "      纵向采样 上 R=%.3f  下 R=%.3f", upper.0, lower.0))
            check(lower.0 > upper.0 + 0.1, "图像上下方向正确（下亮上暗，未上下颠倒）")
        }
    }

    /// 向右旋转 90° 后，渐变应转为横向：亮端（原图底部）转到左侧。
    private func runRotationRenderCheck() {
        guard let left = renderedColor(0.25, 0.5), let right = renderedColor(0.75, 0.5) else {
            print("SKIP  旋转后的渲染回读不可用")
            return
        }
        print(String(format: "      旋转后横向采样 左 R=%.3f  右 R=%.3f", left.0, right.0))
        check(left.0 > right.0 + 0.1, "向右旋转 90° 为顺时针（亮端由底部转到左侧）")
    }

    private func runSelfTest() {
        print("      状态: zoomMode=\(zoomMode == .fit ? "fit" : "custom")"
              + " mag=\(String(format: "%.3f", scrollView.magnification))"
              + " content=\(Int(scrollView.contentSize.width))×\(Int(scrollView.contentSize.height))"
              + " canvas=\(Int(canvas.frame.width))×\(Int(canvas.frame.height))"
              + " visible=\(window.isVisible) mini=\(window.isMiniaturized)")
        check(urls.count >= 5, "扫描到 ≥5 个文件（实际 \(urls.count)）")
        check(canvas.image != nil, "首图已解码")
        if let image = canvas.image {
            print("      首图像素 \(image.width)×\(image.height)，画布点数 \(Int(canvas.frame.width))×\(Int(canvas.frame.height))，屏幕倍率 \(scaleFactor)")
        }

        check(zoomMode == .fit, "初始为「适合窗口」")
        runRenderChecks()
        let fit = scrollView.magnification
        check(fit > 0 && fit <= 1.0001, "适合窗口比例 \(String(format: "%.3f", fit)) ≤ 100%")

        actualSize()
        check(abs(scrollView.magnification - 1.0) < 0.001, "「实际大小」= 100%")

        zoomIn()
        check(abs(scrollView.magnification - 1.25) < 0.02,
              "放大后 \(String(format: "%.3f", scrollView.magnification)) ≈ 125%")

        let before = canvas.frame.size
        rotate(by: 1)
        let after = canvas.frame.size
        check(abs(after.width - before.height) < 1 && abs(after.height - before.width) < 1,
              "向右旋转 90° 后画布宽高互换（\(Int(before.width))×\(Int(before.height)) → \(Int(after.width))×\(Int(after.height))）")
        check(canvas.quarterTurns == 1, "旋转计数 = 1")
        runRotationRenderCheck()

        rotate(by: -1)
        check(canvas.quarterTurns == 0, "向左旋转可复位")

        zoomToFit()
        check(zoomMode == .fit, "回到「适合窗口」")

        show(index: 2)
        check(index == 2, "翻页到第 3 张")

        // 幻灯片：先确认按钮真的接上了动作，再确认状态反馈与自动前进
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == ToolbarID.slideshow }) {
            check(item.action == #selector(toggleSlideshow) && item.target != nil,
                  "工具栏「幻灯片」按钮已接线到 toggleSlideshow")
            check(item.label == "幻灯片", "未播放时按钮标题为「幻灯片」（当前「\(item.label)」）")
        } else {
            check(false, "工具栏里能找到「幻灯片」按钮")
        }

        toggleSlideshow()
        check(slideshowActive, "点击后进入播放状态")
        let buttonLabel = window.toolbar?.items.first(where: { $0.itemIdentifier == ToolbarID.slideshow })?.label ?? ""
        check(buttonLabel == "停止幻灯片", "播放中按钮变为「停止幻灯片」（当前「\(buttonLabel)」）")

        let beforeWait = index
        let deadline = Date().addingTimeInterval(slideshowInterval + 1.5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        check(index != beforeWait, "等待一个间隔后自动前进（\(beforeWait) → \(index)）")

        toggleSlideshow()
        check(!slideshowActive && slideshowTimer == nil, "再次点击停止播放")

        // 设置窗口
        openSettings()
        check(settingsWindow?.isVisible == true, "设置窗口可以打开")
        check(intervalPopUp != nil && zoomPopUp != nil && darkCheckbox != nil, "设置窗口含间隔/初始缩放/背景三项")

        let originalInterval = slideshowInterval
        intervalPopUp?.selectItem(withTitle: "1 秒")
        settingsChanged()
        check(abs(slideshowInterval - 1.0) < 0.001, "幻灯片间隔改为 1 秒并写入偏好（当前 \(slideshowInterval) 秒）")

        let fastBefore = index
        toggleSlideshow()
        let fastDeadline = Date().addingTimeInterval(2.2)
        while Date() < fastDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        check(index != fastBefore, "按新间隔 1 秒自动前进（\(fastBefore) → \(index)）")
        toggleSlideshow()

        // 自检不能污染真实偏好：改回原值
        UserDefaults.standard.set(originalInterval, forKey: DefaultsKey.slideshowInterval)
        check(abs(slideshowInterval - originalInterval) < 0.001, "自检结束已恢复原间隔（\(slideshowInterval) 秒）")

        // 深色背景：偏好必须真的作用到渲染结果
        UserDefaults.standard.set(true, forKey: DefaultsKey.darkBackground)
        darkCheckbox?.state = .on
        applyBackground()
        if let corner = renderedScrollViewColor(0.02, 0.02) {
            print(String(format: "      深色背景角落 RGB = %.3f, %.3f, %.3f", corner.0, corner.1, corner.2))
            check(corner.0 < 0.4 && corner.1 < 0.4 && corner.2 < 0.4, "深色背景已作用到画布")
        } else {
            print("SKIP  背景回读不可用")
        }
        UserDefaults.standard.set(false, forKey: DefaultsKey.darkBackground)
        darkCheckbox?.state = .off
        applyBackground()
        if let corner = renderedScrollViewColor(0.02, 0.02) {
            check(corner.0 > 0.6, String(format: "恢复浅色背景（角落 R=%.3f）", corner.0))
        }

        // 图片详情
        toggleInfoPanel()
        check(infoWindow?.isVisible == true, "图片详情面板可以打开")
        let detail = infoTextView?.string ?? ""
        print("      详情面板行数 = \(detail.split(separator: "\n").count)")
        check(detail.contains(urls[index].lastPathComponent), "详情显示当前文件名")
        check(detail.contains("像素尺寸") && detail.contains("大小") && detail.contains("位置"),
              "详情包含文件与图像信息")
        check(detail.range(of: "[0-9]+ × [0-9]+", options: .regularExpression) != nil,
              "详情里的像素尺寸是真实元数据")

        let beforeDetail = detail
        show(index: 0)
        let afterDetail = infoTextView?.string ?? ""
        check(afterDetail != beforeDetail && afterDetail.contains(urls[0].lastPathComponent),
              "翻页后详情自动更新")

        // 带 EXIF 的图：验证拍摄信息真的被解析出来（而不是只有文件名和尺寸）
        if let exifIndex = urls.firstIndex(where: { $0.lastPathComponent.lowercased().contains("exif") }) {
            show(index: exifIndex)
            let text = infoTextView?.string ?? ""
            check(text.contains("拍摄信息") && text.contains("TestCamera") && text.contains("Model X100"),
                  "EXIF 相机厂商/型号被解析")
            check(text.contains("f/2.8"), "EXIF 光圈被解析为 f/2.8")
            check(text.contains("1/250"), "EXIF 快门被解析为 1/250 秒")
            check(text.contains("400"), "EXIF ISO 被解析为 400")
            check(text.contains("35 mm"), "EXIF 焦距被解析为 35 mm")
            check(text.contains("2026:10:14") || text.contains("2026"), "EXIF 拍摄时间被解析")
        } else {
            print("SKIP  测试目录里没有带 EXIF 的图")
        }
        let openLabel = window.toolbar?.items.first(where: { $0.itemIdentifier == ToolbarID.info })?.label ?? ""
        check(openLabel == "隐藏图片详情", "面板打开时按钮变为「隐藏图片详情」（当前「\(openLabel)」）")

        toggleInfoPanel()
        check(infoWindow?.isVisible == false, "再次点击关闭详情面板")
        let closedLabel = window.toolbar?.items.first(where: { $0.itemIdentifier == ToolbarID.info })?.label ?? ""
        check(closedLabel == "图片详情", "关闭后按钮标题复原（当前「\(closedLabel)」）")
    }

    private func reportSelfTest() {
        if selfTestFailures.isEmpty {
            print("SELFTEST: PASS")
            exit(0)
        }
        print("SELFTEST: FAIL (\(selfTestFailures.count))")
        for failure in selfTestFailures { print("  - \(failure)") }
        exit(1)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls: urls)
    }

    private func buildWindow() {
        let win = ViewerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "看图"
        win.minSize = NSSize(width: 460, height: 340)
        win.delegate = self
        win.controller = self
        win.center()

        let content = NSView(frame: win.contentRect(forFrameRect: win.frame))

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = CenteringClipView()
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = .underPageBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = kMaxMagnification
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true

        let view = ImageCanvas(frame: .zero)
        view.controller = self
        scroll.documentView = view

        let label = NSTextField(labelWithString: "拖入图片或文件夹 · ⌘O 打开 · ← → 翻页 · R 旋转")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 15, weight: .medium)

        content.addSubview(scroll)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        win.contentView = content

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        win.toolbar = toolbar
        win.toolbarStyle = .unified

        window = win
        scrollView = scroll
        canvas = view
        emptyLabel = label

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(backingChanged),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: win
        )

        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func backingChanged() {
        updateCanvasFrame()
    }

    func windowDidResize(_ notification: Notification) {
        updateCanvasFrame()
    }

    // 窗口刚上屏 / 换到另一块屏幕时，屏幕倍率才可靠，需要重算文档尺寸
    func windowDidBecomeKey(_ notification: Notification) {
        updateCanvasFrame()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateCanvasFrame()
    }

    // MARK: 打开

    func open(urls newURLs: [URL]) {
        var files: [URL] = []
        for url in newURLs {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                files.append(contentsOf: scan(directory: url))
            } else if isImageURL(url) {
                files.append(url)
            }
        }

        guard !files.isEmpty else {
            updateStatus(message: "没有找到可显示的图片")
            return
        }

        var seen = Set<URL>()
        urls = files.filter { seen.insert($0).inserted }
        cache.removeAllObjects()
        preloading.removeAll()
        show(index: 0)
        window.makeFirstResponder(canvas)
    }

    private func scan(directory: URL) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, isImageURL(url) {
                result.append(url)
                if result.count >= kMaxFolderFiles { break }
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    @objc func openFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .rawImage, .pdf]
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    @objc func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    // MARK: 翻页

    func step(_ delta: Int) {
        guard !urls.isEmpty else { return }
        show(index: index + delta)
    }

    func show(index newIndex: Int, resetZoom: Bool = true) {
        guard !urls.isEmpty else { return }
        let count = urls.count
        var target = newIndex % count
        if target < 0 { target += count }
        index = target

        // 播放中：每次翻页都重新开始完整间隔（手动翻页后也不会立刻被自动翻走）
        if slideshowActive { armSlideshow() }

        let url = urls[target]
        generation += 1
        let gen = generation

        if resetZoom {
            // 「打开图片时」偏好：适合窗口 或 实际大小
            pendingInitialActualSize = openAtActualSize
            zoomMode = pendingInitialActualSize ? .custom : .fit
        }
        canvas.quarterTurns = 0
        refreshInfoPanel()

        if let cached = cache.object(forKey: url as NSURL) {
            canvas.image = cached
            updateCanvasFrame()
            updateStatus()
            preloadNeighbors()
            return
        }

        canvas.image = nil
        updateCanvasFrame()
        updateStatus(message: "载入中…")
        startLoad(url: url, generation: gen)
    }

    private func startLoad(url: URL, generation gen: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // 第一阶段：快速预览（大图也能立刻看到）
            let preview = Self.decode(url: url, maxPixel: kPreviewMaxPixel)
            DispatchQueue.main.async {
                guard gen == self.generation, let preview else { return }
                self.canvas.image = preview
                self.updateCanvasFrame()
                self.updateStatus()
            }

            // 第二阶段：全分辨率（缩放时才有细节）
            let full = Self.decode(url: url, maxPixel: nil)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                guard let full else {
                    if self.canvas.image == nil { self.updateStatus(message: "无法解码这个文件") }
                    return
                }
                self.cache.setObject(full, forKey: url as NSURL)
                self.canvas.image = full
                self.updateCanvasFrame()
                self.updateStatus()
                self.preloadNeighbors()
            }
        }
    }

    private func preloadNeighbors() {
        guard urls.count > 1, index >= 0 else { return }
        for offset in [1, -1] {
            var target = (index + offset) % urls.count
            if target < 0 { target += urls.count }
            let url = urls[target]
            if cache.object(forKey: url as NSURL) != nil || preloading.contains(url) { continue }
            preloading.insert(url)

            DispatchQueue.global(qos: .utility).async { [weak self] in
                let image = Self.decode(url: url, maxPixel: nil)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.preloading.remove(url)
                    if let image { self.cache.setObject(image, forKey: url as NSURL) }
                }
            }
        }
    }

    /// 交给 ImageIO 解码。maxPixel 为 nil 时给全分辨率，并应用 EXIF 方向。
    private static func decode(url: URL, maxPixel: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]

        if let maxPixel {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        } else {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
                  let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
                  max(w, h) > 0 else { return nil }
            options[kCGImageSourceThumbnailMaxPixelSize] = Int(max(w, h).rounded(.up))
        }

        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: 旋转

    @objc func rotateLeft() { rotate(by: -1) }
    @objc func rotateRight() { rotate(by: 1) }

    func rotate(by turns: Int) {
        guard canvas.image != nil else { return }

        let clip = scrollView.contentView.bounds
        let oldFrame = canvas.frame
        let fx = oldFrame.width > 0 ? clip.midX / oldFrame.width : 0.5
        let fy = oldFrame.height > 0 ? clip.midY / oldFrame.height : 0.5

        canvas.quarterTurns = ((canvas.quarterTurns + turns) % 4 + 4) % 4
        updateCanvasFrame()

        // 自定义缩放时，尽量让视野中心停在图片的同一相对位置
        if zoomMode == .custom {
            let newFrame = canvas.frame
            let center = NSPoint(x: fx * newFrame.width, y: fy * newFrame.height)
            scrollView.contentView.scroll(to: NSPoint(x: center.x - clip.width / 2,
                                                     y: center.y - clip.height / 2))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updateStatus()
    }

    // MARK: 缩放

    func zoom(by factor: CGFloat, atPoint point: NSPoint? = nil) {
        guard canvas.image != nil else { return }
        zoomMode = .custom
        setMagnification(scrollView.magnification * factor, centeredAt: point)
    }

    @objc func zoomIn() { zoom(by: 1.25) }
    @objc func zoomOut() { zoom(by: 1 / 1.25) }

    @objc func zoomToFit() {
        guard canvas.image != nil else { return }
        zoomMode = .fit
        updateCanvasFrame()
    }

    @objc func actualSize() {
        guard canvas.image != nil else { return }
        zoomMode = .custom
        let clip = scrollView.contentView.bounds
        setMagnification(1.0, centeredAt: NSPoint(x: clip.midX, y: clip.midY))
    }

    func toggleFitActual() {
        if zoomMode == .fit { actualSize() } else { zoomToFit() }
    }

    private func setMagnification(_ value: CGFloat, centeredAt point: NSPoint? = nil) {
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        if let point {
            scrollView.setMagnification(clamped, centeredAt: point)
        } else {
            scrollView.magnification = clamped
        }
        updateStatus()
    }

    private func fitScale(for documentSize: NSSize) -> CGFloat {
        let available = scrollView.contentSize
        guard available.width > 4, available.height > 4,
              documentSize.width > 0, documentSize.height > 0 else { return 1 }
        return min(available.width / documentSize.width, available.height / documentSize.height)
    }

    private func updateCanvasFrame() {
        guard let canvas, let scrollView else { return }
        let clipSize = scrollView.contentView.bounds.size

        guard let image = canvas.image else {
            canvas.frame = NSRect(x: 0, y: 0,
                                  width: max(clipSize.width, 1),
                                  height: max(clipSize.height, 1))
            return
        }

        let scale = scaleFactor
        let swapped = canvas.quarterTurns % 2 == 1
        let width = CGFloat(swapped ? image.height : image.width) / scale
        let height = CGFloat(swapped ? image.width : image.height) / scale
        let documentSize = NSSize(width: max(width, 1), height: max(height, 1))
        canvas.frame = NSRect(origin: .zero, size: documentSize)

        let fit = fitScale(for: documentSize)
        scrollView.minMagnification = max(0.02, fit * 0.25)
        scrollView.maxMagnification = kMaxMagnification

        if pendingInitialActualSize {
            pendingInitialActualSize = false
            zoomMode = .custom
            setMagnification(1.0)
        } else if zoomMode == .fit {
            setMagnification(min(fit, 1.0))
        } else {
            setMagnification(scrollView.magnification)
        }
    }

    // MARK: 幻灯片

    @objc func toggleSlideshow() {
        if slideshowActive { stopSlideshow() } else { startSlideshow() }
    }

    private func startSlideshow() {
        guard urls.count > 1 else { return }
        slideshowActive = true
        updateSlideshowButton()
        armSlideshow()
        // 立刻前进一张：点下去马上有可见反应，而不是干等 3 秒
        step(1)
    }

    private func stopSlideshow() {
        slideshowActive = false
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        updateSlideshowButton()
    }

    /// 用「单次计时器 + 每次翻页重新计时」代替重复计时器：
    /// 这样任何一次翻页（自动或手动）都会重新开始完整间隔，也不会互相打架。
    private func armSlideshow() {
        slideshowTimer?.invalidate()
        guard slideshowActive else { return }
        let timer = Timer(timeInterval: slideshowInterval, repeats: false) { [weak self] _ in
            guard let self, self.slideshowActive else { return }
            self.step(1)
        }
        // 放进 .common 模式，触控板/滚动等跟踪状态下也照常触发
        RunLoop.main.add(timer, forMode: .common)
        slideshowTimer = timer
    }

    /// 按钮必须反映状态（播放中显示暂停图标），否则用户点了看不出有没有生效。
    private func updateSlideshowButton() {
        let label = slideshowActive ? "停止幻灯片" : "幻灯片"
        let symbol = slideshowActive ? "pause.fill" : "play.fill"
        slideshowItem?.title = slideshowActive ? "停止幻灯片" : "开始幻灯片"
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == ToolbarID.slideshow }) else { return }
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }

    // MARK: 键盘

    func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123, 126: step(-1); return true            // ← ↑
        case 124, 125: step(1); return true             // → ↓
        case 116: step(-10); return true                // Page Up
        case 121: step(10); return true                 // Page Down
        case 115: show(index: 0); return true           // Home
        case 119: show(index: urls.count - 1); return true // End
        case 49: step(1); return true                   // Space
        case 53:                                        // Esc
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            return true
        default:
            break
        }

        guard let characters = event.charactersIgnoringModifiers?.lowercased(), !characters.isEmpty else {
            return false
        }
        switch characters {
        case "r": rotate(by: event.modifierFlags.contains(.option) ? -1 : 1); return true
        case "f": window.toggleFullScreen(nil); return true
        case "0": zoomToFit(); return true
        case "1": actualSize(); return true
        case "+", "=": zoomIn(); return true
        case "-": zoomOut(); return true
        case "s": toggleSlideshow(); return true
        case "o": openFiles(); return true
        default: return false
        }
    }

    // MARK: 标题栏状态

    private func updateStatus(message: String? = nil) {
        guard let window else { return }
        emptyLabel?.isHidden = index >= 0

        if let message {
            window.subtitle = message
            return
        }

        guard index >= 0, urls.indices.contains(index) else {
            window.title = "看图"
            window.subtitle = "拖入图片或文件夹"
            return
        }

        window.title = urls[index].lastPathComponent

        var parts: [String] = []
        if urls.count > 1 { parts.append("\(index + 1) / \(urls.count)") }
        if let image = canvas.image {
            let swapped = canvas.quarterTurns % 2 == 1
            parts.append("\(swapped ? image.height : image.width)×\(swapped ? image.width : image.height)")
        }
        parts.append("\(Int((scrollView.magnification * 100).rounded()))%")
        if canvas.quarterTurns != 0 { parts.append("\(canvas.quarterTurns * 90)°") }
        window.subtitle = parts.joined(separator: "  ·  ")
    }

    // MARK: 设置窗口

    @objc func openSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildSettingsWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "看图设置"
        win.isReleasedWhenClosed = false

        let interval = NSPopUpButton(frame: .zero, pullsDown: false)
        for seconds in [1.0, 2.0, 3.0, 5.0, 8.0, 10.0, 15.0, 30.0] {
            interval.addItem(withTitle: "\(Int(seconds)) 秒")
            interval.lastItem?.representedObject = seconds
        }
        if let item = interval.itemArray.first(where: { ($0.representedObject as? Double) == slideshowInterval }) {
            interval.select(item)
        }
        interval.target = self
        interval.action = #selector(settingsChanged)

        let zoom = NSPopUpButton(frame: .zero, pullsDown: false)
        zoom.addItem(withTitle: "适合窗口")
        zoom.addItem(withTitle: "实际大小（100%）")
        zoom.selectItem(at: openAtActualSize ? 1 : 0)
        zoom.target = self
        zoom.action = #selector(settingsChanged)

        let dark = NSButton(checkboxWithTitle: "使用深色背景", target: self, action: #selector(settingsChanged))
        dark.state = usesDarkBackground ? .on : .off

        let grid = NSGridView(views: [
            [settingsLabel("幻灯片间隔"), interval],
            [settingsLabel("打开图片时"), zoom],
            [settingsLabel("背景"), dark]
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        let hint = NSTextField(labelWithString: "幻灯片用工具栏 ▶ 或 S 键开始/停止；间隔修改后立即生效。设置会自动记住。")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)

        let content = NSView()
        content.addSubview(grid)
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            hint.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24)
        ])
        win.contentView = content

        settingsWindow = win
        intervalPopUp = interval
        zoomPopUp = zoom
        darkCheckbox = dark
    }

    private func settingsLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    @objc private func settingsChanged() {
        if let seconds = intervalPopUp?.selectedItem?.representedObject as? Double {
            UserDefaults.standard.set(seconds, forKey: DefaultsKey.slideshowInterval)
            if slideshowActive { armSlideshow() }   // 播放中改间隔立即生效
        }
        if let zoom = zoomPopUp {
            UserDefaults.standard.set(zoom.indexOfSelectedItem == 1, forKey: DefaultsKey.openAtActualSize)
        }
        if let dark = darkCheckbox {
            UserDefaults.standard.set(dark.state == .on, forKey: DefaultsKey.darkBackground)
        }
        applyBackground()
    }

    // MARK: 图片详情

    @objc func toggleInfoPanel() {
        if let win = infoWindow, win.isVisible {
            win.orderOut(nil)
            updateInfoButton()
            return
        }
        if infoWindow == nil { buildInfoWindow() }
        refreshInfoPanel()
        infoWindow?.center()
        infoWindow?.makeKeyAndOrderFront(nil)
        updateInfoButton()
    }

    private func updateInfoButton() {
        let visible = infoWindow?.isVisible == true
        let label = visible ? "隐藏图片详情" : "图片详情"
        let symbol = visible ? "info.circle.fill" : "info.circle"
        guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == ToolbarID.info }) else { return }
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    }

    private func buildInfoWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 580),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        win.title = "图片详情"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 320, height: 240)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 580))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.documentView = textView

        let content = NSView()
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        win.contentView = content

        infoWindow = win
        infoTextView = textView
    }

    private func refreshInfoPanel() {
        guard let textView = infoTextView else { return }
        guard index >= 0, urls.indices.contains(index) else {
            textView.string = "没有打开的图片"
            return
        }
        textView.textStorage?.setAttributedString(infoText(for: urls[index]))
    }

    /// 汇总文件属性 + ImageIO 元数据（EXIF/TIFF/GPS），拼成两列排版
    private func infoText(for url: URL) -> NSAttributedString {
        let output = NSMutableAttributedString()

        let sectionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 92)]
        paragraph.headIndent = 92
        paragraph.firstLineHeadIndent = 0
        paragraph.lineSpacing = 2

        func appendSection(_ title: String, _ rows: [(String, String)]) {
            let visible = rows.filter { !$0.1.isEmpty }
            guard !visible.isEmpty else { return }
            if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(NSAttributedString(string: title + "\n", attributes: sectionAttrs))
            for (key, value) in visible {
                output.append(NSAttributedString(string: key + "\t", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph
                ]))
                output.append(NSAttributedString(string: value + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph
                ]))
            }
        }

        var props: [CFString: Any] = [:]
        var typeIdentifier = ""
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
            if let type = CGImageSourceGetType(source) { typeIdentifier = type as String }
        }
        let exif = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let tiff = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        let gps = (props[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]

        func numberValue(_ dictionary: [CFString: Any], _ key: CFString) -> Double? {
            if let number = dictionary[key] as? NSNumber { return number.doubleValue }
            // 少数文件的 rational 会以 [分子, 分母] 数组形式出现（探针在 JFIFVersion 上实测到过）
            if let pair = dictionary[key] as? [NSNumber], pair.count == 2, pair[1].doubleValue != 0 {
                return pair[0].doubleValue / pair[1].doubleValue
            }
            return nil
        }
        func stringValue(_ dictionary: [CFString: Any], _ key: CFString) -> String {
            if let text = dictionary[key] as? String, !text.isEmpty { return text }
            return ""
        }

        let attributes = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        appendSection("文件", [
            ("名称", url.lastPathComponent),
            ("位置", url.deletingLastPathComponent().path),
            ("大小", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)),
            ("修改时间", (attributes[.modificationDate] as? Date).map { dateFormatter.string(from: $0) } ?? ""),
            ("创建时间", (attributes[.creationDate] as? Date).map { dateFormatter.string(from: $0) } ?? ""),
            ("文件格式", typeIdentifier)
        ])

        // EXIF 方向 5–8 表示宽高被旋转过，显示尺寸要换过来
        let orientation = Int(numberValue(props, kCGImagePropertyOrientation) ?? 1)
        let rawWidth = Int(numberValue(props, kCGImagePropertyPixelWidth) ?? 0)
        let rawHeight = Int(numberValue(props, kCGImagePropertyPixelHeight) ?? 0)
        let swapped = orientation >= 5 && orientation <= 8
        let shownWidth = swapped ? rawHeight : rawWidth
        let shownHeight = swapped ? rawWidth : rawHeight
        let megapixels = Double(rawWidth * rawHeight) / 1_000_000

        appendSection("图像", [
            ("像素尺寸", rawWidth > 0 ? "\(shownWidth) × \(shownHeight)" : ""),
            ("总像素", megapixels > 0 ? String(format: "%.1f MP", megapixels) : ""),
            ("色彩模型", stringValue(props, kCGImagePropertyColorModel)),
            ("色彩描述", stringValue(props, kCGImagePropertyProfileName)),
            ("位深", numberValue(props, kCGImagePropertyDepth).map { "\(Int($0)) 位/通道" } ?? ""),
            ("分辨率", numberValue(props, kCGImagePropertyDPIWidth).map { String(format: "%.0f DPI", $0) } ?? ""),
            ("EXIF 方向", rawWidth > 0 ? "\(orientation)" : ""),
            ("当前显示", "\(Int(((scrollView?.magnification ?? 1) * 100).rounded()))%")
        ])

        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        let exposureText: String = {
            guard let exposure = numberValue(exif, kCGImagePropertyExifExposureTime), exposure > 0 else { return "" }
            if exposure < 1 { return "1/\(Int((1 / exposure).rounded())) 秒" }
            return String(format: "%.1f 秒", exposure)
        }()

        appendSection("拍摄信息", [
            ("相机", [stringValue(tiff, kCGImagePropertyTIFFMake), stringValue(tiff, kCGImagePropertyTIFFModel)]
                .filter { !$0.isEmpty }.joined(separator: " ")),
            ("镜头", stringValue(exif, kCGImagePropertyExifLensModel)),
            ("光圈", numberValue(exif, kCGImagePropertyExifFNumber).map { String(format: "f/%.1f", $0) } ?? ""),
            ("快门", exposureText),
            ("ISO", iso.map { "\($0)" } ?? ""),
            ("焦距", numberValue(exif, kCGImagePropertyExifFocalLength).map { String(format: "%.0f mm", $0) } ?? ""),
            ("35mm 等效", numberValue(exif, kCGImagePropertyExifFocalLenIn35mmFilm).map { String(format: "%.0f mm", $0) } ?? ""),
            ("曝光补偿", numberValue(exif, kCGImagePropertyExifExposureBiasValue).map { String(format: "%+.1f EV", $0) } ?? ""),
            ("闪光灯", numberValue(exif, kCGImagePropertyExifFlash).map { $0 == 0 ? "未闪光" : "已闪光" } ?? ""),
            ("拍摄时间", stringValue(exif, kCGImagePropertyExifDateTimeOriginal)),
            ("处理软件", stringValue(tiff, kCGImagePropertyTIFFSoftware))
        ])

        appendSection("位置", [
            ("纬度", numberValue(gps, kCGImagePropertyGPSLatitude)
                .map { String(format: "%.5f° %@", $0, stringValue(gps, kCGImagePropertyGPSLatitudeRef)) } ?? ""),
            ("经度", numberValue(gps, kCGImagePropertyGPSLongitude)
                .map { String(format: "%.5f° %@", $0, stringValue(gps, kCGImagePropertyGPSLongitudeRef)) } ?? ""),
            ("海拔", numberValue(gps, kCGImagePropertyGPSAltitude).map { String(format: "%.0f m", $0) } ?? "")
        ])

        return output
    }

    // MARK: 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 看图",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        let settingsItem = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 看图", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 看图", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // 文件
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        let openFileItem = fileMenu.addItem(withTitle: "打开文件…", action: #selector(openFiles), keyEquivalent: "o")
        openFileItem.target = self
        let openFolderItem = fileMenu.addItem(withTitle: "打开文件夹…", action: #selector(openFolder), keyEquivalent: "o")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        openFolderItem.target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        // 显示
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        let zoomInItem = viewMenu.addItem(withTitle: "放大", action: #selector(zoomIn), keyEquivalent: "+")
        zoomInItem.target = self
        let zoomOutItem = viewMenu.addItem(withTitle: "缩小", action: #selector(zoomOut), keyEquivalent: "-")
        zoomOutItem.target = self
        let actualItem = viewMenu.addItem(withTitle: "实际大小", action: #selector(actualSize), keyEquivalent: "0")
        actualItem.target = self
        let fitItem = viewMenu.addItem(withTitle: "适合窗口", action: #selector(zoomToFit), keyEquivalent: "9")
        fitItem.target = self
        viewMenu.addItem(.separator())
        let rotateLeftItem = viewMenu.addItem(withTitle: "向左旋转", action: #selector(rotateLeft), keyEquivalent: "r")
        rotateLeftItem.keyEquivalentModifierMask = [.command, .option]
        rotateLeftItem.target = self
        let rotateRightItem = viewMenu.addItem(withTitle: "向右旋转", action: #selector(rotateRight), keyEquivalent: "r")
        rotateRightItem.target = self
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "进入全屏幕",
                         action: #selector(NSWindow.toggleFullScreen(_:)),
                         keyEquivalent: "f").keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(.separator())
        let infoItem = viewMenu.addItem(withTitle: "显示图片详情", action: #selector(toggleInfoPanel), keyEquivalent: "i")
        infoItem.target = self
        viewItem.submenu = viewMenu

        // 浏览
        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "浏览")
        let prevItem = goMenu.addItem(withTitle: "上一张", action: #selector(previousImage), keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        prevItem.target = self
        let nextItem = goMenu.addItem(withTitle: "下一张", action: #selector(nextImage), keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!))
        nextItem.target = self
        goMenu.addItem(.separator())
        let firstItem = goMenu.addItem(withTitle: "第一张", action: #selector(firstImage), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        firstItem.keyEquivalentModifierMask = [.command, .option]
        firstItem.target = self
        let lastItem = goMenu.addItem(withTitle: "最后一张", action: #selector(lastImage), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        lastItem.keyEquivalentModifierMask = [.command, .option]
        lastItem.target = self
        goItem.submenu = goMenu

        // 幻灯片
        let playItem = NSMenuItem()
        mainMenu.addItem(playItem)
        let playMenu = NSMenu(title: "幻灯片")
        let slideshow = playMenu.addItem(withTitle: "开始幻灯片", action: #selector(toggleSlideshow), keyEquivalent: "s")
        slideshow.target = self
        slideshowItem = slideshow
        playItem.submenu = playMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func previousImage() { step(-1) }
    @objc private func nextImage() { step(1) }
    @objc private func firstImage() { show(index: 0) }
    @objc private func lastImage() { show(index: urls.count - 1) }

    // MARK: 工具栏

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.open, .flexibleSpace,
         ToolbarID.prev, ToolbarID.next, .space,
         ToolbarID.rotateLeft, ToolbarID.rotateRight, .space,
         ToolbarID.zoomOut, ToolbarID.zoomIn, ToolbarID.actual, ToolbarID.fit, .space,
         ToolbarID.slideshow, .space,
         ToolbarID.info, ToolbarID.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        func configure(_ label: String, _ symbol: String, _ action: Selector) {
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.target = self
            item.action = action
        }

        switch itemIdentifier {
        case ToolbarID.open: configure("打开", "folder", #selector(openFiles))
        case ToolbarID.prev: configure("上一张", "chevron.left", #selector(previousImage))
        case ToolbarID.next: configure("下一张", "chevron.right", #selector(nextImage))
        case ToolbarID.rotateLeft: configure("向左旋转", "rotate.left", #selector(rotateLeft))
        case ToolbarID.rotateRight: configure("向右旋转", "rotate.right", #selector(rotateRight))
        case ToolbarID.zoomOut: configure("缩小", "minus.magnifyingglass", #selector(zoomOut))
        case ToolbarID.zoomIn: configure("放大", "plus.magnifyingglass", #selector(zoomIn))
        case ToolbarID.actual: configure("实际大小", "1.magnifyingglass", #selector(actualSize))
        case ToolbarID.fit: configure("适合窗口", "arrow.up.left.and.arrow.down.right", #selector(zoomToFit))
        case ToolbarID.slideshow: configure("幻灯片", "play.fill", #selector(toggleSlideshow))
        case ToolbarID.info: configure("图片详情", "info.circle", #selector(toggleInfoPanel))
        case ToolbarID.settings: configure("设置", "gearshape", #selector(openSettings))
        default: return nil
        }
        return item
    }
}

// MARK: - 入口

let application = NSApplication.shared
let viewer = ViewerController()
application.delegate = viewer
application.setActivationPolicy(.regular)
application.run()
