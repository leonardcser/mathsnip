# MathSnip

<p align="center">
    <img src="assets/preview.png" width=512></img>
</p>

A macOS menu bar app frontend for converting mathematical equations into
different formats (LaTeX and Typst).

## Requirements

- macOS 14.0 or later
- Swift compiler
- LaTeX backend (see **Backends** section below)

## Installation

### Download Pre-built Release

Download the latest release for your architecture from the
[releases page](https://github.com/leonardcser/mathsnip/releases):

- `MathSnip-arm64.zip` for Apple Silicon Macs
- `MathSnip-x86_64.zip` for Intel Macs

Extract the zip and move `MathSnip.app` to your Applications folder.

**Note:** If macOS shows a "damaged app" warning, run this command in Terminal:

```bash
xattr -cr /Applications/MathSnip.app
```

### Build from Source

Clone the repository and build using the Makefile:

```bash
git clone https://github.com/leonardcser/mathsnip.git
cd mathsnip
make setup    # First time only - set up backend
make install  # Build and install to /Applications
```

### Advanced Usage

```bash
# Build with a different backend
make BACKEND=texo install
make BACKEND=pix2tex install

# Clean build artifacts
make clean

# Show all available commands
make help
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

| Backend                   | Quality   | Speed  | Setup                          |
| ------------------------- | --------- | ------ | ------------------------------ |
| **Texo-CoreML** (default) | Excellent | Fast   | `make install`                 |
| **Texo**                  | Excellent | Medium | `make BACKEND=texo install`    |
| **pix2tex**               | Fair      | Fast   | `make BACKEND=pix2tex install` |

The default backend is **Texo-CoreML**, which provides the best accuracy using
on-device inference via Apple's CoreML framework.

To switch backends, use the `BACKEND` variable with make:

```bash
make BACKEND=texo install        # Use Texo
make BACKEND=pix2tex install     # Use pix2tex
```

You can also change the default by editing the `BACKEND` variable at the top of
the `Makefile`.

**Note:** Using the Texo backend (not Texo-CoreML) subjects your use to AGPL-3.0
license terms.

## Acknowledgments

MathSnip uses [Texo](https://github.com/alephpi/Texo) for mathematical equation
recognition via the FormulaNet model.

## License

MIT License, except the following files which are AGPL-3.0 (they import from or
are derived from [Texo](https://github.com/alephpi/Texo), an AGPL project):

- `backends/texo/inference.py`
- `backends/texo-coreml/CoreMLInference.swift`
- `backends/texo-coreml/MathSnipTokenizer.swift`
