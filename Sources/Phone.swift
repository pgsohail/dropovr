// Send to Phone: a tiny private web server on your Wi‑Fi. Scan the QR code with any
// phone (iPhone or Android) to download what's on the shelf or send files back to the Mac.

import AppKit
import CoreImage.CIFilterBuiltins
import Network
import UniformTypeIdentifiers

final class PhoneServer {
    static let shared = PhoneServer()

    /// The shelf the phone sees. Switching shelves (or stopping) tells the old one it's done.
    weak var shelf: ShelfPanel? {
        didSet { if oldValue !== shelf { oldValue?.phoneSharingEnded() } }
    }
    private(set) var link: URL?
    private var listener: NWListener?
    private var token = ""
    private let queue = DispatchQueue(label: "stash.phone", qos: .userInitiated, attributes: .concurrent)

    func start(_ done: @escaping (URL?) -> Void) {
        if let link { done(link); return }
        guard let ip = Self.localIPv4(), let listener = try? NWListener(using: .tcp) else { done(nil); return }
        let token = (0..<4).map { _ in String(format: "%04x", UInt16.random(in: .min ... .max)) }.joined()
        self.token = token
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                let port = listener?.port?.rawValue ?? 0
                DispatchQueue.main.async {
                    guard let self, self.listener === listener else { return }
                    self.link = URL(string: "http://\(ip):\(port)/\(token)/")
                    done(self.link)
                }
            case .failed:
                DispatchQueue.main.async { self?.stop(); done(nil) }
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        link = nil
        shelf = nil
    }

    // MARK: Requests

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isDone, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let body = Data(buffer[end.upperBound...])
                self.route(connection, head: head, body: body)
            } else if error != nil || isDone || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readHead(connection, buffer: buffer)
            }
        }
    }

    private func route(_ connection: NWConnection, head: String, body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { return respond(connection, "400 Bad Request", text: "Bad request") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let prefix = "/\(token)"
        guard parts[1].hasPrefix(prefix), let comps = URLComponents(string: "http://stash" + parts[1].dropFirst(prefix.count)) else {
            return respond(connection, "404 Not Found", text: "Not found")
        }
        var query: [String: String] = [:]
        comps.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        let request = Request(method: parts[0], path: comps.path, query: query, headers: headers)

        let segments = request.path.split(separator: "/").map(String.init)
        switch (request.method, segments.first ?? "") {
        case ("GET", "") where request.path.isEmpty:
            respond(connection, "301 Moved Permanently", text: "", extra: ["Location": prefix + "/"])
        case ("GET", ""):
            respond(connection, "200 OK", type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
        case ("GET", "items"):
            sendItems(connection)
        case ("GET", "f") where segments.count > 1:
            guard let url = item(segments[1]) else { return respond(connection, "404 Not Found", text: "Gone") }
            sendFile(connection, url)
        case ("GET", "t") where segments.count > 1:
            guard let url = item(segments[1]) else { return respond(connection, "404 Not Found", text: "Gone") }
            sendThumbnail(connection, url)
        case ("POST", "u"):
            receiveUpload(connection, request: request, start: body)
        default:
            respond(connection, "404 Not Found", text: "Not found")
        }
    }

    private func currentItems() -> [URL] {
        DispatchQueue.main.sync { shelf?.urls ?? [] }
    }

    private static func id(_ url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 36)
    }

    private func item(_ id: String) -> URL? {
        currentItems().first { Self.id($0) == id }
    }

    private func sendItems(_ connection: NWConnection) {
        let list: [[String: String]] = currentItems().reversed().map { url in
            let size = isFolder(url) ? "Folder · downloads as ZIP" : fileSize(url).map(formatSize) ?? ""
            return ["id": Self.id(url), "name": url.lastPathComponent, "size": size]
        }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        respond(connection, "200 OK", type: "application/json", body: data)
    }

    private func sendThumbnail(_ connection: NWConnection, _ url: URL) {
        let png: Data? = DispatchQueue.main.sync {
            let image = Thumbnails.shared.best(url)
            let side = 160
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: aspectFit(image.size, in: CGRect(x: 0, y: 0, width: side, height: side)))
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])
        }
        guard let png else { return respond(connection, "404 Not Found", text: "") }
        respond(connection, "200 OK", type: "image/png", body: png, extra: ["Cache-Control": "max-age=60"])
    }

    private func sendFile(_ connection: NWConnection, _ original: URL) {
        var url = original
        if isFolder(original) {
            // Folders go to the phone as a ZIP.
            let zip = stashDir.appendingPathComponent(".phone", isDirectory: true)
            try? disk.createDirectory(at: zip, withIntermediateDirectories: true)
            url = zip.appendingPathComponent("\(Self.id(original)) \(original.lastPathComponent).zip")
            if !disk.fileExists(atPath: url.path) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", original.path, url.path]
                guard (try? process.run()) != nil else { return respond(connection, "500 Internal Server Error", text: "") }
                process.waitUntilExit()
            }
        }
        guard let handle = try? FileHandle(forReadingFrom: url), let size = fileSize(url) else {
            return respond(connection, "404 Not Found", text: "Gone")
        }
        let name = isFolder(original) ? original.lastPathComponent + ".zip" : original.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(size)\r\n"
            + "Content-Disposition: attachment; filename*=UTF-8''\(encoded)\r\nConnection: close\r\n\r\n"

        func pump() {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? nil
            guard let chunk, !chunk.isEmpty else {
                try? handle.close()
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { error in
                if error != nil { try? handle.close(); connection.cancel() } else { pump() }
            })
        }
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error != nil { try? handle.close(); connection.cancel() } else { pump() }
        })
    }

    private func receiveUpload(_ connection: NWConnection, request: Request, start: Data) {
        guard let length = Int(request.headers["content-length"] ?? "") else {
            return respond(connection, "411 Length Required", text: "")
        }
        var name = (request.query["name"] ?? "").replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "From Phone" }
        let folder = stashDir.appendingPathComponent("From Phone", isDirectory: true)
        try? disk.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = uniqueURL(in: folder, filename: name)
        guard disk.createFile(atPath: dest.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dest) else {
            return respond(connection, "500 Internal Server Error", text: "")
        }
        var remaining = length
        let first = start.prefix(remaining)
        handle.write(first)
        remaining -= first.count

        func next() {
            if remaining <= 0 {
                try? handle.close()
                DispatchQueue.main.async { [weak self] in
                    guard let shelf = self?.shelf else { return }
                    shelf.add([dest])
                    shelf.shelfView.toast("Received from phone")
                }
                respond(connection, "200 OK", type: "application/json", body: Data("{\"ok\":true}".utf8))
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 1 << 20)) { data, _, isDone, error in
                if let data, !data.isEmpty {
                    handle.write(data)
                    remaining -= data.count
                }
                if error != nil || (isDone && remaining > 0) {
                    try? handle.close()
                    try? disk.removeItem(at: dest)
                    connection.cancel()
                    return
                }
                next()
            }
        }
        next()
    }

    private func respond(_ connection: NWConnection, _ status: String, type: String = "text/plain; charset=utf-8",
                         body: Data = Data(), text: String? = nil, extra: [String: String] = [:]) {
        let payload = text.map { Data($0.utf8) } ?? body
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n"
        if extra["Cache-Control"] == nil { head += "Cache-Control: no-store\r\n" }
        extra.forEach { head += "\($0.key): \($0.value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Network address & QR

    static func localIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var fallback: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: entry.ifa_name)
            if name == "en0" { return ip }
            if name.hasPrefix("en"), fallback == nil { fallback = ip }
        }
        return fallback
    }

    static func qrCode(_ text: String, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (side * 2 / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }

    // MARK: The phone page

    static let page = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <meta name="theme-color" content="#0c0b14"><title>Stash</title>
    <style>
    :root{color-scheme:dark}
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
    body{margin:0;min-height:100vh;font:16px -apple-system,BlinkMacSystemFont,system-ui,Roboto,sans-serif;color:#fff;
      background:radial-gradient(120% 55% at 50% -8%,#3a2b8f 0%,#14112a 45%,#0c0b14 75%);padding:env(safe-area-inset-top) 16px 140px}
    header{display:flex;align-items:center;gap:14px;padding:26px 4px 20px}
    .logo{width:46px;height:46px;border-radius:14px;flex:none;display:grid;place-items:center;
      background:linear-gradient(160deg,#5b8cff,#9150f5);box-shadow:0 10px 30px #6d5cff66,inset 0 1px 0 #ffffff55}
    h1{font-size:24px;margin:0;font-weight:700;letter-spacing:-.02em}
    .sub{color:#ffffff85;font-size:13.5px;margin-top:3px;display:flex;align-items:center;gap:6px}
    .dot{width:7px;height:7px;border-radius:50%;background:#3ddc84;box-shadow:0 0 8px #3ddc84}
    .dot.off{background:#ff5b5b;box-shadow:0 0 8px #ff5b5b}
    .list{display:flex;flex-direction:column;gap:10px}
    .item{display:flex;align-items:center;gap:13px;padding:11px;border-radius:18px;text-decoration:none;color:inherit;
      background:linear-gradient(180deg,#ffffff12,#ffffff08);border:1px solid #ffffff17;
      -webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px);animation:rise .4s cubic-bezier(.2,.9,.3,1) both;transition:transform .15s}
    .item:active{transform:scale(.98)}
    .item img{width:54px;height:54px;border-radius:12px;object-fit:contain;background:#ffffff0d;flex:none}
    .meta{flex:1;min-width:0}
    .name{font-weight:600;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .size{color:#ffffff75;font-size:12.5px;margin-top:4px}
    .get{flex:none;width:38px;height:38px;border-radius:50%;display:grid;place-items:center;background:#ffffff17}
    .empty{text-align:center;color:#ffffff80;padding:56px 24px;border:1.5px dashed #ffffff26;border-radius:22px;line-height:1.5}
    .empty b{display:block;color:#fff;font-size:17px;margin-bottom:6px}
    .bar{position:fixed;left:16px;right:16px;bottom:calc(18px + env(safe-area-inset-bottom))}
    .send{width:100%;border:0;border-radius:20px;padding:18px;font:600 17px -apple-system,system-ui,sans-serif;color:#fff;
      background:linear-gradient(160deg,#5b8cff,#9150f5);box-shadow:0 14px 34px #6d5cff70,inset 0 1px 0 #ffffff40;transition:transform .15s}
    .send:active{transform:scale(.97)}
    .send:disabled{opacity:.85}
    .prog{height:5px;border-radius:3px;background:#ffffff1c;overflow:hidden;margin:0 6px 12px;opacity:0;transition:opacity .2s}
    .prog i{display:block;height:100%;width:0;border-radius:3px;background:linear-gradient(90deg,#8fb0ff,#fff);transition:width .15s}
    @keyframes rise{from{opacity:0;transform:translateY(10px)}}
    </style></head><body>
    <header>
      <div class="logo"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v10m0 0 4-4m-4 4-4-4"/><path d="M3 14v3a3 3 0 0 0 3 3h12a3 3 0 0 0 3-3v-3h-5a4 4 0 0 1-8 0H3z"/></svg></div>
      <div><h1>Stash</h1><div class="sub"><span class="dot" id="dot"></span><span id="sub">Connected to your Mac</span></div></div>
    </header>
    <div class="list" id="list"></div>
    <div class="bar"><div class="prog" id="prog"><i id="fill"></i></div>
      <button class="send" id="send">Send to Mac</button><input type="file" id="file" multiple hidden></div>
    <script>
    const $=id=>document.getElementById(id);let last='';
    const esc=s=>s.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const arrow='<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v12m0 0 5-5m-5 5-5-5M5 20h14"/></svg>';
    async function load(){
      try{
        const items=await (await fetch('items',{cache:'no-store'})).json();
        $('dot').className='dot';
        $('sub').textContent=items.length?items.length+(items.length==1?' item':' items')+' on your Mac':'Connected to your Mac';
        const sig=JSON.stringify(items); if(sig===last) return; last=sig;
        $('list').innerHTML=items.length?items.map((it,i)=>`<a class="item" style="animation-delay:${i*35}ms" href="f/${it.id}" download="${esc(it.name)}"><img src="t/${it.id}" alt=""><div class="meta"><div class="name">${esc(it.name)}</div><div class="size">${esc(it.size)}</div></div><div class="get">${arrow}</div></a>`).join('')
          :'<div class="empty"><b>Nothing here yet</b>Drop files on the Stash shelf on your Mac and they’ll appear here — or send some from this phone.</div>';
      }catch(e){$('dot').className='dot off';$('sub').textContent='Can’t reach your Mac…'}
    }
    load();setInterval(load,1500);
    $('send').onclick=()=>$('file').click();
    $('file').onchange=async()=>{
      const files=[...$('file').files]; if(!files.length) return;
      const total=files.reduce((a,f)=>a+f.size,0)||1; let done=0;
      $('prog').style.opacity=1; $('send').disabled=true;
      try{
        for(const [n,f] of files.entries()){
          $('send').textContent=files.length>1?`Sending ${n+1} of ${files.length}…`:'Sending…';
          await new Promise((ok,fail)=>{const x=new XMLHttpRequest();x.open('POST','u?name='+encodeURIComponent(f.name));
            x.upload.onprogress=e=>$('fill').style.width=((done+e.loaded)/total*100)+'%';
            x.onload=()=>x.status==200?ok():fail();x.onerror=fail;x.send(f)});
          done+=f.size;
        }
        $('fill').style.width='100%'; $('send').textContent='Sent to your Mac ✓';
      }catch(e){$('send').textContent='Couldn’t send — try again'}
      setTimeout(()=>{$('send').textContent='Send to Mac';$('send').disabled=false;$('prog').style.opacity=0;$('fill').style.width=0},1800);
      $('file').value=''; load();
    };
    </script></body></html>
    """#
}

// MARK: - The QR overlay on the shelf

final class PhoneOverlay: NSView {
    var onHide: (() -> Void)?
    var onStop: (() -> Void)?

    private let card = NSView()
    private let qr = NSImageView()
    private let spinner = NSProgressIndicator()
    private let title = label("Scan with your phone", size: 14, weight: .semibold)
    private let subtitle = label("Same Wi‑Fi · iPhone or Android · both ways", size: 11, color: Style.secondary)
    private let link = label(size: 10, color: NSColor(white: 1, alpha: 0.35))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let side: CGFloat = 156
        card.frame = NSRect(x: (frame.width - side) / 2, y: frame.height - side - 4, width: side, height: side)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 18
        card.layer?.shadowColor = Style.accent.cgColor
        card.layer?.shadowOpacity = 0.45
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = .zero
        addSubview(card)
        qr.frame = card.bounds.insetBy(dx: 12, dy: 12)
        qr.imageScaling = .scaleProportionallyUpOrDown
        card.addSubview(qr)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: side / 2 - 8, y: side / 2 - 8, width: 16, height: 16)
        card.addSubview(spinner)

        title.frame = NSRect(x: 0, y: card.frame.minY - 26, width: frame.width, height: 18)
        subtitle.frame = NSRect(x: 0, y: card.frame.minY - 44, width: frame.width, height: 15)
        link.frame = NSRect(x: 0, y: card.frame.minY - 60, width: frame.width, height: 13)
        link.isSelectable = true
        addSubview(title)
        addSubview(subtitle)
        addSubview(link)

        let hide = PillButton("Done", target: self, action: #selector(hideTapped))
        let stop = PillButton("Stop Sharing", target: self, action: #selector(stopTapped))
        hide.frame = NSRect(x: frame.width / 2 - 112, y: 4, width: 104, height: 28)
        stop.frame = NSRect(x: frame.width / 2 + 8, y: 4, width: 104, height: 28)
        addSubview(hide)
        addSubview(stop)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    func showLoading() {
        qr.image = nil
        spinner.isHidden = false
        spinner.startAnimation(nil)
        title.stringValue = "Getting ready…"
        link.stringValue = ""
    }

    func show(_ url: URL) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        qr.image = PhoneServer.qrCode(url.absoluteString, side: qr.bounds.width)
        title.stringValue = "Scan with your phone"
        subtitle.stringValue = "Same Wi‑Fi · iPhone or Android · both ways"
        link.stringValue = url.absoluteString
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.85
        pop.toValue = 1
        pop.damping = 14
        pop.stiffness = 240
        pop.duration = pop.settlingDuration
        qr.layer?.add(pop, forKey: "pop")
    }

    func showError(_ message: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        qr.image = symbol("wifi.exclamationmark", size: 44, weight: .medium, color: .black)
        title.stringValue = "No Wi‑Fi connection"
        subtitle.stringValue = message
        link.stringValue = ""
    }

    @objc private func hideTapped() { onHide?() }
    @objc private func stopTapped() { onStop?() }
}
