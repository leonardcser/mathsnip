#!/bin/bash
#
# Setup script for MathSnip Texo backend
# Creates a Python virtual environment with required dependencies using uv
#

set -e

MATHSNIP_DIR="$HOME/.mathsnip/backends/texo"
VENV_DIR="$MATHSNIP_DIR/venv"
TEXO_DIR="$MATHSNIP_DIR/Texo"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Fixed commit hash for reproducibility
TEXO_COMMIT="a462c537a9726545d2bcfb639c9f99224d1e36c2"

echo "Setting up MathSnip Texo backend..."

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "Error: uv is not installed."
    echo "Install it with: curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "Or: brew install uv"
    exit 1
fi

# Create mathsnip directory
mkdir -p "$MATHSNIP_DIR"

# Clone Texo repository (required for custom model code)
if [ -d "$TEXO_DIR" ]; then
    echo "Texo already exists at $TEXO_DIR"
else
    echo "Fetching Texo repository (commit $TEXO_COMMIT, shallow)..."
    mkdir -p "$TEXO_DIR"
    cd "$TEXO_DIR"
    git init
    git remote add origin https://github.com/alephpi/Texo.git
    git fetch --depth 1 origin "$TEXO_COMMIT"
    git checkout FETCH_HEAD
fi

# Create virtual environment with uv (Texo requires Python >= 3.11)
echo "Creating virtual environment at $VENV_DIR..."
uv venv "$VENV_DIR" --python 3.12

# Install dependencies manually (Texo's pyproject.toml requires onnxruntime-gpu which isn't available on macOS)
# Versions from Texo pyproject.toml
echo "Installing dependencies (this may take a while on first run)..."

# Detect architecture - PyTorch 2.3+ dropped Intel Mac support
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    echo "Detected Intel Mac (x86_64) - using PyTorch 2.2.2 (last version with Intel Mac support)"
    TORCH_VERSION="torch==2.2.2"
    TORCHVISION_VERSION="torchvision==0.17.2"
else
    echo "Detected Apple Silicon ($ARCH) - using PyTorch 2.7.0"
    TORCH_VERSION="torch==2.7.0"
    TORCHVISION_VERSION="torchvision>=0.20.1"
fi

uv pip install --python "$VENV_DIR/bin/python" \
    "$TORCH_VERSION" \
    "$TORCHVISION_VERSION" \
    "transformers==4.40.0" \
    "pillow>=11.1.0" \
    huggingface_hub \
    "albumentations>=2.0.2" \
    "opencv-python>=4.10.0.84" \
    "ftfy>=6.3.1" \
    "rapidfuzz>=3.13.0" \
    "lightning>=2.5.3" \
    "datasets==4.0.0" \
    "evaluate>=0.4.5" \
    "rich>=10.2.2"

# Copy inference script
echo "Installing inference script..."
cp "$SCRIPT_DIR/inference.py" "$MATHSNIP_DIR/inference.py"

# Pre-download the model
echo ""
echo "Downloading model..."
"$VENV_DIR/bin/python" -c "
import sys
sys.path.insert(0, '$TEXO_DIR')
from pathlib import Path
from huggingface_hub import snapshot_download

cache_dir = Path.home() / '.mathsnip' / 'backends' / 'texo' / 'model_cache'
cache_dir.mkdir(parents=True, exist_ok=True)

print('Downloading FormulaNet model...')
snapshot_download(
    repo_id='alephpi/FormulaNet',
    local_dir=cache_dir / 'FormulaNet',
    local_dir_use_symlinks=False
)
print('Done!')
"

echo ""
echo "Setup complete!"
echo "MathSnip Texo backend is now ready to use."
echo ""
echo "Files installed:"
echo "  - $VENV_DIR (Python environment)"
echo "  - $TEXO_DIR (Texo source code)"
echo "  - $MATHSNIP_DIR/inference.py (inference script)"
