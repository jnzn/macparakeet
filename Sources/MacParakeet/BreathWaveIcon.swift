import AppKit

/// Generates the MacParakeet "Cursive P" logo programmatically.
///
/// Design: An enclosed circular bowl with a dot inside, and a cursive loop tail
/// that descends, loops under, and trails off left. The loop echoes the bowl's
/// circular rhythm — two circles in harmony.
///
/// Inspired by Daoist simplicity: a single stroke forming a P with a bird's-eye
/// dot at center. The cursive tail gives it handwritten warmth.
///
/// The icon is drawn via Core Graphics so it scales perfectly at any size
/// and works as a template image (adapts to light/dark mode automatically).
enum BreathWaveIcon {

    // MARK: - Canonical Geometry (128×128 viewBox)

    // Bowl: circle cx=68, cy=34, r=26
    // Dot: cx=68, cy=34, r=6
    // Stem + cursive loop tail:
    //   M 42,34 L 42,82 C 42,100 30,110 18,112 C 6,114 2,106 8,98 C 14,90 30,88 42,92
    // Stroke width: 7 (large), 10 (small/menu bar)

    /// Menu bar icon state variants.
    enum MenuBarState {
        case idle
        case recording
        case processing
    }

    /// Load the parakeet silhouette as a **template** NSImage for menu bar use.
    /// The image is stored as a processed SwiftPM resource (menubar-icon.png / @2x).
    /// Template images adapt to light/dark mode automatically.
    static func menuBarIcon(pointSize: CGFloat = 18, state: MenuBarState = .idle) -> NSImage {
        let baseIcon = loadBaseMenuBarIcon(pointSize: pointSize)

        switch state {
        case .idle:
            return baseIcon
        case .recording:
            return compositeIcon(base: baseIcon, pointSize: pointSize, badgeColor: .systemRed)
        case .processing:
            return compositeIcon(base: baseIcon, pointSize: pointSize, badgeColor: .systemOrange)
        }
    }

    private static func loadBaseMenuBarIcon(pointSize: CGFloat) -> NSImage {
        // Try loading from SwiftPM resource bundle first, then fall back to main bundle.
        if let url = Bundle.module.url(forResource: "menubar-icon@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: pointSize, height: pointSize)
            image.isTemplate = true
            return image
        }

        // Fallback: 1x version
        if let url = Bundle.module.url(forResource: "menubar-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: pointSize, height: pointSize)
            image.isTemplate = true
            return image
        }

        // Last resort: return a system symbol
        let fallback = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MacParakeet")
            ?? NSImage()
        fallback.size = NSSize(width: pointSize, height: pointSize)
        fallback.isTemplate = true
        return fallback
    }

    /// Composite the base icon with a colored status dot in the bottom-right corner.
    /// The resulting image is NOT a template (so the dot renders in color).
    /// The base icon is drawn using the menu bar's label color so it matches
    /// the idle template appearance in both light and dark mode.
    private static func compositeIcon(base: NSImage, pointSize: CGFloat, badgeColor: NSColor) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { rect in
            // Use the base icon alpha channel as a mask, filled with the menu bar
            // foreground color. This replicates template-image rendering while keeping
            // isTemplate=false so the colored dot isn't tinted by the system.
            // NSStatusBar items use controlTextColor which is white on dark menu bars
            // and black on light ones (pre-Sonoma or accessibility settings).
            if let cgBase = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.clip(to: rect, mask: cgBase)
                NSColor.controlTextColor.setFill()
                ctx.fill(rect)
                ctx.restoreGState()
            }

            // Draw colored dot (bottom-right, 5pt diameter)
            let dotSize: CGFloat = 5
            let dotRect = NSRect(
                x: rect.maxX - dotSize - 0.5,
                y: 0.5,
                width: dotSize,
                height: dotSize
            )
            badgeColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            return true
        }
        // NOT a template — the dot must render in color
        image.isTemplate = false
        return image
    }

    /// Load the canonical parakeet brand mark as a transparent template
    /// NSImage, suitable for inline tinting in SwiftUI views (assistant
    /// avatars, status chips, etc.). The asset (`parakeet-mark.png`) is the
    /// same illustration used by `Assets/AppIcon-1024x1024.png`; this loader
    /// converts the white-on-near-black source to alpha-only at load so
    /// callers control color via `.renderingMode(.template)` +
    /// `.foregroundStyle()`.
    ///
    /// ## Why luminance → alpha
    /// The shipped source is a high-resolution white parakeet on a near-black
    /// background. We don't have a transparent-background variant in the
    /// repo, so we synthesize one: pixel luminance becomes alpha. The white
    /// silhouette goes fully opaque, the dark background fully transparent,
    /// and anti-aliased edges keep their soft falloff intact.
    ///
    /// The processed CGImage is cached in `templateMark` so the per-pixel
    /// pass runs at most once per process.
    static func brandMark(pointSize: CGFloat = 18) -> NSImage {
        let image: NSImage
        if let cgTemplate = templateMark {
            image = NSImage(cgImage: cgTemplate, size: NSSize(width: pointSize, height: pointSize))
        } else {
            image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        image.isTemplate = true
        return image
    }

    /// Lazy process-lifetime cache. Built on first `brandMark(...)` call,
    /// then reused for every subsequent inline render.
    private static let templateMark: CGImage? = {
        guard let url = Bundle.module.url(forResource: "parakeet-mark", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url),
              let source = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return makeLuminanceTemplate(from: source)
    }()

    /// One-pass per-pixel converter: read source RGB, write a premultiplied
    /// pixel where every channel = luminance. The result reads as a white
    /// silhouette with alpha proportional to brightness — exactly what
    /// `isTemplate = true` + SwiftUI's template rendering mode want.
    private static func makeLuminanceTemplate(from source: CGImage) -> CGImage? {
        let width = source.width
        let height = source.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)

        // Rec. 709 luminance, integer-fixed-point so the inner loop stays
        // FP-free. Coefficients sum to 1024 to keep the brightness range 0–255.
        let total = width * height
        for p in 0..<total {
            let i = p * bytesPerPixel
            let r = Int(buffer[i])
            let g = Int(buffer[i + 1])
            let b = Int(buffer[i + 2])
            let lum = UInt8(min(255, (r * 218 + g * 732 + b * 74) >> 10))
            // Premultiplied: storing (lum, lum, lum, lum) is equivalent to a
            // pure-white pixel with alpha = lum.
            buffer[i] = lum
            buffer[i + 1] = lum
            buffer[i + 2] = lum
            buffer[i + 3] = lum
        }

        return context.makeImage()
    }

    /// Create the Cursive P logo as a filled NSImage for app icon / dock use.
    /// Uses white on a colored background.
    static func appIcon(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = size / 128.0
            let cornerRadius = 22 * s

            // Background — deep teal-blue gradient
            let bg = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            let gradient = NSGradient(
                starting: NSColor(red: 0.12, green: 0.20, blue: 0.32, alpha: 1.0),
                ending: NSColor(red: 0.08, green: 0.14, blue: 0.24, alpha: 1.0)
            )
            gradient?.draw(in: bg, angle: -90)

            // White logo, centered with padding
            let padding: CGFloat = 20 * s
            let ls = (size - padding * 2) / 128.0

            NSColor.white.setStroke()
            NSColor.white.setFill()

            let bowlRadius = 26 * ls

            // Enclosed circular bowl
            let bowl = NSBezierPath(
                ovalIn: NSRect(
                    x: padding + 68 * ls - bowlRadius, y: padding + 34 * ls - bowlRadius,
                    width: bowlRadius * 2, height: bowlRadius * 2
                )
            )
            bowl.lineWidth = 7 * ls
            bowl.stroke()

            // Stem + cursive loop tail
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: padding + 42 * ls, y: padding + 34 * ls))
            tail.line(to: NSPoint(x: padding + 42 * ls, y: padding + 82 * ls))
            tail.curve(
                to: NSPoint(x: padding + 18 * ls, y: padding + 112 * ls),
                controlPoint1: NSPoint(x: padding + 42 * ls, y: padding + 100 * ls),
                controlPoint2: NSPoint(x: padding + 30 * ls, y: padding + 110 * ls)
            )
            tail.curve(
                to: NSPoint(x: padding + 8 * ls, y: padding + 98 * ls),
                controlPoint1: NSPoint(x: padding + 6 * ls, y: padding + 114 * ls),
                controlPoint2: NSPoint(x: padding + 2 * ls, y: padding + 106 * ls)
            )
            tail.curve(
                to: NSPoint(x: padding + 42 * ls, y: padding + 92 * ls),
                controlPoint1: NSPoint(x: padding + 14 * ls, y: padding + 90 * ls),
                controlPoint2: NSPoint(x: padding + 30 * ls, y: padding + 88 * ls)
            )
            tail.lineWidth = 7 * ls
            tail.lineCapStyle = .round
            tail.stroke()

            // Dot
            let dotRadius = 6 * ls
            NSBezierPath(ovalIn: NSRect(
                x: padding + 68 * ls - dotRadius, y: padding + 34 * ls - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )).fill()

            return true
        }
        return image
    }
}
