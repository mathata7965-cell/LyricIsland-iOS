import Foundation
import UIKit

struct ArtworkAppearance {
    let image: UIImage
    let thumbnailData: Data?
    let accentRed: Double
    let accentGreen: Double
    let accentBlue: Double

    static let defaultAccent = (red: 1.0, green: 0.231, blue: 0.188)
}

enum ArtworkColorExtractor {
    static func process(_ image: UIImage) -> ArtworkAppearance {
        let thumbData = makeCompactThumbnail(from: image)
        let rgb = dominantVibrantRGB(from: image) ?? ArtworkAppearance.defaultAccent
        return ArtworkAppearance(
            image: image,
            thumbnailData: thumbData,
            accentRed: rgb.red,
            accentGreen: rgb.green,
            accentBlue: rgb.blue
        )
    }

    static func makeCompactThumbnail(from image: UIImage) -> Data? {
        let targetSize = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        for quality in [0.48, 0.34, 0.22] {
            if let data = resized.jpegData(compressionQuality: quality), data.count <= 1450 {
                return data
            }
        }
        return nil
    }

    private static func dominantVibrantRGB(from image: UIImage) -> (red: Double, green: Double, blue: Double)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = 16
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var bestScore: Double = 0
        var bestRGB: (Double, Double, Double)?

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0
            let a = Double(pixels[i + 3]) / 255.0
            if a < 0.5 { continue }

            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let delta = maxC - minC
            let saturation = maxC > 0.01 ? delta / maxC : 0
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b

            // Skip near-black, pure white, or muddy dark pixels so OLED contrast stays sharp
            guard luminance >= 0.22, luminance <= 0.88, saturation >= 0.24 else { continue }

            let score = saturation * (1.0 - abs(luminance - 0.56))
            if score > bestScore {
                bestScore = score
                // Boost readability slightly on OLED black background
                let boost = maxC < 0.72 ? (0.78 / max(maxC, 0.1)) : 1.0
                bestRGB = (
                    min(1.0, r * boost),
                    min(1.0, g * boost),
                    min(1.0, b * boost)
                )
            }
        }
        return bestRGB
    }
}
