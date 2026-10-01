import AppKit
import ScreenCaptureKit

/// Captures the target window (or the main display) as a JPEG, optionally
/// with numbered boxes drawn over the observed elements ("set-of-marks"), so
/// a vision model can answer with an element id instead of coordinates.
@MainActor
enum Screenshot {
    static func capture(target: TargetApp, observer: Observer, area: String, maxWidth: Int, marks: Bool) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw HelperError("Screen Recording permission is not granted to the terminal running pi")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var filter: SCContentFilter
        var captured = "screen"
        var originPoints = CGPoint.zero
        var sizePoints: CGSize

        if area == "window", let app = target.application,
           let windowID = frontWindowID(of: app.processIdentifier),
           let window = content.windows.first(where: { $0.windowID == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            captured = "window"
            originPoints = window.frame.origin
            sizePoints = window.frame.size
        } else {
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                throw HelperError("no display to capture")
            }
            let own = content.windows.filter { $0.owningApplication?.processID == ownPID }
            filter = SCContentFilter(display: display, excludingWindows: own)
            sizePoints = CGDisplayBounds(display.displayID).size
        }

        let pixelWidth = min(Double(maxWidth), sizePoints.width * 2)
        let scale = pixelWidth / sizePoints.width
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(sizePoints.width * scale))
        configuration.height = max(1, Int(sizePoints.height * scale))
        configuration.showsCursor = false
        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

        if marks {
            let elements = observer.currentElements
            if let marked = drawMarks(on: image, elements: elements, origin: originPoints, scale: scale) { image = marked }
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            throw HelperError("JPEG encoding failed")
        }
        return [
            "jpegBase64": jpeg.base64EncodedString(),
            "pixelWidth": image.width,
            "pixelHeight": image.height,
            "originX": originPoints.x,
            "originY": originPoints.y,
            "pointWidth": sizePoints.width,
            "pointHeight": sizePoints.height,
            "area": captured,
        ]
    }

    private static func frontWindowID(of pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Double],
                  (bounds["Width"] ?? 0) > 80, (bounds["Height"] ?? 0) > 80,
                  let number = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return number
        }
        return nil
    }

    private static func drawMarks(on image: CGImage, elements: [ObservedElement], origin: CGPoint, scale: Double) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let palette: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for element in elements {
            // Convert global points to image pixels (CG origin is bottom-left).
            let x = (element.frame.minX - origin.x) * scale
            let yTop = (element.frame.minY - origin.y) * scale
            let rect = CGRect(x: x, y: Double(height) - yTop - element.frame.height * scale,
                              width: element.frame.width * scale, height: element.frame.height * scale)
            guard rect.intersects(CGRect(x: 0, y: 0, width: width, height: height)) else { continue }
            let color = palette[element.id % palette.count]
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(max(1.5, scale))
            context.stroke(rect)

            let label = "\(element.id)" as NSString
            let font = NSFont.boldSystemFont(ofSize: max(10, 11 * scale))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            let tag = CGRect(x: rect.minX, y: min(Double(height) - size.height - 2, rect.maxY - size.height - 2),
                             width: size.width + 4, height: size.height + 2)
            context.setFillColor(color.cgColor)
            context.fill(tag)
            label.draw(at: CGPoint(x: tag.minX + 2, y: tag.minY + 1), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
