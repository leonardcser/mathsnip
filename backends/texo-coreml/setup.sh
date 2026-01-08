#!/bin/bash
# Setup script for CoreML export environment
# This is independent from setup_texo.sh - it only sets up what's needed for export

set -e
cd "$(dirname "$0")"

TEXO_DIR="Texo"
MODEL_CACHE_DIR="model_cache"

echo "=== Setting up CoreML export environment ==="

# Clone Texo if not present (shallow clone for speed)
if [ ! -d "$TEXO_DIR" ]; then
    echo "Cloning Texo repository (shallow)..."
    git clone --depth 1 https://github.com/alephpi/Texo.git "$TEXO_DIR"
else
    echo "Texo directory already exists, skipping clone"
fi

# Create model cache directory
mkdir -p "$MODEL_CACHE_DIR"

# Check if model is already downloaded
if [ ! -d "$MODEL_CACHE_DIR/FormulaNet" ]; then
    echo "Downloading FormulaNet model from HuggingFace..."
    # Use huggingface-cli if available, otherwise use Python
    if command -v huggingface-cli &> /dev/null; then
        huggingface-cli download alephpi/FormulaNet --local-dir "$MODEL_CACHE_DIR/FormulaNet"
    else
        echo "Downloading via Python..."
        uv run python -c "
from huggingface_hub import snapshot_download
snapshot_download('alephpi/FormulaNet', local_dir='$MODEL_CACHE_DIR/FormulaNet')
"
    fi
else
    echo "FormulaNet model already downloaded"
fi

# Sync dependencies
echo "Syncing Python dependencies..."
uv sync

# Export CoreML models
echo ""
echo "Exporting CoreML models..."
uv run python export_coreml.py

echo ""
echo "=== Setup complete ==="
echo "CoreML models have been exported to ../../models/"
