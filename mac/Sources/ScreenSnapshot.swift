import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
#if canImport(VoicePolishCore)
import VoicePolishCore
#endif

/// 触发瞬间的屏幕快照：一张整屏上下文图 + 一张指针附近的放大图，两张都在指针位置画了红色圆环。
/// 模型认画出来的标记比认坐标数字可靠得多，所以只画标记、不给坐标。
struct ScreenSnapshot {
    let overviewJPEG: Data
    let closeUpJPEG: Data
    /// 从发起到拿到 CGImage 的耗时
    let captureMs: Int
    /// 画标记 + 缩放 + JPEG 编码的耗时
    let encodeMs: Int

    var sizeSummary: String {
        AskVision.sizeSummary(overviewJPEG: overviewJPEG, closeUpJPEG: closeUpJPEG)
    }
}

enum ScreenSnapshotError: Error {
    /// 没给屏幕录制权限
    case noPermission
    case noDisplay
    case captureFailed(String)
    case encodeFailed

    /// 给用户看的一句话，要能照着办
    var userMessage: String {
        switch self {
        case .noPermission: return "还没给屏幕录制权限，这次只按语音回答。去「系统设置 → 隐私与安全性 → 屏幕录制」勾上 Typefree，然后退出并重新打开 Typefree。"
        case .noDisplay: return "没找到指针所在的屏幕，这次只按语音回答。"
        case .captureFailed(let reason): return "截屏失败（\(reason)），这次只按语音回答。"
        case .encodeFailed: return "截屏编码失败，这次只按语音回答。"
        }
    }

    /// 日志用的短名（不含任何屏幕内容）
    var debugName: String {
        switch self {
        case .noPermission: return "noPermission"
        case .noDisplay: return "noDisplay"
        case .captureFailed(let reason): return "captureFailed(\(reason))"
        case .encodeFailed: return "encodeFailed"
        }
    }
}

enum ScreenSnapshotCapturer {
    /// 画标记、缩放、JPEG 编码都在这条队列上，主线程一点不占
    private static let renderQueue = DispatchQueue(label: "com.voicepolish.screen-snapshot", qos: .userInitiated)

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 弹一次系统的屏幕录制授权请求（只在第一次触发、且确实没权限时调）
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 截指针所在那块屏幕。point 是 Quartz 全局坐标（原点左上），也就是 CGEvent.location。
    /// 排除本 App 自己的窗口，录音胶囊和回答浮窗不会进到图里。
    /// completion 在主队列回调。
    static func capture(at point: CGPoint,
                        completion: @escaping (Result<ScreenSnapshot, ScreenSnapshotError>) -> Void) {
        func finish(_ result: Result<ScreenSnapshot, ScreenSnapshotError>) {
            DispatchQueue.main.async { completion(result) }
        }
        guard hasPermission else { finish(.failure(.noPermission)); return }
        guard let displayID = displayID(containing: point) else { finish(.failure(.noDisplay)); return }

        let startedAt = ProcessInfo.processInfo.systemUptime
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let error { finish(.failure(.captureFailed(Self.shortReason(error)))); return }
            guard let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                finish(.failure(.noDisplay))
                return
            }
            // 排除本 App：录音胶囊、回答浮窗都不该出现在给模型看的图里
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

            let bounds = CGDisplayBounds(displayID)
            let scale = Self.backingScale(of: displayID)
            let config = SCStreamConfiguration()
            config.width = Int((bounds.width * scale).rounded())
            config.height = Int((bounds.height * scale).rounded())
            config.showsCursor = false      // 指针位置我们自己画标记，系统指针反而会挡住内容
            config.captureResolution = .best
            config.scalesToFit = false

            Task {
                do {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    let captureMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                    // 指针在这张图里的像素位置（图的原点在屏幕左上角）
                    let cursorPixel = CGPoint(x: (point.x - bounds.minX) * scale,
                                              y: (point.y - bounds.minY) * scale)
                    // 指针所在窗口在这张图里的像素范围；清晰图优先截整个窗口
                    let windowPixel = Self.windowFrame(at: point).map {
                        CGRect(x: ($0.minX - bounds.minX) * scale, y: ($0.minY - bounds.minY) * scale,
                               width: $0.width * scale, height: $0.height * scale)
                    }
                    renderQueue.async {
                        let encodeStarted = ProcessInfo.processInfo.systemUptime
                        guard let pair = Self.render(image: image, cursorPixel: cursorPixel, windowPixel: windowPixel, scale: scale) else {
                            finish(.failure(.encodeFailed))
                            return
                        }
                        let encodeMs = Int((ProcessInfo.processInfo.systemUptime - encodeStarted) * 1000)
                        finish(.success(ScreenSnapshot(overviewJPEG: pair.overview, closeUpJPEG: pair.closeUp,
                                                       captureMs: captureMs, encodeMs: encodeMs)))
                    }
                } catch {
                    finish(.failure(.captureFailed(Self.shortReason(error))))
                }
            }
        }
    }

    // MARK: - 渲染

    /// 指针底下最上层的普通窗口（Quartz 全局坐标，原点左上）。CGWindowList 按前后顺序给，第一个包含指针的就是。
    /// 自己的窗口（回答浮窗、胶囊）不算：截图里本来就排除了它们。
    private static func windowFrame(at point: CGPoint) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict), frame.contains(point) else { continue }
            return frame
        }
        return nil
    }

    private static func render(image: CGImage, cursorPixel: CGPoint, windowPixel: CGRect?, scale: CGFloat) -> (overview: Data, closeUp: Data)? {
        let full = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))

        // 整屏图：只用来看「这是什么界面」，压得狠一点，图片 token 直接影响首字延迟
        let overviewScale = AskVision.scale(pixelSize: full, longEdge: AskVision.overviewLongEdge)
        guard let overview = draw(image: image,
                                  source: CGRect(origin: .zero, size: full),
                                  outputScale: overviewScale,
                                  markerAt: cursorPixel),
              let overviewData = jpeg(overview, quality: AskVision.overviewQuality) else { return nil }

        // 清晰图：指针所在的整个窗口（太大就取指针周围一块），小字才认得出来
        let cropRect = AskVision.closeUpRect(center: cursorPixel, imagePixelSize: full, windowRect: windowPixel, scale: scale)
        let closeUpScale = AskVision.scale(pixelSize: cropRect.size, longEdge: AskVision.closeUpLongEdge)
        guard let closeUp = draw(image: image,
                                 source: cropRect,
                                 outputScale: closeUpScale,
                                 markerAt: cursorPixel),
              let closeUpData = jpeg(closeUp, quality: AskVision.closeUpQuality) else { return nil }

        return (overviewData, closeUpData)
    }

    /// 把 source 这块（原图像素坐标、原点左上）画成一张新图，并在指针处画标记。
    private static func draw(image: CGImage, source: CGRect, outputScale: CGFloat, markerAt cursorPixel: CGPoint) -> CGImage? {
        let width = max(1, Int((source.width * outputScale).rounded()))
        let height = max(1, Int((source.height * outputScale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        guard let piece = (source.origin == .zero && source.size == CGSize(width: image.width, height: image.height))
                ? image : image.cropping(to: source) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(piece, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        // 指针在这张输出图里的位置。CGContext 原点在左下，所以 y 要翻过来。
        let x = (cursorPixel.x - source.minX) * outputScale
        let yTopDown = (cursorPixel.y - source.minY) * outputScale
        drawMarker(in: ctx, at: CGPoint(x: x, y: CGFloat(height) - yTopDown),
                   radius: max(14, CGFloat(max(width, height)) * 0.022))
        return ctx.makeImage()
    }

    /// 红色圆环 + 四根朝内的短线，圆心留空不挡内容；外面再描一圈白，深色背景上也看得见。
    private static func drawMarker(in ctx: CGContext, at point: CGPoint, radius: CGFloat) {
        let ring = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ctx.setLineCap(.round)

        ctx.setLineWidth(radius * 0.42)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.strokeEllipse(in: ring)

        ctx.setLineWidth(radius * 0.24)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.13, blue: 0.13, alpha: 1))
        ctx.strokeEllipse(in: ring)

        let inner = radius * 1.28
        let outer = radius * 2.0
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            ctx.move(to: CGPoint(x: point.x + CGFloat(dx) * outer, y: point.y + CGFloat(dy) * outer))
            ctx.addLine(to: CGPoint(x: point.x + CGFloat(dx) * inner, y: point.y + CGFloat(dy) * inner))
        }
        ctx.setLineWidth(radius * 0.24)
        ctx.strokePath()
    }

    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - 屏幕

    private static func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 8, &ids, &count) == .success, count > 0 else {
            return CGMainDisplayID()
        }
        return ids[0]
    }

    private static func backingScale(of displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == displayID { return screen.backingScaleFactor }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private static func shortReason(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
