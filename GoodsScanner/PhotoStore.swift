import UIKit
import ImageIO

/// A5: JPEGs in Application Support/Photos/<uuid>.jpg; models store only the file name.
enum PhotoStore {
    static let directory: URL = {
        let dir = URL.applicationSupportDirectory.appending(path: "Photos", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(_ name: String) -> URL { directory.appending(path: name) }

    static func save(_ image: UIImage) -> String? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let name = UUID().uuidString + ".jpg"
        do { try data.write(to: url(name), options: .atomic) } catch { return nil }
        return name
    }

    static func image(_ name: String) -> UIImage? { UIImage(contentsOfFile: url(name).path) }

    /// Downsampled decode via ImageIO (never decodes the full JPEG). `side` = max pixel size.
    static func thumbnail(_ name: String, side: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url(name) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func delete(_ names: [String]) {
        for n in names { try? FileManager.default.removeItem(at: url(n)) }
    }
}
