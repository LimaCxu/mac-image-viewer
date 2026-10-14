# 看图 (Mac Image Viewer)

一个原生 macOS 看图工具，用来替代系统「预览」在**浏览图片**这件事上的体验：
翻页、旋转、缩放、全屏、拖放、幻灯片、EXIF 详情面板，全部键盘可达。

纯 AppKit 单文件实现，**240KB**，不依赖任何第三方库。
解码完全交给系统 ImageIO，因此天然支持 JPEG / PNG / HEIC / WebP / AVIF / TIFF / GIF / RAW / PDF，并自动应用 EXIF 方向。

```
翻页 ← → ↑ ↓ 空格   旋转 R / ⌥R   缩放 ⌘+ ⌘- 捏合   100% ⌘0   适合窗口 ⌘9
幻灯片 S            详情 ⌘I        设置 ⌘,          全屏 F
```

## 构建与运行

需要 macOS 13+ 与 Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/LimaCxu/mac-image-viewer.git
cd mac-image-viewer
./build.sh
open ImageViewer.app
```

装到「应用程序」里即可双击使用，也可以设为图片的默认打开方式：

```bash
cp -R ImageViewer.app /Applications/
```

也可以直接打开某张图或整个文件夹：

```bash
open -a "$PWD/ImageViewer.app" 图片.jpg
open -a "$PWD/ImageViewer.app" ~/Pictures
```

## 功能

| 操作 | 快捷键 |
|---|---|
| 上一张 / 下一张 | `←` `→` `↑` `↓` `空格` |
| 翻 10 张 | `Page Up` / `Page Down` |
| 第一张 / 最后一张 | `Home` / `End`（或 `⌥⌘↑` `⌥⌘↓`） |
| 放大 / 缩小 | `⌘+` `⌘-`、触控板双指捏合、`⌘` + 滚轮 |
| 实际大小（100%） | `⌘0` 或双击 |
| 适合窗口 | `⌘9`、双击切换 |
| 向右 / 向左旋转 90° | `R` / `⌥R`（或 `⌘R` / `⌥⌘R`） |
| 全屏 | `F` 或 `⌃⌘F`，`Esc` 退出 |
| 幻灯片 | `S` 或点工具栏 ▶（播放中变 ⏸，点击即立刻翻一张，再点停止） |
| 图片详情面板 | `⌘I` 或点工具栏 ⓘ |
| 设置 | `⌘,` 或点工具栏 ⚙ |
| 打开文件 / 文件夹 | `⌘O` / `⇧⌘O` |

拖放：图片或文件夹直接拖到窗口上即可。文件夹会**递归**扫描其中的图片（上限 5000 张，按路径排序）。

**设置**（写入 `UserDefaults`，重启仍生效）

| 项目 | 可选值 |
|---|---|
| 幻灯片间隔 | 1 / 2 / 3 / 5 / 8 / 10 / 15 / 30 秒（播放中修改**立即**按新间隔生效） |
| 打开图片时 | 适合窗口 / 实际大小（100%） |
| 背景 | 浅色（跟随系统）/ 深色 |

**图片详情面板**（翻页时自动刷新，取不到值的行自动隐藏）

- **文件**：名称、位置、大小、修改/创建时间、UTI 格式
- **图像**：像素尺寸（已按 EXIF 方向换算）、总像素、色彩模型、色彩描述文件、位深、DPI、EXIF 方向、当前显示倍率
- **拍摄信息**：相机厂商/型号、镜头、光圈、快门、ISO、焦距、35mm 等效、曝光补偿、闪光灯、拍摄时间、处理软件
- **位置**：经纬度（含 N/S、E/W 方向）、海拔

## 自检

内置一个可进 CI 的验收入口：它驱动真实 UI 逻辑，并把**渲染结果读回位图做像素级校验**，而不是只检查「进程没崩」。

```bash
# 先生成测试图（全部是现场合成的图，仓库不含任何第三方素材）
swiftc -O -o /tmp/make_test_images Tools/make_test_images.swift
/tmp/make_test_images test-images

# 跑 41 项自检
./ImageViewer.app/Contents/MacOS/ImageViewer test-images --selftest
```

覆盖范围包括：文件扫描、两阶段解码、适合窗口比例、实际大小 = 100%、缩放倍率、旋转后画布宽高互换、**旋转方向（顺时针）**、**图像未被上下颠倒**、翻页、幻灯片自动前进与状态反馈、设置项持久化、深色背景真的作用到像素、详情面板内容与翻页更新、EXIF 光圈/快门/ISO/焦距解析。全过打印 `SELFTEST: PASS` 并以 0 退出。

> 这套自检抓出过两个真问题，都记在提交历史里：
> 1. `flipped NSView` 里 `CGContext.draw` 会把 CGImage **上下画反**。定位用的是与坐标约定无关的对照实验（`Tools/probe_orientation.swift`）。
> 2. 用 PIL 写 EXIF 时，rational 类型（FNumber/ExposureTime/FocalLength）不合规，**ImageIO 会静默丢弃这三个标签**，导致假失败。`Tools/probe_exif.swift` 可以直接打印 ImageIO 实际暴露的标签、值与 Swift 类型。

## 设计要点

- **两阶段解码**：先出 1600px 预览（大图也能立刻看到），后台再换全分辨率，打开 50MP 图不会卡住；相邻图片会预读进 `NSCache`。
- **系统解码器**：`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailWithTransform`，EXIF 方向、色彩管理、RAW/HEIC 全部交给系统，不自己写解码器。
- **缩放交给 `NSScrollView`**：`allowsMagnification` 提供捏合与滚动定位，自定义 `CenteringClipView` 让小于窗口的图片居中。
- **旋转是非破坏性的**：只记录 90° 计数并按变换绘制，不改动原文件。
- **100% 的定义**：1 个图像像素 = 1 个屏幕像素（按屏幕倍率换算），窗口上屏/换屏时重算。
- **幻灯片用单次计时器 + 每次翻页重新计时**，并注册在 `.common` 运行循环模式，滚动或触摸板操作时也不会被饿死。

## 关于 REA

本项目的开发流程使用了 **[REA](https://github.com/morluto/rea)**（`rea-agents` 6.5.0，经其 MCP 接口），但**没有反编译任何二进制**。准确地说，REA 在这里承担两项工作：

| 阶段 | REA 做了什么 | 得到什么 |
|---|---|---|
| 开工前侦察 | 对系统「预览」`/System/Applications/Preview.app` 做 Mach-O 依赖清点 | 87 个依赖框架 / 105 条 load command / arm64e；其中真正的解码层只有 `ImageIO + UniformTypeIdentifiers + CoreGraphics + ColorSync`。据此决定本工具只链这 4 类框架 |
| 每次构建后验收 | 对产物做身份固化 | sha256、ad-hoc 签名状态、cdhash，用于确认交付的就是被验证过的那份二进制 |

体积对照（REA 实测同一台机器）：

| | 依赖框架数 | load commands | 架构 |
|---|---|---|---|
| 系统「预览」 | 87 | 105 | arm64e + arm64 |
| 本工具 | 24 | 42 | arm64 |

**声明**：本仓库全部代码为原创实现，仅调用公开文档化的 AppKit / ImageIO / CoreGraphics / UniformTypeIdentifiers API；
不含任何来自「预览」或其他专有软件的代码、资源或反编译产物。上述 REA 结果仅作为架构决策与产物验证的依据被引用。

## 目录结构

```
Sources/main.swift           全部实现（单文件，约 1400 行）
Resources/Info.plist         bundle 配置
Tools/make_test_images.swift 生成自检素材（含合规 EXIF 样本）
Tools/probe_bitmap.swift     NSBitmapImageRep 的 y 轴方向探针
Tools/probe_orientation.swift CGImage 绘制方向对照实验
Tools/probe_exif.swift       打印 ImageIO 实际暴露的 EXIF 标签与类型
build.sh                     编译 + 打包 + ad-hoc 签名
```

## 已知限制

- 仅 arm64（要通用二进制需在 `build.sh` 的 `-target` 加 `x86_64` 并用 `lipo` 合并）。
- GIF 只显示第一帧，未做动画播放。
- 没有缩略图条、删除/重命名、PDF 多页浏览。
- 未做公证（notarization）；换机器分发需自行签名。

## 协议

[MIT](LICENSE)
