# MathSnip

A macOS menu bar app that captures mathematical equations from the screen and converts them to LaTeX.

## Requirements

- macOS 13.0 or later
- Swift compiler
- `pix2tex` installed on your system (for equation-to-LaTeX conversion)

## Build

```bash
./build.sh
```

This creates `MathSnip.app` in the current directory.

## Usage

1. Run the app - it appears as a menu bar icon
2. Click the menu bar icon to start equation capture
3. Click and drag to select the equation area on screen
4. The LaTeX conversion is copied to your clipboard automatically

## Permissions

On first run, macOS will prompt you to allow screen recording access. Grant permission for the app to function properly.
