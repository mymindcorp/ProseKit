#if canImport(UIKit)
import UIKit
import ImageIO
import DocumentModel

/// The in-flight image loads, held apart from `DocumentImageStore` so that a
/// view's `deinit` — which is not main-actor isolated — can still cancel them.
///
/// A download or a disk read for a note the reader has already closed is work
/// nobody is waiting for, and on a slow connection it can outlive the view by a
/// long way.
final class ImageLoadTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks.isEmpty
    }

    func contains(_ src: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tasks[src] != nil
    }

    /// Run `work` as the load for `src`, replacing (and cancelling) any load
    /// already running for it.
    func start(_ src: String, _ work: @escaping @Sendable () async -> Void) {
        let task = Task { await work() }
        lock.lock()
        let previous = tasks.updateValue(task, forKey: src)
        lock.unlock()
        previous?.cancel()
    }

    func finish(_ src: String) {
        lock.lock()
        tasks[src] = nil
        lock.unlock()
    }

    /// Cancel the loads whose `src` matches.
    func cancel(_ matches: (String) -> Bool) {
        lock.lock()
        let doomed = tasks.filter { matches($0.key) }
        for key in doomed.keys { tasks[key] = nil }
        lock.unlock()
        doomed.values.forEach { $0.cancel() }
    }

    func cancelAll() {
        lock.lock()
        let all = tasks
        tasks.removeAll()
        lock.unlock()
        all.values.forEach { $0.cancel() }
    }
}

// MARK: - Downsampled decoding

/// Decode `data` to a bitmap no larger than the box the image will be drawn in.
///
/// The result reports the **natural** point size of the original in `size`, with
/// the reduction carried by `scale` — see `DocumentImageStore` for why that
/// matters. Anything ImageIO won't open (or won't describe) falls back to a
/// plain `UIImage(data:)`, which is what this code did for everything before.
func decodeDownsampledImage(_ data: Data, maxPointWidth: CGFloat, displayScale: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData,
                                                   [kCGImageSourceShouldCache: false] as CFDictionary) else {
        return UIImage(data: data)
    }
    return downsample(source, maxPointWidth: maxPointWidth, displayScale: displayScale) ?? UIImage(data: data)
}

/// `decodeDownsampledImage` on a background executor — the decode is the
/// expensive half, and it has no business happening in a frame.
func decodeOffMainActor(_ data: Data, maxPointWidth: CGFloat, displayScale: CGFloat) async -> UIImage? {
    decodeDownsampledImage(data, maxPointWidth: maxPointWidth, displayScale: displayScale)
}

/// Load an image from a data:, file:, or http(s) URL, downsampled to the box it
/// will be drawn in. Nonisolated, so both the read and the decode run off the
/// main actor.
func loadDownsampledImage(from url: URL, maxPointWidth: CGFloat, displayScale: CGFloat) async -> UIImage? {
    if url.scheme == "data" {
        guard let data = dataURLPayload(url) else { return nil }
        return decodeDownsampledImage(data, maxPointWidth: maxPointWidth, displayScale: displayScale)
    }
    if url.isFileURL {
        // Read through ImageIO rather than loading the file into a `Data` first:
        // only the thumbnail is ever materialized, so a 20 MB photo costs its
        // header plus a few hundred KB of pixels.
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = downsample(source, maxPointWidth: maxPointWidth, displayScale: displayScale) {
            return image
        }
        return (try? Data(contentsOf: url)).flatMap(UIImage.init(data:))
    }
    do {
        let (data, _) = try await URLSession.shared.data(from: url)
        return decodeDownsampledImage(data, maxPointWidth: maxPointWidth, displayScale: displayScale)
    } catch {
        return nil
    }
}

/// The bytes behind a `data:` URL (base64 or percent-encoded).
private func dataURLPayload(_ url: URL) -> Data? {
    let string = url.absoluteString
    guard let comma = string.firstIndex(of: ",") else { return nil }
    let meta = string[..<comma]
    let payload = String(string[string.index(after: comma)...])
    if meta.contains("base64") { return Data(base64Encoded: payload) }
    return payload.removingPercentEncoding.map { Data($0.utf8) }
}

/// Decode one image from `source` at no more than the pixels it will be drawn
/// with. Nil when the source won't describe itself (the caller then falls back).
private func downsample(_ source: CGImageSource, maxPointWidth: CGFloat, displayScale: CGFloat) -> UIImage? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          pixelWidth > 0, pixelHeight > 0 else { return nil }
    // EXIF orientations 5...8 transpose the image, and the thumbnail below is
    // produced with the transform already applied — so the size a caller sees
    // (and lays out from) is the transposed one.
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let natural = orientation >= 5
        ? CGSize(width: pixelHeight, height: pixelWidth)
        : CGSize(width: pixelWidth, height: pixelHeight)

    let scale = displayScale > 0 ? displayScale : 2
    // Layout caps an image to the content column, so this is the widest it can
    // ever be drawn; the height follows from the aspect ratio, and it is the
    // longer of the two that `kCGImageSourceThumbnailMaxPixelSize` bounds.
    let fitWidth = maxPointWidth > 0 ? min(natural.width, maxPointWidth) : natural.width
    let fitHeight = fitWidth * natural.height / natural.width
    // Never ask for more than the source has: past its own resolution there is
    // nothing to gain and a full-size copy to pay for.
    let longestSide = min((max(fitWidth, fitHeight) * scale).rounded(.up),
                          max(natural.width, natural.height))
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        // Decode now, on whatever thread this is. Without it the bitmap is
        // decoded lazily inside the first `draw(in:)` — on the main thread,
        // mid-scroll, which is the stall this whole path exists to avoid.
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(max(longestSide, 1)),
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    // Keep the original's point size: layout measures the image's box from it,
    // so the bitmap may shrink but the picture may not. Taken from the longer
    // side, which carries the most pixels and so the least rounding — the
    // thumbnail's dimensions are whole numbers, and the shorter side's are the
    // ones a half-pixel of that is worth more of.
    let pointScale = natural.width >= natural.height
        ? CGFloat(cgImage.width) / natural.width
        : CGFloat(cgImage.height) / natural.height
    return UIImage(cgImage: cgImage, scale: pointScale > 0 ? pointScale : 1, orientation: .up)
}
#endif
