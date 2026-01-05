#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="MathSnip"
APP_BUNDLE="${APP_NAME}.app"

# Clean previous build
rm -rf "${APP_BUNDLE}"

# Create app bundle structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy icons
cp assets/icon.png "${APP_BUNDLE}/Contents/Resources/"
cp assets/icon@2x.png "${APP_BUNDLE}/Contents/Resources/"
cp assets/AppIcon.icns "${APP_BUNDLE}/Contents/Resources/"

# Compile Swift code
swiftc -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    -framework Cocoa \
    -framework ScreenCaptureKit \
    -framework WebKit \
    main.swift \
    AppDelegate.swift \
    OverlayPanel.swift \
    PreviewPanel.swift

# Copy Info.plist
cp Info.plist "${APP_BUNDLE}/Contents/"

echo "Build complete: ./${APP_BUNDLE}"
