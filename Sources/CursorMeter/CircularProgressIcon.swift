import AppKit

// MARK: - Progress Level

enum ProgressLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    var color: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        }
    }
}

// MARK: - Circular Progress Icon

enum CircularProgressIcon {
    /// Shared color tokens used by the menu-bar ring and the popover weekly chart.
    /// Reused across surfaces so heat color never drifts between views.
    static let accentColor = NSColor(red: 0.20, green: 0.70, blue: 0.25, alpha: 1)
    static let warnColor = NSColor(red: 0.95, green: 0.65, blue: 0.0, alpha: 1)
    static let critColor = NSColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1)

    static func level(for percent: Double) -> ProgressLevel {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }

    /// Maps a plan-percent (0–100+) to one of the shared color tokens.
    /// Single source of truth for both the menu-bar ring and the popover
    /// progress bar — prevents the bands from drifting (e.g. ring=green
    /// while progress bar=yellow at the same value).
    static func tokenColor(for percent: Double) -> NSColor {
        if percent >= 90 { return critColor }
        if percent >= 70 { return warnColor }
        return accentColor
    }

    /// Icon only, drawn in the requested style.
    @MainActor
    static func menuBarImage(percent: Double, style: MenuBarIconStyle, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawGlyph(in: ctx, rect: rect, percent: percent, style: style)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Icon + fraction text (used / limit) as a single NSImage
    @MainActor
    static func menuBarImageWithText(
        percent: Double,
        style: MenuBarIconStyle,
        usedText: String,
        limitText: String
    ) -> NSImage {
        let pieSize: CGFloat = 20
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let textColor = NSColor.labelColor

        let usedStr = NSAttributedString(string: usedText, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let limitStr = NSAttributedString(string: limitText, attributes: [
            .font: font, .foregroundColor: textColor,
        ])

        let usedSize = usedStr.size()
        let limitSize = limitStr.size()
        let textWidth = max(usedSize.width, limitSize.width)
        let lineHeight: CGFloat = 1
        let textBlockHeight = usedSize.height + lineHeight + limitSize.height
        let gap: CGFloat = 3

        let totalWidth = pieSize + gap + textWidth + 1
        let totalHeight: CGFloat = 22

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw pie (vertically centered)
            let pieY = (totalHeight - pieSize) / 2
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pieY)
            let pieRect = CGRect(x: 0, y: 0, width: pieSize, height: pieSize)
            drawGlyph(in: ctx, rect: pieRect, percent: percent, style: style)
            ctx.restoreGState()

            // Draw fraction text (vertically centered)
            let textX = pieSize + gap
            let textY = (totalHeight - textBlockHeight) / 2

            // Limit (bottom)
            limitStr.draw(at: NSPoint(
                x: textX + (textWidth - limitSize.width) / 2,
                y: textY
            ))

            // Divider line
            let lineY = textY + limitSize.height + lineHeight / 2
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: textX, y: lineY))
            ctx.addLine(to: CGPoint(x: textX + textWidth, y: lineY))
            ctx.strokePath()

            // Used (top)
            usedStr.draw(at: NSPoint(
                x: textX + (textWidth - usedSize.width) / 2,
                y: textY + limitSize.height + lineHeight
            ))

            return true
        }
        image.isTemplate = false
        return image
    }

    /// Icon + percent text as a single NSImage
    @MainActor
    static func menuBarImageWithPercent(percent: Double, style: MenuBarIconStyle) -> NSImage {
        let pieSize: CGFloat = 20
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let textColor = NSColor.labelColor

        let percentStr = NSAttributedString(string: String(format: "%.1f%%", percent), attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let textSize = percentStr.size()
        let gap: CGFloat = 3

        let totalWidth = pieSize + gap + textSize.width + 1
        let totalHeight: CGFloat = 22

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw pie (vertically centered)
            let pieY = (totalHeight - pieSize) / 2
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pieY)
            let pieRect = CGRect(x: 0, y: 0, width: pieSize, height: pieSize)
            drawGlyph(in: ctx, rect: pieRect, percent: percent, style: style)
            ctx.restoreGState()

            // Draw percent text (vertically centered)
            let textX = pieSize + gap
            let textY = (totalHeight - textSize.height) / 2
            percentStr.draw(at: NSPoint(x: textX, y: textY))

            return true
        }
        image.isTemplate = false
        return image
    }

    /// "Cursor Meter" text icon for idle/not-logged-in state
    static func idleImage() -> NSImage {
        let topFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let bottomFont = NSFont.systemFont(ofSize: 6, weight: .regular)
        let color = NSColor.labelColor

        let topStr = NSAttributedString(string: "Cursor", attributes: [
            .font: topFont, .foregroundColor: color,
        ])
        let bottomStr = NSAttributedString(string: "Meter", attributes: [
            .font: bottomFont, .foregroundColor: color,
        ])

        let topSize = topStr.size()
        let bottomSize = bottomStr.size()
        let width = max(topSize.width, bottomSize.width) + 2
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let totalText = topSize.height + bottomSize.height
            let startY = (height - totalText) / 2

            bottomStr.draw(at: NSPoint(
                x: (width - bottomSize.width) / 2,
                y: startY
            ))
            topStr.draw(at: NSPoint(
                x: (width - topSize.width) / 2,
                y: startY + bottomSize.height
            ))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Idle logo + warning badge — shown when the stored session has expired
    /// and the user must log in again. Distinct from `idleImage()` so the
    /// expired state doesn't look identical to fresh-launch idle (#76,
    /// docs/mockup-issue-76-login-icon.html candidate C).
    ///
    /// Composites the existing `idleImage()` rather than redrawing the logo —
    /// the drawing handler re-runs at render time, so `labelColor` inside the
    /// nested image stays appearance-dynamic.
    static func loginRequiredImage() -> NSImage {
        let logo = idleImage()
        let badgeRadius: CGFloat = 4
        // Badge overhangs the logo's top-right corner; widen the canvas so it never clips.
        let size = NSSize(width: logo.size.width + badgeRadius, height: logo.size.height)

        let image = NSImage(size: size, flipped: false) { _ in
            logo.draw(
                at: .zero, from: .zero, operation: .sourceOver, fraction: 1)

            // Warning badge, top-right. Black "!" on warnColor reads in both
            // light and dark menu bars.
            let badgeCenter = NSPoint(x: size.width - badgeRadius, y: size.height - badgeRadius)
            let badgeRect = NSRect(
                x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                width: badgeRadius * 2, height: badgeRadius * 2)
            warnColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let bang = NSAttributedString(string: "!", attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .heavy),
                .foregroundColor: NSColor.black,
            ])
            let bangSize = bang.size()
            bang.draw(at: NSPoint(
                x: badgeCenter.x - bangSize.width / 2,
                y: badgeCenter.y - bangSize.height / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Renders an emoji glyph centered in a fixed-size NSImage suitable for
    /// `NSStatusItem.button.image` swap. Used for the usage-jump effect.
    ///
    /// The returned image's `size` matches the requested `size` exactly so that
    /// swapping it onto a pinned-length status item never shifts the slot.
    ///
    /// - Parameters:
    ///   - emoji: single Unicode scalar / sequence (e.g. `"⚡"`, `"🚀"`).
    ///   - size: target image size; should match the ring image size.
    ///   - glow: when `true`, attaches a red drop-shadow halo behind the glyph.
    static func makeEmojiImage(emoji: String, size: NSSize, glow: Bool = false) -> NSImage {
        // Font sized so a typical emoji glyph fills ~78% of the image height.
        let fontSize = size.height * 0.78
        let font = NSFont.systemFont(ofSize: fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]

        if glow {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = max(2, size.height * 0.18)
            shadow.shadowColor = NSColor.systemRed.withAlphaComponent(0.6)
            shadow.shadowOffset = .zero
            attrs[.shadow] = shadow
        }

        let attributed = NSAttributedString(string: emoji, attributes: attrs)
        let textSize = attributed.size()

        let image = NSImage(size: size, flipped: false) { rect in
            // Slight inset keeps any drop-shadow halo within image bounds.
            let inset: CGFloat = glow ? max(1, rect.height * 0.08) : 0
            let drawRect = rect.insetBy(dx: inset, dy: inset)

            // Center the glyph: NSAttributedString.draw uses the typographic
            // bounding box, so subtract the measured size from the available
            // box to obtain origin for visual centering.
            let originX = drawRect.minX + (drawRect.width - textSize.width) / 2
            let originY = drawRect.minY + (drawRect.height - textSize.height) / 2
            attributed.draw(at: NSPoint(x: originX, y: originY))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Private

    private static func pieColor(for percent: Double) -> NSColor {
        tokenColor(for: percent)
    }

    // MARK: - Glyph (menu-bar icon styles)

    /// Draws the icon body for `style` into `rect`. Every style is monochrome:
    /// the menu bar slot is rendered with `labelColor` so it matches the rest
    /// of the menu bar in both appearances.
    private static func drawGlyph(
        in ctx: CGContext,
        rect: CGRect,
        percent: Double,
        style: MenuBarIconStyle
    ) {
        func drawMark(in markRect: CGRect) { drawCursorMark(in: ctx, rect: markRect) }

        switch style {
        case .pie:
            // Legacy shape, de-colored: track at 20% vs full-strength wedge
            // still reads as progress without introducing a hue.
            drawPie(in: ctx, rect: rect, percent: percent, color: NSColor.labelColor)
        case .cursor:
            let barHeight = max(1.5, rect.height * 0.11)
            let gap: CGFloat = 2
            var glyphRect = rect
            glyphRect.size.height -= (barHeight + gap)
            // Lift the cube off the bottom: in this y-up context a CGRect's
            // origin is its lower-left corner, so shrinking the height alone
            // keeps the cube sitting on the bar.
            glyphRect.origin.y += (barHeight + gap)
            drawMark(in: glyphRect)
            drawUnderlineProgress(in: ctx, rect: rect, percent: percent, barHeight: barHeight)
        case .ring:
            drawRing(in: ctx, rect: rect, percent: percent)
            drawMark(in: rect.insetBy(dx: rect.width * 0.30, dy: rect.height * 0.26))
        case .cursorText:
            // The cube is drawn next to 13pt percent text in a 20pt slot; at
            // full size it dwarfs the digits. Inset to roughly the text's
            // visual height so the two read as one unit.
            drawMark(in: rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.10))
        case .badge:
            drawMark(in: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.10))
            drawBadgeRing(in: ctx, rect: rect, percent: percent)
        }
    }

    /// Width : height of the cube's bounding box (2a wide by 4a/√3 tall).
    private static let cursorMarkAspect: CGFloat = 0.866

    /// Cursor's mark: a solid isometric cube with the brand's crease carved out
    /// of it.
    ///
    /// The construction is Cursor's own, read off `cursor.com/favicon.svg`
    /// (512×512): one subpath is the cube's hexagon, the second runs backwards
    /// through it and is knocked out, leaving the crease as a hole. The crease's
    /// four points land on the cube's own landmarks rather than being a glyph
    /// pasted on top:
    ///   crease left tip   → cube upper-left vertex
    ///   crease top tip    → cube upper-right vertex
    ///   crease bottom tip → cube bottom vertex
    ///   crease elbow      → cube centre
    /// so it crosses the top, left and right faces in one folded band. The
    /// vertices are pulled ~6% toward the middle (the official art insets them
    /// too) so the crease reads as a fold *inside* the silhouette instead of
    /// splitting it.
    ///
    /// Drawn rather than loaded from the IDE bundle: the app icon is full-colour
    /// artwork on a squircle, and in the menu bar — where every neighbouring
    /// icon is a monochrome template — it reads as a foreign block. Painting
    /// with `labelColor` keeps it white on dark menu bars and black on light
    /// ones, like the rest of the bar.
    private static func drawCursorMark(in ctx: CGContext, rect: CGRect) {
        var box = rect
        if box.width / box.height > cursorMarkAspect {
            box.size.width = box.height * cursorMarkAspect
            box.origin.x = rect.midX - box.width / 2
        } else {
            box.size.height = box.width / cursorMarkAspect
            box.origin.y = rect.midY - box.height / 2
        }

        let a = box.width / 2
        let h = a / Double(3).squareRoot()
        let cx = box.midX
        let cy = box.midY

        // The image is built with `flipped: false`, so this context is y-up:
        // a larger y sits higher on screen. The cube's landmarks are named for
        // what the eye sees, which is the opposite of the raw axis — getting
        // this backwards renders the whole cube upside down.
        let apex = CGPoint(x: cx, y: cy + 2 * h)
        let upperRight = CGPoint(x: cx + a, y: cy + h)
        let lowerRight = CGPoint(x: cx + a, y: cy - h)
        let base = CGPoint(x: cx, y: cy - 2 * h)
        let lowerLeft = CGPoint(x: cx - a, y: cy - h)
        let upperLeft = CGPoint(x: cx - a, y: cy + h)
        let centre = CGPoint(x: cx, y: cy)

        // Solid cube.
        ctx.setFillColor(NSColor.labelColor.cgColor)
        ctx.addLines(between: [apex, upperRight, lowerRight, base, lowerLeft, upperLeft])
        ctx.closePath()
        ctx.fillPath()

        // Knock the crease out. The concave quad is the two triangles of
        // Cursor's own `cursor_mini.svg` (A,B,C and D,B,C — C is the elbow,
        // shared by both), remapped onto the cube's vertices.
        let inset: CGFloat = 0.06
        func pull(_ p: CGPoint) -> CGPoint {
            CGPoint(x: cx + (p.x - cx) * (1 - inset),
                    y: cy + (p.y - cy) * (1 - inset))
        }
        let creaseLeft = pull(upperLeft)
        let creaseTop = pull(upperRight)
        let creaseBottom = pull(base)
        let creaseElbow = centre

        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(NSColor.black.cgColor)
        for triangle in [
            [creaseLeft, creaseTop, creaseElbow],
            [creaseBottom, creaseTop, creaseElbow],
        ] {
            ctx.addLines(between: triangle)
            ctx.closePath()
            ctx.fillPath()
        }
        ctx.setBlendMode(.normal)
    }

    private static func drawRing(in ctx: CGContext, rect: CGRect, percent: Double) {
        let lineWidth = max(1.2, rect.width * 0.11)
        let radius = (min(rect.width, rect.height) - lineWidth) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)

        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()

        let progress = min(max(percent / 100.0, 0), 1.0)
        guard progress > 0 else { return }
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        ctx.setLineCap(.round)
        let start = CGFloat.pi / 2
        ctx.addArc(center: center, radius: radius, startAngle: start,
                   endAngle: start - 2 * .pi * progress, clockwise: true)
        ctx.strokePath()
    }

    private static func drawUnderlineProgress(
        in ctx: CGContext, rect: CGRect, percent: Double, barHeight: CGFloat
    ) {
        let track = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: barHeight)
        let radius = barHeight / 2
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.25).cgColor)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        let progress = min(max(percent / 100.0, 0), 1.0)
        guard progress > 0 else { return }
        var fill = track
        fill.size.width = max(barHeight, track.width * CGFloat(progress))
        ctx.setFillColor(NSColor.labelColor.cgColor)
        ctx.addPath(CGPath(roundedRect: fill, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    private static func drawBadgeRing(in ctx: CGContext, rect: CGRect, percent: Double) {
        let radius = rect.width * 0.22
        let center = CGPoint(x: rect.maxX - radius, y: rect.maxY - radius)
        ctx.setLineWidth(max(1, radius * 0.55))
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.25).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()

        let progress = min(max(percent / 100.0, 0), 1.0)
        guard progress > 0 else { return }
        ctx.setStrokeColor(NSColor.labelColor.cgColor)
        let start = CGFloat.pi / 2
        ctx.addArc(center: center, radius: radius, startAngle: start,
                   endAngle: start - 2 * .pi * progress, clockwise: true)
        ctx.strokePath()
    }

    private static func drawPie(in ctx: CGContext, rect: CGRect, percent: Double, color: NSColor? = nil) {
        let inset: CGFloat = 1
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) - inset * 2) / 2

        // Track (adapts to system appearance)
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.2).cgColor)
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2)
        ctx.addEllipse(in: circleRect)
        ctx.fillPath()

        // Border
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(0.75)
        ctx.addEllipse(in: circleRect)
        ctx.strokePath()

        // Pie wedge
        let progress = min(max(percent / 100.0, 0), 1.0)
        if progress > 0 {
            let nsColor = color ?? pieColor(for: percent)
            ctx.setFillColor(nsColor.cgColor)

            let startAngle = CGFloat.pi / 2
            let endAngle = startAngle - (2 * .pi * progress)

            ctx.move(to: center)
            ctx.addArc(center: center, radius: radius,
                       startAngle: startAngle, endAngle: endAngle, clockwise: true)
            ctx.closePath()
            ctx.fillPath()
        }
    }
}
