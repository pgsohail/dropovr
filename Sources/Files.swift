// Where Dropovr keeps things that don't already exist as files, how it reads
// whatever is dragged onto a shelf, and how it makes previews.

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

let disk = FileManager.default

let stashDir: URL = {
    let dir = disk.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Dropovr", isDirectory: true)
    try? disk.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

/// A path in `dir` named `filename` that doesn't exist yet ("Photo 2.jpg" if "Photo.jpg" is taken).
func uniqueURL(in dir: URL, filename: String) -> URL {
    let base = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    var candidate = dir.appendingPathComponent(filename)
    var n = 2
    while disk.fileExists(atPath: candidate.path) {
        candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
        n += 1
    }
    return candidate
}

/// A new file for a dropped snippet, e.g. "Text 2026-10-19 at 18.40.12.txt".
func clippingURL(_ kind: String, ext: String) -> URL {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return uniqueURL(in: stashDir, filename: "\(kind) \(formatter.string(from: Date())).\(ext)")
}

func isFolder(_ url: URL) -> Bool {
    var dir: ObjCBool = false
    return disk.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
        && (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
}

func fileSize(_ url: URL) -> Int64? {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
    return Int64(size)
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func kindDescription(_ url: URL) -> String {
    if isFolder(url) { return "Folder" }
    let kind = UTType(filenameExtension: url.pathExtension)?.localizedDescription ?? "File"
    if let size = fileSize(url) { return "\(kind) · \(formatSize(size))" }
    return kind
}

// MARK: - Reading drops

enum PasteboardReader {
    static let types: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .png, .tiff, .pdf, .rtf, .html]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Turns whatever was dropped into files and hands them to `deliver` on the main thread.
    /// Returns false when there was nothing usable.
    static func read(_ pasteboard: NSPasteboard, deliver: @escaping ([URL]) -> Void) -> Bool {
        // Real files and folders.
        if let files = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            deliver(files)
            return true
        }
        // Files that only exist once dropped: Photos, Mail attachments, Safari images, Messages…
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            let dest = stashDir.appendingPathComponent("Dropped \(UUID().uuidString.prefix(6))", isDirectory: true)
            try? disk.createDirectory(at: dest, withIntermediateDirectories: true)
            for promise in promises {
                promise.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: promiseQueue) { url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { deliver([url]) }
                }
            }
            return true
        }
        if let pdf = pasteboard.data(forType: .pdf) {
            let dest = clippingURL("Document", ext: "pdf")
            if (try? pdf.write(to: dest)) != nil { deliver([dest]); return true }
        }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let dest = clippingURL("Image", ext: "png")
            if (try? png.write(to: dest)) != nil { deliver([dest]); return true }
        }
        if let link = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first,
           let scheme = link.scheme, ["http", "https"].contains(scheme),
           let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": link.absoluteString],
                                                          format: .xml, options: 0) {
            let dest = clippingURL(link.host ?? "Link", ext: "webloc")
            if (try? data.write(to: dest)) != nil { deliver([dest]); return true }
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let dest = clippingURL("Text", ext: "txt")
            if (try? text.write(to: dest, atomically: true, encoding: .utf8)) != nil { deliver([dest]); return true }
        }
        if let rtf = pasteboard.data(forType: .rtf) {
            let dest = clippingURL("Text", ext: "rtf")
            if (try? rtf.write(to: dest)) != nil { deliver([dest]); return true }
        }
        return false
    }
}

// MARK: - Previews

struct Thumb {
    let image: NSImage
    /// True for a real preview (photo, PDF page, video frame); false for a plain file icon.
    let isPreview: Bool
}

/// Makes Quick Look previews for anything macOS can preview, with the file icon as a stand-in.
final class Thumbnails {
    static let shared = Thumbnails()
    private var cache: [URL: Thumb] = [:]
    private var waiting: [URL: [(Thumb) -> Void]] = [:]

    func cached(_ url: URL) -> Thumb? { cache[url] }

    func best(_ url: URL) -> NSImage { cache[url]?.image ?? NSWorkspace.shared.icon(forFile: url.path) }

    /// Calls `completion` right away with what's known, then again once a real preview is ready.
    func load(_ url: URL, completion: @escaping (Thumb) -> Void) {
        if let thumb = cache[url] { completion(thumb); return }
        completion(Thumb(image: NSWorkspace.shared.icon(forFile: url.path), isPreview: false))
        if waiting[url] != nil { waiting[url]?.append(completion); return }
        waiting[url] = [completion]

        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 240, height: 240),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let callbacks = self.waiting.removeValue(forKey: url) ?? []
                let thumb = rep.map { Thumb(image: $0.nsImage, isPreview: true) }
                    ?? Thumb(image: NSWorkspace.shared.icon(forFile: url.path), isPreview: false)
                self.cache[url] = thumb
                if thumb.isPreview { callbacks.forEach { $0(thumb) } }
            }
        }
    }

    func forget(_ url: URL) { cache[url] = nil }
}

extension CALayer {
    func setImage(_ image: NSImage) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        contentsScale = image.recommendedLayerContentsScale(scale)
        contents = image.layerContents(forContentsScale: contentsScale)
    }
}

func aspectFit(_ size: CGSize, in box: CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return box }
    let scale = min(box.width / size.width, box.height / size.height)
    let w = size.width * scale, h = size.height * scale
    return CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h)
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor? = nil) -> NSImage? {
    var config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    if let color { config = config.applying(.init(paletteColors: [color])) }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
}
