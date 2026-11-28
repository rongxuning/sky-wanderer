import Foundation

/// Rejects failed record-list map plates before they are cached or drawn.
///
/// Offscreen `MKMapView` captures can come back solid black when Tianditu tiles
/// with `canReplaceMapContent` never paint, or when Metal has not composited
/// yet. Those JPEGs used to cover the SwiftUI track stroke and stick on disk
/// forever because backfill only checked `exists`.
enum RecordListThumbnailQuality {
    /// Mean luma of a usable plate. Failed black captures sit near 0.
    /// Light backdrop alone is ~0.94; terrain tiles are mid-gray.
    static let minimumMeanLuma = 0.10
    /// Near-black pixel cutoff when measuring `darkPixelFraction`.
    static let darkLumaCeiling = 0.06
    /// A plate that is almost entirely near-black is a failed capture.
    static let maxDarkPixelFraction = 0.90
    /// Unpainted `SkyBasemapInstaller.backdrop` (~0.94) with almost no contrast.
    /// Those empty plates used to pass the black check and cover the start pin.
    static let blankMeanLuma = 0.90
    /// Minimum max−min luma for a plate that is otherwise near-backdrop bright.
    static let minimumLumaSpread = 0.06

    static func isUsable(meanLuma: Double, darkPixelFraction: Double, lumaSpread: Double = 1) -> Bool {
        guard meanLuma.isFinite,
              darkPixelFraction.isFinite,
              lumaSpread.isFinite,
              meanLuma >= minimumMeanLuma,
              darkPixelFraction <= maxDarkPixelFraction else {
            return false
        }
        // Reject solid backdrop fills: bright and almost no tonal range.
        if meanLuma >= blankMeanLuma, lumaSpread < minimumLumaSpread {
            return false
        }
        return true
    }

    /// Samples packed RGB/RGBA bytes. `step` skips pixels for large thumbnails.
    static func sample(
        bytes: [UInt8],
        bytesPerPixel: Int,
        width: Int,
        height: Int,
        step: Int = 4
    ) -> (meanLuma: Double, darkPixelFraction: Double, lumaSpread: Double) {
        guard bytesPerPixel >= 3, width > 0, height > 0, step > 0 else {
            return (0, 1, 0)
        }
        let row = width * bytesPerPixel
        guard bytes.count >= row * height else {
            return (0, 1, 0)
        }
        var sum = 0.0
        var dark = 0
        var count = 0
        var minLuma = Double.greatestFiniteMagnitude
        var maxLuma = -Double.greatestFiniteMagnitude
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * row + x * bytesPerPixel
                let r = Double(bytes[offset]) / 255
                let g = Double(bytes[offset + 1]) / 255
                let b = Double(bytes[offset + 2]) / 255
                // Rec. 601 luma.
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                sum += luma
                minLuma = min(minLuma, luma)
                maxLuma = max(maxLuma, luma)
                if luma <= darkLumaCeiling { dark += 1 }
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return (0, 1, 0) }
        return (sum / Double(count), Double(dark) / Double(count), maxLuma - minLuma)
    }
}
