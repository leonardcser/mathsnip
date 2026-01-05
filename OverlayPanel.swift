import Cocoa
import CoreGraphics

class OverlayPanel: NSWindow {
    weak var appDelegate: AppDelegate?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(appDelegate: AppDelegate) {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        self.appDelegate = appDelegate

        // Create overlay view
        let overlayView = OverlayView(frame: screenFrame)
        overlayView.overlayPanel = self
        contentView = overlayView

        setupEventTap()
    }

    // Called from AppDelegate BEFORE showing the window
    func configureForOverlay() {
        guard NSScreen.main != nil else { return }

        // Activate app to gain cursor control
        NSApp.activate(ignoringOtherApps: true)

        // Window level above menubar
        level = .screenSaver

        // Set position to cover entire screen including menubar
        setFrameOrigin(NSPoint(x: 0, y: 0))

        // Remove title bar elements
        styleMask.remove(.titled)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Visual properties
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Don't show in window switcher or mission control
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func setupEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue) |
                                      (1 << CGEventType.leftMouseDown.rawValue) |
                                      (1 << CGEventType.leftMouseDragged.rawValue) |
                                      (1 << CGEventType.leftMouseUp.rawValue) |
                                      (1 << CGEventType.keyDown.rawValue)

        // Store self in a pointer to pass to the callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let panel = Unmanaged<OverlayPanel>.fromOpaque(refcon).takeUnretainedValue()
                return panel.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            print("Failed to create event tap. Check Accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let overlayView = contentView as? OverlayView else {
            return Unmanaged.passRetained(event)
        }

        // Handle tap disabled (system can disable taps if they take too long)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let location = event.location  // Screen coordinates (CG coordinates, origin at top-left)

        switch type {
        case .mouseMoved:
            overlayView.handleMouseMoved(screenPoint: location)
            return nil  // Consume the event

        case .leftMouseDown:
            overlayView.handleMouseDown(screenPoint: location)
            return nil

        case .leftMouseDragged:
            overlayView.handleMouseDragged(screenPoint: location)
            return nil

        case .leftMouseUp:
            overlayView.handleMouseUp(screenPoint: location)
            return nil

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == 53 {  // Escape
                DispatchQueue.main.async {
                    self.appDelegate?.cancelSnipping()
                }
                return nil
            }
            return nil  // Consume all keys during snipping

        default:
            return Unmanaged.passRetained(event)
        }
    }

    func cleanup() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        cleanup()
    }
}

class OverlayView: NSView {
    weak var overlayPanel: OverlayPanel?

    private var startPoint: NSPoint = .zero
    private var currentPoint: NSPoint = .zero
    private var isSelecting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // Convert CG screen coordinates (origin top-left) to view coordinates (origin bottom-left)
    private func viewPointFromScreenPoint(_ cgPoint: CGPoint) -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: cgPoint.x, y: cgPoint.y) }
        // CG coordinates: origin at top-left, Y increases downward
        // NS coordinates: origin at bottom-left, Y increases upward
        let nsScreenPoint = NSPoint(x: cgPoint.x, y: screen.frame.height - cgPoint.y)
        return nsScreenPoint
    }

    func handleMouseMoved(screenPoint: CGPoint) {
        currentPoint = viewPointFromScreenPoint(screenPoint)
        DispatchQueue.main.async {
            self.needsDisplay = true
        }
    }

    func handleMouseDown(screenPoint: CGPoint) {
        let point = viewPointFromScreenPoint(screenPoint)
        startPoint = point
        currentPoint = point
        isSelecting = true
        DispatchQueue.main.async {
            self.needsDisplay = true
        }
    }

    func handleMouseDragged(screenPoint: CGPoint) {
        if isSelecting {
            currentPoint = viewPointFromScreenPoint(screenPoint)
            DispatchQueue.main.async {
                self.needsDisplay = true
            }
        }
    }

    func handleMouseUp(screenPoint: CGPoint) {
        if isSelecting {
            isSelecting = false
            let rect = selectionRect

            if rect.width >= 10 && rect.height >= 10 {
                // The rect is already in view/screen coordinates (NS coordinates)
                let screenRect = NSRect(
                    x: rect.origin.x,
                    y: rect.origin.y,
                    width: rect.width,
                    height: rect.height
                )
                DispatchQueue.main.async {
                    self.overlayPanel?.appDelegate?.handleSelection(screenRect)
                }
            } else {
                DispatchQueue.main.async {
                    self.overlayPanel?.appDelegate?.cancelSnipping()
                }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        // Initialize crosshair at current mouse position
        if window != nil, NSScreen.main != nil {
            let cgMouseLocation = CGEvent(source: nil)?.location ?? .zero
            currentPoint = viewPointFromScreenPoint(cgMouseLocation)
            NSCursor.crosshair.push()
            needsDisplay = true
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Pop cursor when view is removed from window
        if newWindow == nil && window != nil {
            NSCursor.pop()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
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
}
