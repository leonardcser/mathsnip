# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

MathSnip is a macOS menu bar application that converts mathematical equations to LaTeX and Typst formats using image recognition. It captures equation images from the screen and processes them through pluggable ML backends.

## Building and Running

### Build
```bash
./build.sh
```

Creates `MathSnip.app` in the current directory.

### Install
```bash
cp -R MathSnip.app /Applications/
```

### Run
Click the MathSnip menu bar icon to start snipping, or right-click for the context menu.

## Architecture

### Core Components

**AppDelegate.swift** - Main application controller
- Status bar menu management
- Snipping flow orchestration (`startSnipping()` → `handleSelection()` → `captureAndProcess()`)
- Backend abstraction and switching between pix2tex and Texo
- Texo daemon lifecycle management (non-blocking startup, socket-based communication)
- Permission checking (Accessibility, Screen Recording)
- Screenshot capture using ScreenCaptureKit with scaling and cropping

**OverlayPanel.swift & OverlayView.swift** - Full-screen selection overlay
- CGEvent tap for capturing mouse/keyboard events during snipping
- Event tap requires Accessibility permission
- Coordinate conversion between CG (origin top-left) and NS (origin bottom-left) systems
- Selection visualization (semi-transparent overlay, white border, crosshair)
- Minimum selection size check (10×10 pixels)

**PreviewPanel.swift** - LaTeX/Typst preview window
- Floating panel below menu bar icon
- Uses WebKit to render math with KaTeX
- Includes tex2typst.js for format conversion between LaTeX and Typst
- Dynamically loads bundle resources to temp directory for security
- Dismisses on click outside

### Backend System

Two ML backends for equation recognition:

**Texo** (default)
- Better accuracy, uses FormulaNet model
- Persistent daemon for performance
- Socket-based IPC (`/tmp/mathsnip_texo.sock`)
- Non-blocking startup: daemon boots in background, waits for "READY" signal on stdout
- Falls back to single-shot inference if daemon unavailable
- Setup via `./scripts/setup_texo.sh`

**pix2tex**
- Lightweight, fast
- External tool: `pix2tex [image]`
- Paths searched: `~/.local/bin/pix2tex`, `/usr/local/bin/pix2tex`, `/opt/homebrew/bin/pix2tex`
- Output format: `"filepath: latex_result"` (parser extracts after colon)

Backend is set via `let activeBackend: LaTeXBackend` in AppDelegate.swift:13

### Texo Daemon Details

When `activeBackend = .texo`:
- App starts daemon in background on launch without blocking
- Python script `scripts/inference_texo.py` runs with `--server` flag
- App waits for daemon readiness only when snipping (max 120s timeout)
- Daemon monitors via `texoDaemonReady` flag and condition variable
- Socket connection sends image path, receives LaTeX
- Automatic cleanup of stale socket/PID files on restart

## Key Development Notes

### Threading
- Event handling in CGEvent tap runs on system event thread (must not block)
- Main UI updates dispatched to main thread via `DispatchQueue.main.async`
- Asynchronous capture/processing via Task/async-await

### Coordinate Systems
- CG coordinates: origin top-left, Y increases downward
- NS coordinates: origin bottom-left, Y increases upward
- OverlayView converts between systems in `viewPointFromScreenPoint()`
- Screenshot scaling accounts for Retina displays via `backingScaleFactor`

### Screen Capture
- Uses ScreenCaptureKit (macOS 13.2+)
- Captures full display, then crops to selection rect
- Scaling applied based on display backing scale factor
- Temporary PNG files cleaned up after processing

### Permissions
- Accessibility: required for event tap
- Screen Recording: required for ScreenCaptureKit
- App prompts user and opens System Settings if missing
- Note: macOS treats app in different locations as separate, requiring re-grant

### Preview Panel
- Resources (CSS, JS, fonts) embedded in app bundle
- Copies to temp cache directory on each preview for security
- KaTeX renders LaTeX, tex2typst converts to Typst
- Dismisses on any click outside via local/global event monitors

## Asset Organization

- `assets/icon.png` & `icon@2x.png` - Menu bar icons
- `assets/AppIcon.icns` - App icon
- `assets/preview.html` - Preview panel template (has `{{LATEX}}` placeholder)
- `assets/katex.min.css` & `katex.min.js` - Math rendering
- `assets/tex2typst.min.js` - LaTeX to Typst conversion
- `assets/fonts/` - KaTeX fonts

## Common Tasks

### Switch Backend
Edit `AppDelegate.swift:13`: change `activeBackend` to `.pix2tex` or `.texo`

### Add New Backend
1. Add case to `LaTeXBackend` enum (AppDelegate.swift:7)
2. Implement backend check in `startSnipping()` (AppDelegate.swift:499)
3. Implement run function and call from `captureAndProcess()` (AppDelegate.swift:561)
4. Add permission/setup checks

### Modify Overlay Appearance
Edit `OverlayView.draw()` method (OverlayPanel.swift:249)
- Colors, transparency, border style
- Crosshair rendering

### Update Preview Format
Edit `assets/preview.html` template and ensure resources are copied in `PreviewPanel.showBelow()` (PreviewPanel.swift:92)

## Dependencies

- **macOS SDK**: Cocoa, ScreenCaptureKit, WebKit, ApplicationServices
- **Swift**: No external package manager (single-file compilation)
- **Backends**: pix2tex (pip), Texo (setup_texo.sh with uv)

## License

MIT except `scripts/inference_texo.py` which is AGPL-3.0 (imports Texo)
