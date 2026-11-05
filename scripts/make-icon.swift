import AppKit

// Writes .build/AppIcon.iconset from the app's own logo art (Sources/ClaudePool/PoolIconArt.swift).
//   swiftc -parse-as-library -o .build/make-icon Sources/ClaudePool/PoolIconArt.swift scripts/make-icon.swift
//   .build/make-icon [preview.png]

@main
struct MakeIcon {
    static func write(_ image: CGImage?, to url: URL) throws {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    static func main() throws {
        let directory = URL(fileURLWithPath: ".build/AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                try write(PoolIconArt.icon(pixels: size * scale), to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        if CommandLine.arguments.count > 1 {
            try write(PoolIconArt.icon(pixels: 1024), to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }
}
