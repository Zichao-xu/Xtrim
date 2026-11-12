import AppKit
import SwiftUI

// Uses the production view and compiled asset catalog, without launching WgSense.
@main
struct BrandMedia {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3,
              let bundle = Bundle(path: CommandLine.arguments[1]),
              bundle.url(forResource: "Assets", withExtension: "car") != nil else {
            fatalError("Usage: render-brand <built Xtrim.app> <output PNG>")
        }
        let view = HStack(spacing: 0) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                VStack(spacing: 18) {
                    WgBrandIcon(bundle: bundle).frame(width: 210, height: 210)
                    Text(scheme == .light ? "浅色 · 浅底黑 X" : "深色 · 黑底白 X")
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(width: 360, height: 320)
                .foregroundStyle(scheme == .light ? Color(white: 0.15) : Color(white: 0.87))
                .background(scheme == .light ? Color(white: 0.96) : Color(white: 0.085))
                .environment(\.colorScheme, scheme)
            }
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            fatalError("Could not render native brand media")
        }
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
