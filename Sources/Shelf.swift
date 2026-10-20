// A shelf: the floating glass window, what's on it, and everything you can do with it.

import AppKit
import Quartz

final class ShelfPanel: NSPanel, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let size = NSSize(width: 300, height: 340)

    private(set) var urls: [URL] = []
    private(set) var selection: Set<URL> = []
    private(set) var expanded = false
    private(set) var shelfView: ShelfView!
    var onClose: ((ShelfPanel) -> Void)?
    private var closing = false
    private var previewURLs: [URL] = []

    init(near point: NSPoint) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        shelfView = ShelfView(frame: NSRect(origin: .zero, size: Self.size), shelf: self)
        contentView = shelfView
        setFrameOrigin(Self.origin(near: point))
    }

    override var canBecomeKey: Bool { true }

    static func origin(near point: NSPoint) -> NSPoint {
        let size = Self.size
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 10), visible.maxX - size.width - 10)
            origin.y = min(max(origin.y, visible.minY + 10), visible.maxY - size.height - 10)
        }
        return origin
    }

    /// Glides the shelf in next to `point` (or over to it, if it's already showing).
    func present(near point: NSPoint) {
        let target = NSRect(origin: Self.origin(near: point), size: Self.size)
        if isVisible && !closing {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = Style.smooth
                animator().setFrame(target, display: true)
            }
            return
        }
        closing = false
        alphaValue = 0
        setFrame(target.offsetBy(dx: 0, dy: -10), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = Style.smooth
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    override func close() {
        guard !closing else { return }
        closing = true
        if PhoneServer.shared.shelf === self { PhoneServer.shared.stop() }
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = 0
            animator().setFrame(frame.offsetBy(dx: 0, dy: -10), display: true)
        }, completionHandler: { [weak self] in
            guard let self, self.closing else { return }
            self.orderOut(nil)
            self.onClose?(self)
        })
    }

    // MARK: Contents

    func add(_ new: [URL]) {
        let fresh = new.map(\.standardizedFileURL).filter { !urls.contains($0) }
        guard !fresh.isEmpty else { return }
        urls += fresh
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        changed()
    }

    func remove(_ gone: [URL]) {
        let set = Set(gone)
        urls.removeAll { set.contains($0) }
        selection.subtract(set)
        set.forEach { Thumbnails.shared.forget($0) }
        if urls.isEmpty { close() } else { changed() }
    }

    private func changed() {
        if urls.count < 2 { expanded = false }
        shelfView.reload(animated: true)
    }

    func setExpanded(_ value: Bool) {
        expanded = value && urls.count > 1
        if !expanded { selection.removeAll() }
        shelfView.reload(animated: true)
    }

    func click(_ url: URL, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else if modifiers.contains(.shift) {
            selection.insert(url)
        } else {
            selection = [url]
        }
        shelfView.selectionChanged()
    }

    func clearSelection() {
        selection.removeAll()
        shelfView.selectionChanged()
    }

    /// The selected items, or everything when nothing is selected.
    var activeURLs: [URL] {
        let picked = urls.filter { selection.contains($0) }
        return picked.isEmpty ? urls : picked
    }

    // MARK: Actions

    @objc func closeShelf() { close() }

    @objc func toggleExpanded() { setExpanded(!expanded) }

    @objc func togglePhone() { shelfView.setPhoneVisible(!shelfView.phoneVisible) }

    func phoneSharingEnded() { shelfView.phoneEnded() }

    @objc func share(_ sender: NSButton) {
        guard !urls.isEmpty else { return }
        NSSharingServicePicker(items: activeURLs).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc func airDrop() {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: activeURLs) else {
            shelfView.toast("AirDrop isn't available")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: activeURLs)
    }

    @objc func showQuickLook() {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil); return }
        previewURLs = activeURLs
        NSApp.activate(ignoringOtherApps: true)
        makeKey()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    @objc func copyItems() {
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(activeURLs as [NSURL])
        shelfView.toast(activeURLs.count == 1 ? "Copied" : "Copied \(activeURLs.count) items")
    }

    @objc func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(activeURLs)
    }

    @objc func saveToDownloads() {
        let items = activeURLs
        guard !items.isEmpty else { return }
        let downloads = disk.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let saved = items.filter { url in
                (try? disk.copyItem(at: url, to: uniqueURL(in: downloads, filename: url.lastPathComponent))) != nil
            }.count
            DispatchQueue.main.async { [weak self] in
                self?.shelfView.toast(saved == items.count ? "Saved to Downloads" : "Saved \(saved) of \(items.count)")
            }
        }
    }

    @objc func compress() {
        let items = activeURLs
        guard !items.isEmpty else { return }
        shelfView.toast("Compressing…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let name = items.count == 1 ? items[0].deletingPathExtension().lastPathComponent : "Archive"
            let output = uniqueURL(in: stashDir, filename: name + ".zip")
            var source = items[0]
            var temp: URL?
            if items.count > 1 {
                let holder = stashDir.appendingPathComponent(".zip-\(UUID().uuidString)", isDirectory: true)
                let folder = holder.appendingPathComponent("Archive", isDirectory: true)
                try? disk.createDirectory(at: folder, withIntermediateDirectories: true)
                for url in items {
                    try? disk.copyItem(at: url, to: uniqueURL(in: folder, filename: url.lastPathComponent))
                }
                source = folder
                temp = holder
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, output.path]
            var ok = false
            if (try? process.run()) != nil {
                process.waitUntilExit()
                ok = process.terminationStatus == 0
            }
            if let temp { try? disk.removeItem(at: temp) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if ok { self.add([output]); self.shelfView.toast("Zipped") } else { self.shelfView.toast("Couldn't compress") }
            }
        }
    }

    @objc func removeSelected() {
        guard !selection.isEmpty else { return }
        let gone = urls.filter { selection.contains($0) }
        selection.removeAll()
        urls.removeAll { gone.contains($0) }
        changed()
    }

    @objc func clearAll() {
        urls.removeAll()
        selection.removeAll()
        changed()
    }

    @objc func selectAll() {
        guard urls.count > 1 else { return }
        expanded = true
        selection = Set(urls)
        shelfView.reload(animated: true)
    }

    @objc func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let has = !urls.isEmpty
        func add(_ title: String, _ icon: String, _ action: Selector, key: String = "", enabled: Bool = true) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            item.image = symbol(icon, size: 13, weight: .regular)
            item.isEnabled = enabled
        }
        let scope = selection.isEmpty ? "" : " Selected"
        add("Quick Look", "eye", #selector(showQuickLook), key: " ", enabled: has)
        add("Copy\(scope)", "doc.on.doc", #selector(copyItems), key: "c", enabled: has)
        add("AirDrop…", "dot.radiowaves.left.and.right", #selector(airDrop), enabled: has)
        add("Send to Phone…", "iphone", #selector(togglePhone))
        menu.addItem(.separator())
        add("Compress to ZIP", "doc.zipper", #selector(compress), enabled: has)
        add("Save to Downloads", "arrow.down.circle", #selector(saveToDownloads), enabled: has)
        add("Show in Finder", "folder", #selector(revealInFinder), enabled: has)
        menu.addItem(.separator())
        if !selection.isEmpty { add("Remove Selected", "minus.circle", #selector(removeSelected)) }
        add("Clear Shelf", "trash", #selector(clearAll), enabled: has)
        add("Close Shelf", "xmark", #selector(closeShelf), key: "w")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch (event.keyCode, command) {
        case (49, false): showQuickLook()                       // space
        case (51, _), (117, _): removeSelected()            // delete
        case (0, true): selectAll()                         // ⌘A
        case (8, true): copyItems()                         // ⌘C
        case (13, true): close()                            // ⌘W
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if shelfView.phoneVisible { shelfView.setPhoneVisible(false) }
        else if expanded { setExpanded(false) }
        else { close() }
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }
}

// MARK: - The glass

final class ShelfView: NSVisualEffectView {
    weak var shelf: ShelfPanel?

    private var modeButton: HeaderButton!
    private var phoneButton: HeaderButton!
    private var shareButton: HeaderButton!
    private let titleLabel = label(size: 13, weight: .semibold, align: .left)
    private let body: NSView
    private let empty: EmptyDropView
    private let stack: StackView
    private let grid: GridView
    private var phone: PhoneOverlay?
    private let glow = PassthroughView()
    private let toastView = ToastView()
    private(set) var phoneVisible = false

    init(frame: NSRect, shelf: ShelfPanel) {
        self.shelf = shelf
        let bodyFrame = NSRect(x: 12, y: 12, width: frame.width - 24, height: frame.height - 58)
        body = NSView(frame: bodyFrame)
        let inner = NSRect(origin: .zero, size: bodyFrame.size)
        empty = EmptyDropView(frame: inner)
        stack = StackView(frame: inner)
        grid = GridView(frame: inner)
        super.init(frame: frame)

        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        maskImage = Self.roundedMask(Style.radius)

        // A soft light sheen across the top, and a hairline edge.
        // A deep tint over the blur so the shelf stays dark and legible on bright wallpapers.
        let tint = PassthroughView(frame: bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedRed: 0.045, green: 0.045, blue: 0.06, alpha: 0.86).cgColor
        addSubview(tint)

        let sheen = PassthroughView(frame: bounds)
        sheen.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = bounds
        gradient.colors = [NSColor(white: 1, alpha: 0.06).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0.55)
        sheen.layer?.addSublayer(gradient)
        addSubview(sheen)

        let close = HeaderButton(symbol: "xmark", tip: "Close (Esc)", target: shelf, action: #selector(ShelfPanel.closeShelf))
        close.frame.origin = NSPoint(x: 10, y: frame.height - 38)
        addSubview(close)

        titleLabel.frame = NSRect(x: 42, y: frame.height - 32, width: 120, height: 18)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        let more = HeaderButton(symbol: "ellipsis", tip: "More", target: shelf, action: #selector(ShelfPanel.showMore(_:)))
        shareButton = HeaderButton(symbol: "square.and.arrow.up", tip: "Share", target: shelf, action: #selector(ShelfPanel.share(_:)))
        phoneButton = HeaderButton(symbol: "iphone", tip: "Send to Phone", target: shelf, action: #selector(ShelfPanel.togglePhone))
        modeButton = HeaderButton(symbol: "square.grid.2x2", tip: "Browse", target: shelf, action: #selector(ShelfPanel.toggleExpanded))
        for (index, button) in [more, shareButton!, phoneButton!, modeButton!].enumerated() {
            button.frame.origin = NSPoint(x: frame.width - 38 - CGFloat(index) * 30, y: frame.height - 38)
            addSubview(button)
        }

        let divider = PassthroughView(frame: NSRect(x: 14, y: frame.height - 46, width: frame.width - 28, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        addSubview(divider)

        stack.shelf = shelf
        grid.shelf = shelf
        for view in [empty, stack, grid] as [NSView] { body.addSubview(view) }
        addSubview(body)

        let edge = PassthroughView(frame: bounds)
        edge.wantsLayer = true
        edge.layer?.cornerRadius = Style.radius
        edge.layer?.borderWidth = 1
        edge.layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        addSubview(edge)

        glow.frame = bounds
        glow.wantsLayer = true
        glow.layer?.cornerRadius = Style.radius
        glow.layer?.borderWidth = 2.5
        glow.layer?.borderColor = Style.accent.cgColor
        glow.layer?.shadowColor = Style.accent.cgColor
        glow.layer?.shadowRadius = 10
        glow.layer?.shadowOpacity = 0.9
        glow.layer?.shadowOffset = .zero
        glow.layer?.opacity = 0
        addSubview(glow)
        addSubview(toastView)

        registerForDraggedTypes(PasteboardReader.types)
        reload(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func roundedMask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func reload(animated: Bool) {
        guard let shelf else { return }
        let urls = shelf.urls

        let heading = NSMutableAttributedString(string: urls.isEmpty ? "Stash" : urls.count == 1 ? "1 item" : "\(urls.count) items",
                                                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                             .foregroundColor: Style.text])
        let bytes = urls.compactMap(fileSize).reduce(0, +)
        if bytes > 0 {
            heading.append(NSAttributedString(string: "  \(formatSize(bytes))", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: Style.secondary,
            ]))
        }
        titleLabel.attributedStringValue = heading

        modeButton.isEnabled = urls.count > 1
        modeButton.setSymbol(shelf.expanded ? "square.stack.3d.up" : "square.grid.2x2")
        modeButton.toolTip = shelf.expanded ? "Stack" : "Browse"
        shareButton.isEnabled = !urls.isEmpty

        fade(empty, visible: !phoneVisible && urls.isEmpty)
        fade(stack, visible: !phoneVisible && !urls.isEmpty && !shelf.expanded)
        fade(grid, visible: !phoneVisible && !urls.isEmpty && shelf.expanded)
        if let phone { fade(phone, visible: phoneVisible) }
        stack.update(animated: animated)
        grid.update(animated: animated)
    }

    func selectionChanged() { grid.updateSelection() }

    func toast(_ message: String) { toastView.show(message, in: self) }

    // MARK: Phone

    func setPhoneVisible(_ visible: Bool) {
        guard let shelf else { return }
        phoneVisible = visible
        if visible {
            let overlay = phone ?? {
                let view = PhoneOverlay(frame: body.bounds)
                view.onHide = { [weak self] in self?.setPhoneVisible(false) }
                view.onStop = { PhoneServer.shared.stop() }
                body.addSubview(view)
                phone = view
                return view
            }()
            overlay.isHidden = true
            overlay.showLoading()
            PhoneServer.shared.shelf = shelf
            PhoneServer.shared.start { [weak overlay, weak self] link in
                guard let overlay else { return }
                if let link {
                    overlay.show(link)
                    self?.phoneButton.isActive = true
                    print("Stash phone link:", link.absoluteString)
                    fflush(stdout)
                }
                else { overlay.showError("Connect your Mac to Wi‑Fi, then try again.") }
            }
        }
        reload(animated: true)
    }

    func phoneEnded() {
        phoneButton.isActive = false
        if phoneVisible { setPhoneVisible(false) }
    }

    // MARK: Dropping in

    private func accepts(_ info: NSDraggingInfo) -> Bool {
        if let drag = DragOut.current, drag.shelf === shelf { return false }
        return true
    }

    private func setHighlight(_ on: Bool) {
        empty.highlighted = on
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        glow.layer?.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard accepts(info) else { return [] }
        setHighlight(true)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return .copy
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { accepts(info) ? .copy : [] }

    override func draggingExited(_ info: NSDraggingInfo?) { setHighlight(false) }

    override func draggingEnded(_ info: NSDraggingInfo) { setHighlight(false) }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        setHighlight(false)
        guard let shelf, accepts(info) else { return false }
        return PasteboardReader.read(info.draggingPasteboard) { [weak shelf] urls in shelf?.add(urls) }
    }
}
