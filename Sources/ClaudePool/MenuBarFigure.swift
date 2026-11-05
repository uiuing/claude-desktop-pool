import AppKit

/// The menu bar item: Claude's mark and, beside it, the shown plan's 5-hour limit over its weekly
/// one. It is one template image, so the menu bar tints it like its own items and the two lines
/// stay aligned; a plan with only one of the two limits shows that one at full size.
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
        let height: CGFloat = 22, markSize: CGFloat = 16
        let mark = ClaudeMark.menuBar(size: markSize)
        let lines = [figures?.session, figures?.week].compactMap { $0 }.map { "\($0)%" }
        let stacked = lines.count == 2
        let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9.5 : 12.5, weight: stacked ? .semibold : .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let sizes = lines.map { ($0 as NSString).size(withAttributes: attributes) }
        let textWidth = ceil(sizes.map(\.width).max() ?? 0)
        let width = markSize + (lines.isEmpty ? 0 : 3) + textWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            mark.draw(in: NSRect(x: 0, y: (height - markSize) / 2, width: markSize, height: markSize))
            // Line boxes carry their own leading; stacked lines overlap it slightly to stay compact.
            let overlap: CGFloat = stacked ? 1.5 : 0
            var top = (height + sizes.reduce(0) { $0 + $1.height } - overlap * CGFloat(max(0, sizes.count - 1))) / 2
            for (line, size) in zip(lines, sizes) {
                top -= size.height
                // Right-aligned, so the percent signs line up and digits never shift as they change.
                (line as NSString).draw(at: NSPoint(x: width - size.width, y: top), withAttributes: attributes)
                top += overlap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func accessibility(_ figures: MenuBarFigures, model: PoolAppModel) -> String {
        [figures.session.map { model.t("5 hours: {0}% left", "\($0)") }, figures.week.map { model.t("7 days: {0}% left", "\($0)") }]
            .compactMap { $0 }.joined(separator: ", ")
    }
}
