// The menu bar app: opens shelves on shake, on ⌃⌥S, or from the menu.

import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Shake detection

/// Watches mouse drags system-wide and fires when the cursor is shaken
/// left-right while something is being dragged.
final class ShakeDetector {
    var onShake: ((NSPoint) -> Void)?
    var enabled = true

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
        guard enabled else { return }

        let dx = point.x - lastX
        lastX = point.x
        guard abs(dx) > 2 else { return }

        let newDirection = dx > 0 ? 1 : -1
        if newDirection == direction {
            travel += abs(dx)
            return
        }
        if direction != 0 && travel >= 30 { reversals.append(now) }
        direction = newDirection
        travel = abs(dx)
        reversals.removeAll { now - $0 > 0.9 }

        // Only when a real drag is happening (the drag pasteboard changed),
        // so shaking a window around doesn't pop shelves.
        if reversals.count >= 4, now - lastFire > 1.2,
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
    private var ref: EventHotKeyRef?

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5354_5348), id: 1)   // 'STSH'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var shelves: [ShelfPanel] = []
    private let shake = ShakeDetector()
    private var hotKey: HotKey?

    private var shakeEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "shakeDisabled") }
        set {
            UserDefaults.standard.set(!newValue, forKey: "shakeDisabled")
            shake.enabled = newValue
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Stash")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        shake.enabled = shakeEnabled
        shake.onShake = { [weak self] point in self?.openShelf(at: point) }
        shake.start()
        hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) { [weak self] in self?.newShelf() }

        if CommandLine.arguments.contains("--new-shelf") { newShelf() }
        if CommandLine.arguments.contains("--share-phone") {
            newShelf()
            shelves.last?.togglePhone()
        }
        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            DispatchQueue.main.async { self.showHelp() }
        }
    }

    // Opening Stash again (from Applications, Spotlight or Raycast) pops a shelf.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        newShelf()
        return false
    }

    // Files opened with Stash (Open With, or dropped on its icon) land on a shelf.
    func application(_ application: NSApplication, open urls: [URL]) {
        let target = shelves.last { $0.isVisible } ?? {
            newShelf()
            return shelves.last
        }()
        target?.add(urls)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let new = menu.addItem(withTitle: "New Shelf", action: #selector(newShelf), keyEquivalent: "s")
        new.keyEquivalentModifierMask = [.control, .option]
        new.target = self
        new.image = symbol("plus.rectangle.on.rectangle", size: 13, weight: .regular)
        if !shelves.isEmpty {
            let all = menu.addItem(withTitle: "Close All Shelves", action: #selector(closeAll), keyEquivalent: "")
            all.target = self
            all.image = symbol("xmark.rectangle", size: 13, weight: .regular)
        }
        menu.addItem(.separator())
        let shakeItem = menu.addItem(withTitle: "Shake Mouse to Open Shelf", action: #selector(toggleShake), keyEquivalent: "")
        shakeItem.target = self
        shakeItem.state = shakeEnabled ? .on : .off
        let loginItem = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "How to Use Stash", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Stash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    @objc private func toggleShake() { shakeEnabled.toggle() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Stash lives in your menu bar"
        alert.informativeText = """
        Open a shelf
        • Shake the mouse while dragging anything
        • Press ⌃⌥S anywhere, or use the tray icon

        Fill it
        • Drop files, folders, photos, text, links — anything

        Use it
        • Drag the stack out to move everything
        • Click the stack to browse, then drag single items
        • Space: Quick Look · ⌘C: copy · Delete: remove
        • 📱 Phone button: scan the QR code to send files to or from your phone
        • ⋯ menu: AirDrop, ZIP, Save to Downloads and more
        """
        alert.runModal()
    }
}
