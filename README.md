# MathSnip

<p align="center">
    <img src="assets/preview.png" width=512></img>
</p>

A macOS menu bar app frontend for converting mathematical equations into
different formats (LaTeX and Typst).

## Requirements

- macOS 13.0 or later
- Swift compiler
- LaTeX backend (see **Backends** section below)

## Setup

```bash
./build.sh
```

This creates `MathSnip.app` in the current directory.

To install the application run:

```bash
cp -R MathSnip.app /Applications/
```

## Usage

1. Run the app - it appears as a menu bar icon
2. Click the menu bar icon to start equation capture
3. Click and drag to select the equation area on screen
4. The LaTeX conversion is copied to your clipboard automatically

## Permissions

MathSnip requires two macOS permissions to function:

### Accessibility Permission

Required for the snipping overlay to capture mouse and keyboard events. Without
this permission, the overlay cannot detect your selection.

### Screen Recording Permission

Required to capture the selected area of the screen. Without this permission,
the app cannot capture the equation image.

On first use, the app will check for these permissions and prompt you to grant
them if missing. You can also manually enable them in:

- **System Settings → Privacy & Security → Accessibility** - Add MathSnip
- **System Settings → Privacy & Security → Screen Recording** - Add MathSnip

**Note:** If you move or copy the app (e.g., to `/Applications`), macOS treats
it as a new application and you'll need to re-grant permissions. Remove the old
entry from the permission lists and add the app again from its new location.

## Backends

| Backend            | License | Quality   | Setup                     |
| ------------------ | ------- | --------- | ------------------------- |
| **Texo** (default) | AGPL    | Excellent | `./scripts/setup_texo.sh` |
| **pix2tex**        | MIT     | Good      | `uv tool install pix2tex` |

To use **pix2tex**, change `let activeBackend: LaTeXBackend = .texo` to
`.pix2tex` in `AppDelegate.swift` and rebuild.

Note: Using Texo subjects your use to AGPL-3.0.

## License

MIT License, except `scripts/inference_texo.py` which is AGPL-3.0 (it imports
from [Texo](https://github.com/alephpi/Texo), an AGPL project).
