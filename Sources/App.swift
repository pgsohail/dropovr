// The menu bar app: opens shelves on shake, on ⌃⌥S, or from the menu.

import AppKit
import Carbon.HIToolbox

// MARK: - Shake detection

/// Watches mouse drags system-wide and fires when the cursor is shaken
/// left-right while something is being dragged.
final class ShakeDetector {
    var onShake: ((NSPoint) -> Void)?

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
    private static var action: (() -> Void)?
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        if !HotKey.handlerInstalled {
            HotKey.handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = EventHotKeyID(signature: OSType(0x4452_5652), id: 1)   // 'DRVR'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private(set) var shelves: [ShelfPanel] = []
    private let shake = ShakeDetector()
    private var hotKey: HotKey?
    private var phoneSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.toolTip = "Dropovr"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        shake.onShake = { [weak self] point in self?.openShelf(at: point) }
        shake.start()

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

    private func openShelf(at point: NSPoint) {
        // Reuse an empty shelf instead of piling up new ones.
        if let empty = shelves.first(where: { $0.urls.isEmpty }) {
            empty.present(near: point)
            return
        }
        let shelf = ShelfPanel(near: point)
        shelf.onClose = { [weak self] closed in self?.shelves.removeAll { $0 === closed } }
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
        • Press ⌃⌥S anywhere, or use the menu bar icon

        Fill it
        • Drop files, folders, photos, text, links — anything

        Use it
        • Drag the stack out to move everything
        • Click the stack to browse, then drag single items
        • Space: Quick Look · ⌘C: copy · Delete: remove
        • 📱 Phone button: scan the QR code to send files to or from your phone
        • ⋯ menu: AirDrop, ZIP, Save to Downloads and more

        Make it yours in Settings (⌘, from the menu bar icon).
        """
        alert.runModal()
    }
}
