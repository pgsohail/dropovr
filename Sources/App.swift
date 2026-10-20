// The menu bar app: opens shelves on shake, on ⌃⌥S, or from the menu.

import AppKit
import Carbon.HIToolbox

// MARK: - Shake detection

/// Watches mouse drags system-wide and fires when the cursor is shaken
/// left-right while something is being dragged.
final class ShakeDetector {
    var onShake: ((NSPoint) -> Void)?
    /// Fired when a drag reaches the notch (or the top middle of a screen without one).
    var onNotch: ((NSScreen) -> Void)?
    private var lastNotch: TimeInterval = 0

    private var monitors: [Any] = []
    private var dragChangeCount = 0
    private var lastX: CGFloat = 0
    private var direction = 0
    private var travel: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var lastFire: TimeInterval = 0

    func start() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime

        if event.type == .leftMouseDown {
            dragChangeCount = NSPasteboard(name: .drag).changeCount
            lastX = point.x
            direction = 0
            travel = 0
            reversals.removeAll()
            return
        }
        let dragging = NSPasteboard(name: .drag).changeCount != dragChangeCount
        if dragging, Prefs.notchEnabled, now - lastNotch > 1.5,
           let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
           point.y >= screen.frame.maxY - 6, abs(point.x - screen.frame.midX) < 110 {
            lastNotch = now
            onNotch?(screen)
        }
        guard Prefs.shakeEnabled else { return }

        let dx = point.x - lastX
        lastX = point.x
        guard abs(dx) > 2 else { return }

        // Low needs a long, wide shake; high opens with a quick wiggle.
        let (needed, distance): (Int, CGFloat) = [(5, 40), (4, 30), (3, 22)][min(max(Prefs.shakeSensitivity, 0), 2)]
        let newDirection = dx > 0 ? 1 : -1
        if newDirection == direction {
            travel += abs(dx)
            return
        }
        if direction != 0 && travel >= distance { reversals.append(now) }
        direction = newDirection
        travel = abs(dx)
        reversals.removeAll { now - $0 > 0.9 }

        // Only when a real drag is happening (the drag pasteboard changed),
        // so shaking a window around doesn't pop shelves.
        if reversals.count >= needed, now - lastFire > 1.2,
           NSPasteboard(name: .drag).changeCount != dragChangeCount {
            lastFire = now
            reversals.removeAll()
            onShake?(point)
        }
    }
}

// MARK: - Global shortcut

/// A system-wide keyboard shortcut (no special permissions needed).
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action
        if !HotKey.handlerInstalled {
            HotKey.handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                DispatchQueue.main.async { HotKey.actions[pressed.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4452_5652), id: id)   // 'DRVR'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private(set) var shelves: [ShelfPanel] = []
    private let shake = ShakeDetector()
    private var hotKey: HotKey?
    private var clipboardHotKey: HotKey?
    private let screenshots = ScreenshotWatcher()
    private var phoneSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.toolTip = "Dropovr"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        shake.onShake = { [weak self] point in self?.openShelf(at: point) }
        shake.onNotch = { [weak self] screen in self?.openShelfFromNotch(of: screen) }
        shake.start()
        screenshots.onNew = { [weak self] url in self?.addScreenshot(url) }

        // Drop files straight onto the menu bar icon.
        statusItem.button?.window?.registerForDraggedTypes(PasteboardReader.types)
        statusItem.button?.window?.delegate = self

        restorePinnedShelves()
        ShelfPanel.onChange = { [weak self] in self?.savePinnedShelves() }

        // When the phone needs a shelf and none is attached, use the newest one (or open one).
        PhoneServer.shared.shelfProvider = { [weak self] create in
            guard let self else { return nil }
            if let open = self.shelves.last(where: { $0.isVisible }) { return open }
            guard create, let screen = NSScreen.main else { return nil }
            self.openShelf(at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY))
            return self.shelves.last
        }

        _ = Prefs.phoneToken   // create it now, not from inside a preferences-changed callback
        applyPrefs()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyPrefs()
        }

        if CommandLine.arguments.contains("--new-shelf") { newShelf() }
        if CommandLine.arguments.contains("--share-phone") {
            newShelf()
            shelves.last?.togglePhone()
        }
        if CommandLine.arguments.contains("--settings") { SettingsWindow.show() }
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.async { self.showHelp() }
        }
    }

    static func menuBarIcon() -> NSImage {
        let logo = Bundle.main.url(forResource: "logo", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Dropovr")!
        logo.size = NSSize(width: 18, height: 18)
        logo.isTemplate = true
        return logo
    }

    /// Brings everything in line with Settings; runs whenever a preference changes.
    private func applyPrefs() {
        if Prefs.hotKeyEnabled, hotKey == nil {
            hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) { [weak self] in self?.newShelf() }
        } else if !Prefs.hotKeyEnabled {
            hotKey = nil
        }
        if Prefs.clipboardHotKeyEnabled, clipboardHotKey == nil {
            clipboardHotKey = HotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey) { [weak self] in self?.clipboardToShelf() }
        } else if !Prefs.clipboardHotKeyEnabled {
            clipboardHotKey = nil
        }
        if Prefs.screenshotsEnabled { screenshots.start() } else { screenshots.stop() }
        shelves.forEach { $0.shelfView.applyDarkness() }

        let signature = Prefs.phoneAlwaysOn ? "on \(Prefs.phoneUseHostname) \(Prefs.phoneToken)" : "off"
        if signature != phoneSignature {
            let first = phoneSignature.isEmpty
            phoneSignature = signature
            if Prefs.phoneAlwaysOn {
                PhoneServer.shared.restart()
            } else if !first, PhoneServer.shared.isPersistent {
                PhoneServer.shared.stop()
            }
        }
    }

    // Opening Dropovr again (from Applications, Spotlight or Raycast) pops a shelf.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        newShelf()
        return false
    }

    // Files opened with Dropovr (Open With, or dropped on its icon) land on a shelf.
    func application(_ application: NSApplication, open urls: [URL]) {
        let target = shelves.last { $0.isVisible } ?? {
            newShelf()
            return shelves.last
        }()
        target?.add(urls)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let new = menu.addItem(withTitle: "New Shelf", action: #selector(newShelf), keyEquivalent: Prefs.hotKeyEnabled ? "s" : "")
        new.keyEquivalentModifierMask = [.control, .option]
        new.target = self
        new.image = symbol("plus.rectangle.on.rectangle", size: 13, weight: .regular)
        let clip = menu.addItem(withTitle: "Clipboard to Shelf", action: #selector(clipboardToShelf),
                                keyEquivalent: Prefs.clipboardHotKeyEnabled ? "v" : "")
        clip.keyEquivalentModifierMask = [.control, .option]
        clip.target = self
        clip.image = symbol("doc.on.clipboard", size: 13, weight: .regular)
        if !shelves.isEmpty {
            let all = menu.addItem(withTitle: "Close All Shelves", action: #selector(closeAll), keyEquivalent: "")
            all.target = self
            all.image = symbol("xmark.rectangle", size: 13, weight: .regular)
        }
        if Prefs.phoneAlwaysOn {
            let phone = menu.addItem(withTitle: PhoneServer.shared.link == nil ? "Phone Link Starting…" : "Phone Link Is On",
                                     action: #selector(openPhoneSettings), keyEquivalent: "")
            phone.target = self
            phone.image = symbol("iphone.radiowaves.left.and.right", size: 13, weight: .regular)
        }
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = symbol("gearshape", size: 13, weight: .regular)
        menu.addItem(withTitle: "How to Use Dropovr", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dropovr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func newShelf() {
        openShelf(at: NSEvent.mouseLocation)
    }

    /// The newest open shelf, or a new one at `point`.
    private func shelfForAdding(at point: NSPoint) -> ShelfPanel? {
        if let open = shelves.last(where: { $0.isVisible }) { return open }
        openShelf(at: point)
        return shelves.last
    }

    private func openShelfFromNotch(of screen: NSScreen) {
        let shelf = shelves.first(where: { $0.urls.isEmpty }) ?? {
            let made = ShelfPanel(near: NSPoint(x: screen.frame.midX, y: screen.frame.maxY))
            made.onClose = { [weak self] closed in self?.shelves.removeAll { $0 === closed } }
            shelves.append(made)
            return made
        }()
        shelf.presentFromNotch(of: screen)
    }

    @objc func clipboardToShelf() {
        let point = NSEvent.mouseLocation
        let pasteboard = NSPasteboard.general
        guard pasteboard.pasteboardItems?.isEmpty == false else { return }
        let shelf = shelfForAdding(at: point)
        let ok = PasteboardReader.read(pasteboard) { [weak shelf] urls in shelf?.add(urls) }
        shelf?.shelfView.toast(ok ? "Added from clipboard" : "Nothing to add")
    }

    private func addScreenshot(_ url: URL) {
        guard let screen = NSScreen.main else { return }
        let corner = NSPoint(x: screen.visibleFrame.maxX - ShelfPanel.size.width / 2, y: screen.visibleFrame.minY + ShelfPanel.size.height / 2)
        guard let shelf = shelfForAdding(at: corner) else { return }
        shelf.add([url])
        shelf.shelfView.toast("Screenshot added")
    }

    // MARK: Pinned shelves

    private func restorePinnedShelves() {
        for saved in ShelfStore.load() {
            let urls = saved.paths.map { URL(fileURLWithPath: $0) }.filter { disk.fileExists(atPath: $0.path) }
            let shelf = ShelfPanel(near: .zero)
            shelf.onClose = { [weak self] closed in
                self?.shelves.removeAll { $0 === closed }
                self?.savePinnedShelves()
            }
            shelves.append(shelf)
            shelf.add(urls)
            shelf.pinned = true
            shelf.setFrameOrigin(NSPoint(x: saved.x, y: saved.y))
            shelf.orderFrontRegardless()
        }
    }

    private func savePinnedShelves() {
        ShelfStore.save(shelves.filter { $0.isVisible || $0.urls.count > 0 })
    }

    // MARK: Dropping on the menu bar icon

    @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let frame = statusItem.button?.window?.frame else { return [] }
        let below = NSPoint(x: frame.midX, y: frame.minY - ShelfPanel.size.height / 2 - 8)
        if shelves.last(where: { $0.isVisible }) == nil { openShelf(at: below) }
        else { shelves.last(where: { $0.isVisible })?.present(near: below) }
        return .copy
    }

    @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let shelf = shelves.last(where: { $0.isVisible }) else { return false }
        return PasteboardReader.read(sender.draggingPasteboard) { [weak shelf] urls in shelf?.add(urls) }
    }

    private func openShelf(at point: NSPoint) {
        // Reuse an empty shelf instead of piling up new ones.
        if let empty = shelves.first(where: { $0.urls.isEmpty }) {
            empty.present(near: point)
            return
        }
        let shelf = ShelfPanel(near: point)
        shelf.onClose = { [weak self] closed in
            self?.shelves.removeAll { $0 === closed }
            self?.savePinnedShelves()
        }
        shelves.append(shelf)
        shelf.present(near: point)
    }

    @objc private func closeAll() {
        shelves.forEach { $0.close() }
    }

    @objc private func openSettings() { SettingsWindow.show() }

    @objc private func openPhoneSettings() { SettingsWindow.show(tab: .phone) }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Dropovr lives in your menu bar"
        alert.informativeText = """
        Open a shelf
        • Shake the mouse while dragging anything
        • Drag anything to the notch (top middle of the screen)
        • Drop files on the menu bar icon
        • Press ⌃⌥S anywhere · ⌃⌥V puts what you copied on a shelf
        • Take a screenshot — it lands on a shelf

        Fill it
        • Drop files, folders, photos, text, links — anything

        Use it
        • Drag the stack out to move everything
        • Click the stack to browse, then drag single items
        • Space: Quick Look · ⌘C: copy · Delete: remove
        • 📱 Phone button: scan the QR code to send files to or from your phone
        • Right-click or ⋯: Share Link, AirDrop, image tools (remove background, resize, convert), ZIP and more
        • ⌘P pins a shelf so it stays after a restart

        Make it yours in Settings (⌘, from the menu bar icon).
        """
        alert.runModal()
    }
}
