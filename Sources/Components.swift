// The pieces a shelf is made of: header buttons, the card stack, the grid,
// the empty drop zone, toasts, and dragging things back out.

import AppKit

enum Style {
    static let radius: CGFloat = 22
    static let text = NSColor(white: 1, alpha: 0.96)
    static let secondary = NSColor(white: 1, alpha: 0.58)
    static let faint = NSColor(white: 1, alpha: 0.12)
    static var accent: NSColor { .controlAccentColor }
    /// A soft overshooting ease, like a spring.
    static let spring = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.35, 1)
    static let smooth = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
}

func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
           color: NSColor = Style.text, align: NSTextAlignment = .center) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.alignment = align
    field.lineBreakMode = .byTruncatingMiddle
    field.maximumNumberOfLines = 1
    return field
}

func fade(_ view: NSView, visible: Bool, duration: TimeInterval = 0.14) {
    if visible {
        if view.isHidden { view.alphaValue = 0; view.isHidden = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = Style.smooth
            view.animator().alphaValue = 1
        }
    } else if !view.isHidden {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration * 0.75
            view.animator().alphaValue = 0
        }, completionHandler: {
            if view.alphaValue < 0.01 { view.isHidden = true }
        })
    }
}

/// Ignores the mouse so whatever is underneath gets clicks and drops.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Buttons

final class HeaderButton: NSButton {
    private var hovering = false { didSet { refresh() } }
    var isActive = false { didSet { refresh() } }

    init(symbol name: String, tip: String, target: AnyObject?, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        isBordered = false
        imagePosition = .imageOnly
        toolTip = tip
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 8
        setSymbol(name)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String) {
        image = symbol(name, size: 12, weight: .semibold)
        image?.isTemplate = true
    }

    override var isEnabled: Bool { didSet { refresh() } }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func refresh() {
        contentTintColor = !isEnabled ? NSColor(white: 1, alpha: 0.22)
            : isActive ? Style.accent : NSColor(white: 1, alpha: hovering ? 0.95 : 0.7)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            layer?.backgroundColor = (isActive ? Style.accent.withAlphaComponent(0.2)
                : hovering && isEnabled ? NSColor(white: 1, alpha: 0.1) : .clear).cgColor
        }
    }
}

final class PillButton: NSButton {
    private var hovering = false { didSet { refresh() } }
    private let prominent: Bool

    init(_ title: String, prominent: Bool = false, target: AnyObject?, action: Selector) {
        self.prominent = prominent
        super.init(frame: .zero)
        isBordered = false
        setTitle(title)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 14
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func setTitle(_ title: String) {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func refresh() {
        let base = prominent ? Style.accent : NSColor(white: 1, alpha: 0.12)
        layer?.backgroundColor = (hovering ? base.blended(withFraction: 0.18, of: .white) ?? base : base).cgColor
    }
}

// MARK: - Dragging out

/// One drag of items out of a shelf. Items that get moved (or binned) leave the shelf;
/// items that get copied somewhere stay so you can use them again.
final class DragOut: NSObject, NSDraggingSource {
    static private(set) var current: DragOut?
    let urls: [URL]
    weak var shelf: ShelfPanel?

    private init(urls: [URL], shelf: ShelfPanel) {
        self.urls = urls
        self.shelf = shelf
    }

    static func begin(from view: NSView, event: NSEvent, urls: [URL], shelf: ShelfPanel) {
        guard !urls.isEmpty else { return }
        let drag = DragOut(urls: urls, shelf: shelf)
        current = drag
        let start = view.convert(event.locationInWindow, from: nil)
        let items = urls.enumerated().map { index, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = Thumbnails.shared.best(url)
            let frame = aspectFit(image.size, in: CGRect(x: start.x - 32, y: start.y - 32, width: 64, height: 64))
            item.setDraggingFrame(frame.offsetBy(dx: CGFloat(min(index, 3)) * 3, dy: CGFloat(min(index, 3)) * -3),
                                  contents: image)
            return item
        }
        let session = view.beginDraggingSession(with: items, event: event, source: drag)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic, .delete] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let moved = operation.contains(.move) || operation.contains(.delete)
        if moved || (Prefs.removeAfterDrag == 1 && !operation.isEmpty) {
            shelf?.remove(urls)
        } else if !operation.isEmpty {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        DragOut.current = nil
    }
}

// MARK: - Card stack

/// The fanned pile of previews. Drag it to take everything; click it to browse.
final class StackView: NSView {
    weak var shelf: ShelfPanel?

    private final class Card {
        let container = CALayer()
        let image = CALayer()
        var size = CGSize(width: 120, height: 120)
    }

    private var cards: [URL: Card] = [:]
    private var order: [URL] = []
    private let badge = CALayer()
    private let badgeText = CATextLayer()
    private let title = label(size: 13, weight: .semibold)
    private let subtitle = label(size: 11, color: Style.secondary)
    private var hovering = false { didSet { if hovering != oldValue { layoutCards(animated: true) } } }
    private var down: NSEvent?
    private var dragged = false
    private let box: CGFloat = 112

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        badge.backgroundColor = Style.accent.cgColor
        badge.cornerRadius = 11
        badge.borderWidth = 2
        badge.borderColor = NSColor(white: 0.1, alpha: 0.6).cgColor
        badge.zPosition = 50
        badge.shadowOpacity = 0.4
        badge.shadowRadius = 4
        badge.shadowOffset = CGSize(width: 0, height: -1)
        badgeText.fontSize = 12
        badgeText.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.alignmentMode = .center
        badgeText.contentsScale = 2
        badge.addSublayer(badgeText)
        layer?.addSublayer(badge)

        title.frame = NSRect(x: 8, y: 22, width: frame.width - 16, height: 18)
        subtitle.frame = NSRect(x: 8, y: 4, width: frame.width - 16, height: 16)
        addSubview(title)
        addSubview(subtitle)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY + 20) }

    func update(animated: Bool) {
        guard let shelf, let root = layer else { return }
        let shown = Array(shelf.urls.suffix(3).reversed())   // newest first, on top

        for (url, card) in cards where !shown.contains(url) {
            card.container.removeFromSuperlayer()
            cards[url] = nil
        }
        var arrived: Card?
        for url in shown where cards[url] == nil {
            let card = Card()
            card.container.shadowColor = NSColor.black.cgColor
            card.container.shadowOpacity = 0.5
            card.container.shadowRadius = 14
            card.container.shadowOffset = CGSize(width: 0, height: -8)
            card.container.position = center
            card.image.contentsGravity = .resizeAspect
            card.container.addSublayer(card.image)
            root.addSublayer(card.container)
            cards[url] = card
            Thumbnails.shared.load(url) { [weak self, weak card] thumb in
                guard let self, let card else { return }
                self.apply(thumb, to: card)
            }
            if url == shown.first { arrived = card }
        }
        order = shown
        layoutCards(animated: animated)

        if animated, let card = arrived {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 1.35
            pop.toValue = 1
            pop.damping = 13
            pop.stiffness = 260
            pop.duration = pop.settlingDuration
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = 0.12
            card.container.add(pop, forKey: "pop")
            card.container.add(appear, forKey: "appear")
        }

        let count = shelf.urls.count
        if count == 1, let url = shelf.urls.first {
            title.stringValue = url.lastPathComponent
            subtitle.stringValue = kindDescription(url)
        } else {
            title.stringValue = "\(count) items"
            subtitle.stringValue = "Drag to move all  ·  Click to browse"
        }
    }

    private func apply(_ thumb: Thumb, to card: Card) {
        let fitted = thumb.isPreview
            ? aspectFit(thumb.image.size, in: CGRect(x: 0, y: 0, width: box, height: box)).size
            : CGSize(width: box, height: box)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        card.size = fitted
        card.container.bounds = CGRect(origin: .zero, size: fitted)
        card.image.frame = card.container.bounds
        card.image.setImage(thumb.image)
        card.image.cornerRadius = thumb.isPreview ? 12 : 0
        card.image.masksToBounds = thumb.isPreview
        card.image.borderWidth = thumb.isPreview ? 1 : 0
        card.image.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        card.container.shadowPath = thumb.isPreview
            ? CGPath(roundedRect: card.container.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil) : nil
        CATransaction.commit()
        layoutCards(animated: true)
    }

    private func layoutCards(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.36 : 0)
        CATransaction.setAnimationTimingFunction(Style.spring)
        CATransaction.setDisableActions(!animated)

        let angles: [CGFloat] = [0, -8, 8]
        let shifts: [CGFloat] = [0, -18, 18]
        let spread: CGFloat = hovering ? 1.7 : 1
        for (index, url) in order.enumerated() {
            guard let card = cards[url] else { continue }
            let lift: CGFloat = index == 0 && hovering ? 6 : 0
            card.container.position = CGPoint(x: center.x + shifts[index] * spread, y: center.y + lift)
            card.container.zPosition = CGFloat(10 - index)
            let scale: CGFloat = index == 0 ? (hovering ? 1.05 : 1) : 0.9
            var transform = CATransform3DMakeRotation(angles[index] * spread * .pi / 180, 0, 0, 1)
            transform = CATransform3DScale(transform, scale, scale, 1)
            card.container.transform = transform
            card.container.shadowOpacity = index == 0 ? (hovering ? 0.6 : 0.5) : 0.35
        }

        let count = shelf?.urls.count ?? 0
        badge.opacity = count > 1 ? 1 : 0
        badgeText.string = "\(count)"
        let width: CGFloat = count > 9 ? 30 : 22
        badge.bounds = CGRect(x: 0, y: 0, width: width, height: 22)
        badgeText.frame = CGRect(x: 0, y: 3, width: width, height: 16)
        if let top = order.first, let card = cards[top] {
            let lift: CGFloat = hovering ? 6 : 0
            badge.position = CGPoint(x: center.x + card.size.width / 2 - 2, y: center.y + card.size.height / 2 - 2 + lift)
        }
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        down = event
        dragged = false
        if event.clickCount == 2, let shelf, shelf.urls.count == 1, let url = shelf.urls.first {
            NSWorkspace.shared.open(url)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, !dragged, let shelf else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        dragged = true
        DragOut.begin(from: self, event: down, urls: shelf.urls, shelf: shelf)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged, event.clickCount == 1, let shelf, shelf.urls.count > 1 else { return }
        shelf.setExpanded(true)
    }

    override func menu(for event: NSEvent) -> NSMenu? { shelf?.buildMenu() }
}

// MARK: - Grid

final class TileView: NSView {
    static let size = NSSize(width: 74, height: 94)
    let url: URL
    weak var shelf: ShelfPanel?

    private let background = CALayer()
    private let imageLayer = CALayer()
    private let name = NSTextField(wrappingLabelWithString: "")
    private var hovering = false { didSet { refresh() } }
    private var down: NSEvent?
    private var selectOnMouseUp = false
    var selected = false { didSet { if selected != oldValue { refresh() } } }

    init(url: URL, shelf: ShelfPanel) {
        self.url = url
        self.shelf = shelf
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        background.frame = bounds
        background.cornerRadius = 14
        layer?.addSublayer(background)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.shadowColor = NSColor.black.cgColor
        imageLayer.shadowOpacity = 0.35
        imageLayer.shadowRadius = 5
        imageLayer.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(imageLayer)

        name.stringValue = url.lastPathComponent
        name.font = .systemFont(ofSize: 10.5, weight: .medium)
        name.textColor = Style.text
        name.alignment = .center
        name.maximumNumberOfLines = 2
        name.lineBreakMode = .byTruncatingMiddle
        name.cell?.truncatesLastVisibleLine = true
        name.frame = NSRect(x: 3, y: 3, width: Self.size.width - 6, height: 28)
        addSubview(name)
        toolTip = url.lastPathComponent

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        Thumbnails.shared.load(url) { [weak self] thumb in self?.apply(thumb) }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    private func apply(_ thumb: Thumb) {
        let box = CGRect(x: 12, y: 34, width: 50, height: 50)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = thumb.isPreview ? aspectFit(thumb.image.size, in: box) : box
        imageLayer.setImage(thumb.image)
        imageLayer.cornerRadius = thumb.isPreview ? 7 : 0
        imageLayer.borderWidth = thumb.isPreview ? 0.5 : 0
        imageLayer.borderColor = NSColor(white: 1, alpha: 0.2).cgColor
        imageLayer.shadowPath = thumb.isPreview
            ? CGPath(roundedRect: imageLayer.bounds, cornerWidth: 7, cornerHeight: 7, transform: nil) : nil
        CATransaction.commit()
        if thumb.isPreview {
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0.3
            fadeIn.toValue = 1
            fadeIn.duration = 0.18
            imageLayer.add(fadeIn, forKey: "fade")
        }
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.1)
        background.backgroundColor = (selected ? Style.accent.withAlphaComponent(0.42)
            : hovering ? NSColor(white: 1, alpha: 0.13) : NSColor(white: 1, alpha: 0.06)).cgColor
        background.borderWidth = 1
        background.borderColor = (selected ? Style.accent : NSColor(white: 1, alpha: hovering ? 0.16 : 0.07)).cgColor
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        down = event
        window?.makeKey()
        if event.clickCount == 2 { NSWorkspace.shared.open(url); return }
        let flags = event.modifierFlags
        if selected && !flags.contains(.command) && !flags.contains(.shift) {
            selectOnMouseUp = true   // keep a multi-selection intact in case this becomes a drag
        } else {
            shelf?.click(url, modifiers: flags)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, let shelf else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        self.down = nil
        selectOnMouseUp = false
        let urls = selected ? shelf.urls.filter { shelf.selection.contains($0) } : [url]
        DragOut.begin(from: self, event: down, urls: urls, shelf: shelf)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if !selected { shelf?.click(url, modifiers: []) }
        return shelf?.buildMenu()
    }

    override func mouseUp(with event: NSEvent) {
        if selectOnMouseUp { shelf?.click(url, modifiers: []) }
        selectOnMouseUp = false
        down = nil
    }
}

final class GridDocument: NSView {
    weak var shelf: ShelfPanel?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { shelf?.clearSelection() }
    override func menu(for event: NSEvent) -> NSMenu? { shelf?.buildMenu() }
}

final class GridView: NSScrollView {
    weak var shelf: ShelfPanel? { didSet { document.shelf = shelf } }
    private let document = GridDocument()
    private var tiles: [URL: TileView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .allowed
        automaticallyAdjustsContentInsets = false
        documentView = document
        document.frame = NSRect(origin: .zero, size: contentSize)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(animated: Bool) {
        guard let shelf else { return }
        let ordered = Array(shelf.urls.reversed())
        let columns = 3
        let tile = TileView.size
        let gapX = (contentSize.width - CGFloat(columns) * tile.width) / CGFloat(columns - 1)
        let gapY: CGFloat = 6
        let rows = (ordered.count + columns - 1) / columns
        document.frame = NSRect(x: 0, y: 0, width: contentSize.width,
                                height: max(CGFloat(rows) * (tile.height + gapY), contentSize.height))

        let keep = Set(ordered)
        for (url, view) in tiles where !keep.contains(url) {
            tiles[url] = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                view.animator().alphaValue = 0
            }, completionHandler: { view.removeFromSuperview() })
        }
        for (index, url) in ordered.enumerated() {
            let frame = NSRect(x: CGFloat(index % columns) * (tile.width + gapX),
                               y: CGFloat(index / columns) * (tile.height + gapY),
                               width: tile.width, height: tile.height)
            if let view = tiles[url] {
                if animated {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.22
                        ctx.timingFunction = Style.smooth
                        view.animator().frame = frame
                    }
                } else {
                    view.frame = frame
                }
            } else {
                let view = TileView(url: url, shelf: shelf)
                view.frame = frame
                view.alphaValue = animated ? 0 : 1
                document.addSubview(view)
                tiles[url] = view
                if animated { fade(view, visible: true, duration: 0.18) }
            }
        }
        updateSelection()
    }

    func updateSelection() {
        for (url, view) in tiles { view.selected = shelf?.selection.contains(url) ?? false }
    }
}

// MARK: - Empty state

final class EmptyDropView: NSView {
    private let border = CAShapeLayer()
    private let icon = CALayer()
    private let title = label("Drop anything here", size: 14, weight: .semibold)
    private let subtitle = label("Files, folders, photos, text and links", size: 11.5, color: Style.secondary)
    private let hint = label("Shake, drag to the notch, or press ⌃⌥S", size: 10.5, color: NSColor(white: 1, alpha: 0.3))

    var highlighted = false { didSet { if highlighted != oldValue { refresh() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let box = bounds.insetBy(dx: 1, dy: 1)
        border.frame = bounds
        border.path = CGPath(roundedRect: box, cornerWidth: 18, cornerHeight: 18, transform: nil)
        border.lineWidth = 1.5
        border.lineDashPattern = [7, 6]
        layer?.addSublayer(border)

        if let image = symbol("tray.and.arrow.down.fill", size: 30, weight: .medium, color: NSColor(white: 1, alpha: 0.75)) {
            icon.bounds = CGRect(origin: .zero, size: image.size)
            icon.setImage(image)
        }
        icon.position = CGPoint(x: bounds.midX, y: bounds.midY + 34)
        layer?.addSublayer(icon)

        title.frame = NSRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 20)
        subtitle.frame = NSRect(x: 0, y: bounds.midY - 32, width: bounds.width, height: 16)
        hint.frame = NSRect(x: 0, y: 14, width: bounds.width, height: 14)
        addSubview(title)
        addSubview(subtitle)
        addSubview(hint)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        CATransaction.setAnimationTimingFunction(Style.spring)
        border.strokeColor = (highlighted ? Style.accent : NSColor(white: 1, alpha: 0.28)).cgColor
        border.fillColor = (highlighted ? Style.accent.withAlphaComponent(0.16) : NSColor(white: 1, alpha: 0.045)).cgColor
        icon.transform = highlighted
            ? CATransform3DTranslate(CATransform3DMakeScale(1.15, 1.15, 1), 0, -4, 0) : CATransform3DIdentity
        CATransaction.commit()
        title.stringValue = highlighted ? "Release to stash it" : "Drop anything here"

        if highlighted {
            let march = CABasicAnimation(keyPath: "lineDashPhase")
            march.fromValue = 0
            march.toValue = -26
            march.duration = 0.7
            march.repeatCount = .infinity
            border.add(march, forKey: "march")
        } else {
            border.removeAnimation(forKey: "march")
        }
    }
}

// MARK: - Toast

final class ToastView: NSView {
    private let text = label(size: 12, weight: .semibold)
    private var hideWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.96).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        addSubview(text)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ message: String, in parent: NSView) {
        text.stringValue = message
        let width = min(text.intrinsicContentSize.width + 30, parent.bounds.width - 40)
        frame = NSRect(x: (parent.bounds.width - width) / 2, y: 18, width: width, height: 28)
        text.frame = NSRect(x: 12, y: 6, width: width - 24, height: 16)
        fade(self, visible: true, duration: 0.2)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in if let self { fade(self, visible: false, duration: 0.3) } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
