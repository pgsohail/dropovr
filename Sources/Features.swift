// Extra powers: image tools, share links, screenshot capture and pinned shelves.

import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Image tools

enum ImageTools {
    enum Failure: LocalizedError {
        case unreadable, unwritable, noSubject, unsupported
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read the image"
            case .unwritable: return "Couldn't save the image"
            case .noSubject: return "No subject found"
            case .unsupported: return "Needs macOS 14 or later"
            }
        }
    }

    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    private static let outputDir: URL = {
        let dir = stashDir.appendingPathComponent("Edited", isDirectory: true)
        try? disk.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Loads the image upright, optionally scaled so its longest side is at most `maxSide` pixels.
    private static func load(_ url: URL, maxSide: CGFloat? = nil) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw Failure.unreadable }
        let width = props[kCGImagePropertyPixelWidth] as? CGFloat ?? 4096
        let height = props[kCGImagePropertyPixelHeight] as? CGFloat ?? 4096
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(min(maxSide ?? .infinity, max(width, height))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
        return image
    }

    private static func write(_ image: CGImage, as type: UTType, named name: String, quality: Double = 0.88) throws -> URL {
        let ext = type.preferredFilenameExtension ?? "png"
        let dest = uniqueURL(in: outputDir, filename: "\(name).\(ext)")
        guard let target = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else { throw Failure.unwritable }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw Failure.unwritable }
        return dest
    }

    private static func base(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    private static func originalType(_ url: URL) -> UTType {
        let type = UTType(filenameExtension: url.pathExtension) ?? .png
        return [UTType.jpeg, .png, .heic, .tiff].contains(type) ? type : .png
    }

    static func resize(_ url: URL, percent: CGFloat) throws -> URL {
        let full = try load(url)
        let side = CGFloat(max(full.width, full.height)) * percent / 100
        return try write(try load(url, maxSide: side), as: originalType(url), named: "\(base(url)) \(Int(percent))%")
    }

    static func resize(_ url: URL, maxSide: CGFloat) throws -> URL {
        try write(try load(url, maxSide: maxSide), as: originalType(url), named: "\(base(url)) \(Int(maxSide))px")
    }

    static func convert(_ url: URL, to type: UTType, quality: Double = 0.88) throws -> URL {
        try write(try load(url), as: type, named: base(url), quality: quality)
    }

    static func compress(_ url: URL) throws -> URL {
        try write(try load(url), as: .jpeg, named: "\(base(url)) compressed", quality: 0.6)
    }

    /// Cuts out the subject (people, pets, objects) onto a transparent background.
    static func removeBackground(_ url: URL) throws -> URL {
        guard #available(macOS 14.0, *) else { throw Failure.unsupported }
        let image = try load(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw Failure.noSubject }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cut = CIContext().createCGImage(ci, from: ci.extent) else { throw Failure.unwritable }
        return try write(cut, as: .png, named: "\(base(url)) cutout")
    }
}

// MARK: - Share links

/// Uploads to a free temporary file host and returns a download link anyone can open.
/// Litterbox first (ad-free, links last 1 day, up to 1 GB); tmpfiles.org as a backup (1 hour, up to 100 MB).
enum ShareLink {
    struct Shared {
        let link: URL
        let lifetime: String
    }

    enum Failure: LocalizedError {
        case tooBig, badResponse
        var errorDescription: String? {
            self == .tooBig ? "Files over 1 GB can't be shared" : "Upload failed — try again"
        }
    }

    private struct Host {
        let endpoint: URL
        let fileField: String
        let extraFields: [(String, String)]
        let maxBytes: Int64
        let lifetime: String
        let parse: (Data) -> URL?
    }

    private static let hosts: [Host] = [
        Host(endpoint: URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!, fileField: "fileToUpload",
             extraFields: [("reqtype", "fileupload"), ("time", "24h")], maxBytes: 1_000_000_000, lifetime: "1 day") { data in
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.hasPrefix("https://") ? URL(string: text) : nil
        },
        Host(endpoint: URL(string: "https://tmpfiles.org/api/v1/upload")!, fileField: "file", extraFields: [],
             maxBytes: 100_000_000, lifetime: "1 hour") { data in
            // {"status":"success","data":{"url":"https://tmpfiles.org/abc/name.png"}} → direct /dl/ link
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let page = (json["data"] as? [String: Any])?["url"] as? String else { return nil }
            return URL(string: page.replacingOccurrences(of: "tmpfiles.org/", with: "tmpfiles.org/dl/"))
        },
    ]

    /// Uploads one file, or a ZIP of several, and returns the public link.
    static func upload(_ items: [URL], completion: @escaping (Result<Shared, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let file = try single(items)
                let size = fileSize(file) ?? 0
                let usable = hosts.filter { size <= $0.maxBytes }
                if usable.isEmpty { throw Failure.tooBig }
                attempt(file, on: usable[...], completion: completion)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func attempt(_ file: URL, on remaining: ArraySlice<Host>, completion: @escaping (Result<Shared, Error>) -> Void) {
        guard let host = remaining.first else {
            DispatchQueue.main.async { completion(.failure(Failure.badResponse)) }
            return
        }
        do {
            let boundary = "dropovr-\(UUID().uuidString)"
            let body = try multipartBody(file: file, host: host, boundary: boundary)
            var request = URLRequest(url: host.endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            URLSession.shared.uploadTask(with: request, fromFile: body) { data, response, _ in
                try? disk.removeItem(at: body)
                if (response as? HTTPURLResponse)?.statusCode == 200, let data, let link = host.parse(data) {
                    DispatchQueue.main.async { completion(.success(Shared(link: link, lifetime: host.lifetime))) }
                } else {
                    attempt(file, on: remaining.dropFirst(), completion: completion)
                }
            }.resume()
        } catch {
            attempt(file, on: remaining.dropFirst(), completion: completion)
        }
    }

    /// A single file to upload: the file itself, or a ZIP for folders and multiple items.
    private static func single(_ items: [URL]) throws -> URL {
        if items.count == 1, !isFolder(items[0]) { return items[0] }
        let holder = stashDir.appendingPathComponent(".share-\(UUID().uuidString)", isDirectory: true)
        let name = items.count == 1 ? items[0].lastPathComponent : "Dropovr Files"
        let folder = holder.appendingPathComponent(name, isDirectory: true)
        try disk.createDirectory(at: folder, withIntermediateDirectories: true)
        let source: URL
        if items.count == 1 {
            source = items[0]
        } else {
            for url in items { try? disk.copyItem(at: url, to: uniqueURL(in: folder, filename: url.lastPathComponent)) }
            source = folder
        }
        let zip = uniqueURL(in: stashDir, filename: "\(name).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, zip.path]
        try process.run()
        process.waitUntilExit()
        try? disk.removeItem(at: holder)
        guard process.terminationStatus == 0 else { throw Failure.badResponse }
        return zip
    }

    /// The name the host sees. Some hosts refuse very short names, so those get a prefix.
    private static func uploadName(_ file: URL) -> String {
        let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        return file.deletingPathExtension().lastPathComponent.count < 4 ? "Dropovr-\(name)" : name
    }

    /// Writes the form to a temporary file, streaming the upload so big files don't fill memory.
    private static func multipartBody(file: URL, host: Host, boundary: String) throws -> URL {
        let body = stashDir.appendingPathComponent(".upload-\(UUID().uuidString)")
        disk.createFile(atPath: body.path, contents: nil)
        let out = try FileHandle(forWritingTo: body)
        defer { try? out.close() }
        for (name, value) in host.extraFields {
            out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(host.fileField)\"; filename=\"\(uploadName(file))\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

// MARK: - Screenshots

/// Notices new screenshots and screen recordings as macOS saves them.
final class ScreenshotWatcher {
    var onNew: ((URL) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var folder: URL?
    private var pending: DispatchWorkItem?

    static var screenshotFolder: URL {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let custom, !custom.isEmpty {
            let url = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
            if isFolder(url) { return url }
        }
        return disk.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        let folder = Self.screenshotFolder
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        self.folder = folder
        known = Set((try? disk.contentsOfDirectory(atPath: folder.path)) ?? [])
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleScan() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func scheduleScan() {
        // macOS writes a hidden temp file first and renames it; give it a moment.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func scan() {
        guard let folder else { return }
        let names = Set((try? disk.contentsOfDirectory(atPath: folder.path)) ?? [])
        let fresh = names.subtracting(known)
        known = names
        for name in fresh.sorted() where !name.hasPrefix(".") {
            let url = folder.appendingPathComponent(name)
            if Self.isScreenCapture(url) { onNew?(url) }
        }
    }

    static func isScreenCapture(_ url: URL) -> Bool {
        // macOS tags screenshots with this attribute; fall back to the usual names.
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let name = url.lastPathComponent.lowercased()
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        guard Date().timeIntervalSince(created) < 30 else { return false }
        return ["screenshot", "screen shot", "screen recording", "bildschirmfoto", "capture d", "captura de pantalla", "schermafbeelding"]
            .contains { name.hasPrefix($0) }
    }
}

// MARK: - Pinned shelves

struct SavedShelf: Codable {
    var paths: [String]
    var x: Double
    var y: Double
}

enum ShelfStore {
    private static let key = "pinnedShelves"

    static func save(_ shelves: [ShelfPanel]) {
        let saved = shelves.filter(\.pinned).map {
            SavedShelf(paths: $0.urls.map(\.path), x: $0.frame.origin.x, y: $0.frame.origin.y)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: key)
    }

    static func load() -> [SavedShelf] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedShelf].self, from: data)) ?? []
    }
}
