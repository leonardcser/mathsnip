# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MathSnip is a macOS menu bar app that captures mathematical equations from the screen and converts them to LaTeX. The app uses a snipping overlay (similar to macOS screenshot tool) to let users select an equation area, then uses `pix2tex` (Python package) to perform OCR on the image and convert it to LaTeX, which is copied to the clipboard. A preview panel displays the rendered equation using KaTeX.

## Build Commands

```bash
# Build the app (creates MathSnip.app in current directory)
./build.sh
```

The build script:
- Compiles all Swift files using `swiftc` with Cocoa, ScreenCaptureKit, and WebKit frameworks
- Creates macOS app bundle structure
- Copies icon assets and preview HTML/CSS/JS/fonts to Resources
- Produces a standalone `.app` that can be run directly

## Runtime Dependencies

The app requires external tools to be installed:
- `pix2tex` - Python package for equation OCR (`pip install pix2tex`)
  - Searched in: `~/.local/bin/pix2tex`, `/usr/local/bin/pix2tex`, `/opt/homebrew/bin/pix2tex`
- `katex` - For LaTeX rendering in preview (bundled in assets, no runtime dependency)

## Architecture

### Component Overview

The app consists of 4 main Swift files:

1. **main.swift** - Entry point, sets app activation policy to `.accessory` (menu bar app, no dock icon)

2. **AppDelegate.swift** - Core application logic
   - Manages menu bar status item and menu
   - Permission checks (Accessibility + Screen Recording required)
   - Orchestrates snipping flow: overlay → capture → pix2tex → preview
   - Icon state management (normal/loading)
   - Screen capture using ScreenCaptureKit API
   - Process management for pix2tex execution

3. **OverlayPanel.swift** - Fullscreen snipping interface
   - Window level `.screenSaver` to cover menubar
   - CGEvent tap to intercept all mouse/keyboard events (requires Accessibility permission)
   - Crosshair cursor + selection rectangle UI
   - Coordinate system conversion: CG coords (top-left origin) ↔ NS coords (bottom-left origin)
   - ESC key cancels snipping

4. **PreviewPanel.swift** - LaTeX preview popup
   - WKWebView-based panel positioned below menu bar icon
   - Loads HTML template with KaTeX, injects captured LaTeX
   - Copies resources (CSS/JS/fonts) to cache directory for WebKit file access
   - Auto-dismisses on click outside

### Key Workflows

**Snipping Flow:**
1. User clicks menu bar icon → `AppDelegate.startSnipping()`
2. Check pix2tex installed → Check permissions (Accessibility + Screen Recording)
3. Create `OverlayPanel` with CGEvent tap
4. User drags selection → `handleSelection()` called with NSRect
5. Hide overlay → `captureScreenRegion()` using ScreenCaptureKit
6. Crop to selection, save PNG to temp
7. Run `pix2tex <imagepath>`, parse output (format: "path: latex_result")
8. Copy LaTeX to clipboard
9. Show `PreviewPanel` with rendered equation

**Coordinate System Handling:**
- CGEvent/ScreenCaptureKit use CG coordinates (origin top-left, Y down)
- NSWindow/NSView use NS coordinates (origin bottom-left, Y up)
- `OverlayPanel` converts between systems when handling events
- Screen capture crops using CG coordinates with proper Y-axis inversion

**Preview Rendering:**
- HTML template at `assets/preview.html` has `{{LATEX}}` placeholder
- Swift escapes LaTeX string for JavaScript (backslashes, quotes, newlines)
- Template + KaTeX assets copied to cache directory
- WebView loads from file URL with read access to cache dir
- Auto-scales rendered equation to fit panel dimensions

## Important Implementation Details

### Permission Requirements
Both macOS permissions are strictly required and checked before snipping:
- **Accessibility**: Required for CGEvent tap to intercept mouse/keyboard
- **Screen Recording**: Required for ScreenCaptureKit to capture screen region
- Moving the app to a new location (e.g., to `/Applications`) invalidates permissions

### Event Tap Behavior
- Event tap can be disabled by system if callback takes too long
- Code handles `.tapDisabledByTimeout` by re-enabling tap
- All events consumed during snipping to prevent interference with other apps

### Window Level Configuration
- Overlay must be configured (`configureForOverlay()`) BEFORE showing
- This ensures window covers menubar from first frame (prevents flicker)

### Asset Management
- Icons loaded from bundle: `icon.png`, `icon@2x.png`, `AppIcon.icns`
- Preview assets: `preview.html`, `katex.min.css`, `katex.min.js`, `fonts/` directory
- All assets must be in app bundle's Resources directory after build
