import AppKit
import SwiftUI

/// Render the production view against the compiled application asset catalog.
/// This deliberately uses SwiftUI's colorScheme rather than changing macOS appearance.
@main
struct BrandAppearanceRegression {
    struct Sample: Codable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        var brightness: Double { (red + green + blue) / 3 }
        var isRed: Bool { red > 0.65 && green < 0.45 && blue < 0.4 && red > green * 1.7 }
    }

    struct Fixture: Codable {
        let appearance: String
        let sizePoints: Int
        let widthPixels: Int
        let heightPixels: Int
        let background: Sample
        let blade: Sample
        let accent: Sample
        let corner: Sample
    }

    enum Failure: Error {
        case invalidArguments
        case missingBundle(String)
        case render(String)
        case assertion(String)
    }

    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            print("Usage: brand-appearance-check <built Xtrim.app> <output-directory>")
            throw Failure.invalidArguments
        }
        let bundlePath = CommandLine.arguments[1]
        guard let bundle = Bundle(path: bundlePath),
              bundle.url(forResource: "Assets", withExtension: "car") != nil else {
            throw Failure.missingBundle(bundlePath)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sizes = [16, 32, 64, 128, 256, 512]
        let themes: [(String, ColorScheme)] = [("light", .light), ("dark", .dark)]
        var fixtures: [Fixture] = []
        var failures: [String] = []

        func sample(_ bitmap: NSBitmapImageRep, _ x: Double, _ y: Double) -> Sample {
            let color = bitmap.colorAt(
                x: min(bitmap.pixelsWide - 1, Int(Double(bitmap.pixelsWide) * x)),
                y: min(bitmap.pixelsHigh - 1, Int(Double(bitmap.pixelsHigh) * y))
            )!.usingColorSpace(.sRGB)!
            return Sample(red: color.redComponent, green: color.greenComponent,
                          blue: color.blueComponent, alpha: color.alphaComponent)
        }

        func save(_ image: CGImage, name: String) throws -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(cgImage: image)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw Failure.render("PNG encoding: \(name)")
            }
            try data.write(to: output.appendingPathComponent(name + ".png"))
            return bitmap
        }

        for (name, scheme) in themes {
            for size in sizes {
                let view = WgBrandIcon(bundle: bundle)
                    .frame(width: CGFloat(size), height: CGFloat(size))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.cgImage else { throw Failure.render("\(name)-\(size)") }
                let bitmap = try save(image, name: "brand-\(name)-\(size)pt")
                let fixture = Fixture(
                    appearance: name, sizePoints: size,
                    widthPixels: image.width, heightPixels: image.height,
                    background: sample(bitmap, 0.2, 0.2),
                    blade: sample(bitmap, 0.8, 0.45),
                    accent: sample(bitmap, 0.70, 0.375),
                    corner: sample(bitmap, 0.01, 0.01))
                fixtures.append(fixture)
                if image.width != size * 2 || image.height != size * 2 {
                    failures.append("\(name) \(size)pt: unexpected rendered dimensions")
                }
                if fixture.background.alpha < 0.99 || fixture.blade.alpha < 0.99 {
                    failures.append("\(name) \(size)pt: missing opaque artwork")
                }
                if fixture.corner.alpha > 0.01 {
                    failures.append("\(name) \(size)pt: rounded-corner transparency lost")
                }
                // Precise samples are intentionally taken away from antialiased edges.
                // The 128 pt check catches an appearance catalog that silently stays dark.
                if size == 128 {
                    let backgroundCorrect = scheme == .light
                        ? fixture.background.brightness > 0.8 : fixture.background.brightness < 0.2
                    let bladeCorrect = scheme == .light
                        ? fixture.blade.brightness < 0.2 : fixture.blade.brightness > 0.8
                    if !backgroundCorrect { failures.append("\(name): incorrect background appearance") }
                    if !bladeCorrect { failures.append("\(name): incorrect crossing-plane appearance") }
                    if !fixture.accent.isRed { failures.append("\(name): vermilion accent missing or changed") }
                }
            }
        }

        let light = fixtures.first { $0.appearance == "light" && $0.sizePoints == 128 }!
        let dark = fixtures.first { $0.appearance == "dark" && $0.sizePoints == 128 }!
        func sameColor(_ lhs: Sample, _ rhs: Sample) -> Bool {
            abs(lhs.red - rhs.red) < 0.005 && abs(lhs.green - rhs.green) < 0.005
                && abs(lhs.blue - rhs.blue) < 0.005 && abs(lhs.alpha - rhs.alpha) < 0.005
        }
        if !sameColor(light.accent, dark.accent) {
            failures.append("the vermilion accent must remain identical across appearances")
        }
        if !sameColor(light.background, dark.blade) || !sameColor(light.blade, dark.background) {
            failures.append("the two appearances must exchange the same light and dark palette")
        }

        let preview = HStack(alignment: .top, spacing: 0) {
            ForEach(themes, id: \.0) { name, scheme in
                VStack(spacing: 20) {
                    Text(name == "light" ? "浅色 · 浅底黑 X" : "深色 · 黑底白 X")
                        .font(.system(size: 22, weight: .medium))
                    ForEach(sizes, id: \.self) { size in
                        VStack(spacing: 8) {
                            WgBrandIcon(bundle: bundle)
                                .frame(width: CGFloat(size), height: CGFloat(size))
                            Text("\(size) pt").font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(28)
                .frame(width: 570)
                .foregroundStyle(scheme == .light ? Color.black : Color.white)
                .background(scheme == .light ? Color(white: 0.96) : Color(white: 0.12))
                .environment(\.colorScheme, scheme)
            }
        }
        let previewRenderer = ImageRenderer(content: preview)
        previewRenderer.scale = 1
        guard let previewImage = previewRenderer.cgImage else { throw Failure.render("comparison") }
        _ = try save(previewImage, name: "light-dark-comparison")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixtures).write(to: output.appendingPathComponent("appearance-samples.json"))
        let report: [String: Any] = [
            "bundle": bundlePath,
            "productionView": "WgBrandIcon",
            "renderer": "SwiftUI.ImageRenderer",
            "scale": 2,
            "fixtureCount": fixtures.count,
            "failures": failures,
            "passed": failures.isEmpty,
            "systemAppearanceChanged": false,
            "mainAppLaunched": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("appearance-check.json"))
        if !failures.isEmpty { throw Failure.assertion(failures.joined(separator: "; ")) }
        print("PASS: \(fixtures.count)/\(fixtures.count) native brand fixtures; both appearance palettes, accent, dimensions and transparent corners verified")
    }
}
