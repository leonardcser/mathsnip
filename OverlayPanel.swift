import Cocoa

class OverlayPanel: NSPanel {
    weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.appDelegate = appDelegate

        // Panel configuration
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false

        // Don't show in window switcher or mission control
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true

        // Create overlay view
        let overlayView = OverlayView(frame: screenFrame)
        overlayView.overlayPanel = self
        contentView = overlayView

        makeFirstResponder(overlayView)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class OverlayView: NSView {
    weak var overlayPanel: OverlayPanel?

    private var startPoint: NSPoint = .zero
    private var currentPoint: NSPoint = .zero
    private var isSelecting = false

    override init(frame: NSRect) {
        super.init(frame: frame)

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Initialize crosshair at current mouse position
        if let window = window {
            let mouseLocation = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: mouseLocation)
            currentPoint = convert(windowPoint, from: nil)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw semi-transparent overlay
        NSColor(white: 0, alpha: 0.3).setFill()
        bounds.fill()

        // Draw selection if selecting
        if isSelecting {
            let selectionRect = self.selectionRect

            // Clear selection area
            NSColor.clear.setFill()
            selectionRect.fill(using: .clear)

            // Draw border
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selectionRect)
            path.lineWidth = 1.0
            path.stroke()
        }

        // Draw crosshair
        NSColor(white: 1, alpha: 0.8).setStroke()

        let vLine = NSBezierPath()
        vLine.move(to: NSPoint(x: currentPoint.x, y: 0))
        vLine.line(to: NSPoint(x: currentPoint.x, y: bounds.height))
        vLine.lineWidth = 1.0
        vLine.stroke()

        let hLine = NSBezierPath()
        hLine.move(to: NSPoint(x: 0, y: currentPoint.y))
        hLine.line(to: NSPoint(x: bounds.width, y: currentPoint.y))
        hLine.lineWidth = 1.0
        hLine.stroke()
    }

    private var selectionRect: NSRect {
        let x = min(startPoint.x, currentPoint.x)
        let y = min(startPoint.y, currentPoint.y)
        let width = abs(currentPoint.x - startPoint.x)
        let height = abs(currentPoint.y - startPoint.y)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        isSelecting = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isSelecting {
            currentPoint = convert(event.locationInWindow, from: nil)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isSelecting {
            isSelecting = false
            let rect = selectionRect

            if rect.width >= 10 && rect.height >= 10 {
                // Convert to screen coordinates
                let windowRect = convert(rect, to: nil)
                let screenRect = window?.convertToScreen(windowRect) ?? rect
                overlayPanel?.appDelegate?.handleSelection(screenRect)
            } else {
                overlayPanel?.appDelegate?.cancelSnipping()
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            overlayPanel?.appDelegate?.cancelSnipping()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
}
