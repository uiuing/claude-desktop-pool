import AppKit

/// The menu bar item: Claude's mark, the shown plan's 5-hour limit over its weekly one and, beside
/// them, its tightest model limit ("F72%") in the type of a single figure, as the menu bar's own items
/// are written. It is one template image, so the menu bar tints it like its own items and the figures
/// stay aligned; a plan with only one of the two limits shows it in that type too.
@MainActor enum MenuBarFigure {
    private static var cache: [MenuBarFigures?: NSImage] = [:]

    static func image(_ figures: MenuBarFigures?) -> NSImage {
        if let cached = cache[figures] { return cached }
        if cache.count > 32 { cache.removeAll() }
        let made = draw(figures)
        cache[figures] = made
        return made
    }

    private static func draw(_ figures: MenuBarFigures?) -> NSImage {
        let height: CGFloat = 22, markSize: CGFloat = 16, gap: CGFloat = 5
        let mark = ClaudeMark.menuBar(size: markSize)
        let layout: (stacked: [String], beside: String?) = figures?.layout ?? (stacked: [], beside: nil)
        let lines = layout.stacked
        let stacked = lines.count == 2
        let single = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let font = stacked ? NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold) : single
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // The model limit is one figure, so it is written as a single figure is, centred on the bar.
        let besideAttributes: [NSAttributedString.Key: Any] = [.font: single, .foregroundColor: NSColor.black]
        let sizes = lines.map { ($0 as NSString).size(withAttributes: attributes) }
        let columnWidth = ceil(sizes.map(\.width).max() ?? 0)
        let besideSize = layout.beside.map { ($0 as NSString).size(withAttributes: besideAttributes) }
        let besideWidth = besideSize.map { ceil($0.width) + gap } ?? 0
        let columnRight = markSize + (lines.isEmpty ? 0 : 3) + columnWidth
        let width = columnRight + besideWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            mark.draw(in: NSRect(x: 0, y: (height - markSize) / 2, width: markSize, height: markSize))
            // Line boxes carry their own leading; stacked lines overlap it slightly to stay compact.
            let overlap: CGFloat = lines.count == 2 ? 1.5 : 0
            var top = (height + sizes.reduce(0) { $0 + $1.height } - overlap * CGFloat(max(0, sizes.count - 1))) / 2
            for (line, size) in zip(lines, sizes) {
                top -= size.height
                // Right-aligned, so the percent signs line up and digits never shift as they change.
                (line as NSString).draw(at: NSPoint(x: columnRight - size.width, y: top), withAttributes: attributes)
                top += overlap
            }
            if let beside = layout.beside, let size = besideSize {
                (beside as NSString).draw(at: NSPoint(x: width - size.width, y: (height - size.height) / 2), withAttributes: besideAttributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Which limit each figure is: "5 hours: 79% left, 7 days: 70% left, Fable 7 days: 72% left".
    static func accessibility(_ figures: MenuBarFigures, model: PoolAppModel) -> String {
        [figures.session.map { model.t("5 hours: {0}% left", "\($0)") },
         figures.week.map { model.t("7 days: {0}% left", "\($0)") },
         figures.modelPercent.map { model.t("{0} 7 days: {1}% left", figures.model ?? "", "\($0)") }].compactMap { $0 }.joined(separator: ", ")
    }
}
