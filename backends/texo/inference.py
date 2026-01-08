#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 Leonard
#
# This file is licensed under AGPL-3.0 because it imports from Texo
# (https://github.com/alephpi/Texo), which is AGPL-licensed.
# The rest of MathSnip is MIT-licensed.
"""
Texo inference server for MathSnip.
Keeps the FormulaNet model loaded in memory and accepts inference requests via Unix socket.
"""

import sys
import os
import socket
import signal
from pathlib import Path

# Add Texo to path for custom model code
BACKEND_DIR = Path.home() / ".mathsnip" / "backends" / "texo"
TEXO_PATH = BACKEND_DIR / "Texo"
sys.path.insert(0, str(TEXO_PATH / "src"))

# Register custom model types with transformers BEFORE importing VisionEncoderDecoderModel
from transformers import AutoConfig, AutoModel
from texo.model.hgnet2 import HGNetv2, HGNetv2Config

AutoConfig.register("my_hgnetv2", HGNetv2Config)
AutoModel.register(HGNetv2Config, HGNetv2)

from PIL import Image
from transformers import AutoTokenizer, VisionEncoderDecoderModel
from texo.data.processor.image_processor import EvalMERImageProcessor
import torch


MODEL_DIR = BACKEND_DIR / "model_cache" / "FormulaNet"
SOCKET_PATH = "/tmp/mathsnip_texo.sock"
PID_FILE = "/tmp/mathsnip_texo.pid"


def load_model():
    """Load the FormulaNet model and tokenizer."""
    print("Loading model...", file=sys.stderr, flush=True)

    model = VisionEncoderDecoderModel.from_pretrained(str(MODEL_DIR))
    tokenizer = AutoTokenizer.from_pretrained(str(MODEL_DIR))
    image_processor = EvalMERImageProcessor(image_size={'height': 384, 'width': 384})

    # Use MPS if available (Apple Silicon), otherwise CPU
    if torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")

    model = model.to(device)
    model.eval()

    # Compile model for faster inference (PyTorch 2.0+)
    # Use reduce-overhead mode for repeated inference on similar inputs
    print("Compiling model with torch.compile...", file=sys.stderr, flush=True)
    try:
        model = torch.compile(model, mode="reduce-overhead")
        print("Model compiled successfully", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"torch.compile failed (will use eager mode): {e}", file=sys.stderr, flush=True)

    print(f"Model loaded on {device}", file=sys.stderr, flush=True)
    return model, tokenizer, image_processor, device


def format_latex(latex: str) -> str:
    r"""
    Format LaTeX string by removing unnecessary spaces.
    Matches the logic from texo-web's formatLatex function.

    Rules:
    - Remove all spaces between tokens
    - Only add space after LaTeX commands (starting with \) when followed by alphanumeric
    - Add newline after \\
    """
    if not latex:
        return ""

    # Split by whitespace to get tokens
    tokens = latex.split()
    if not tokens:
        return ""

    new_tokens = []
    for i in range(len(tokens) - 1):
        token = tokens[i]
        next_token = tokens[i + 1]
        new_tokens.append(token)

        if token == '\\\\':
            # Add newline after line break
            new_tokens.append('\n')
        elif token.startswith('\\') and next_token and next_token[0].isalnum():
            # Add space after LaTeX command if followed by alphanumeric
            new_tokens.append(' ')

    # Add the last token
    new_tokens.append(tokens[-1])

    return ''.join(new_tokens)


def inference(image_path: str, model, tokenizer, image_processor, device) -> str:
    """Run inference on an image and return LaTeX string."""
    image = Image.open(image_path).convert("RGB")

    # Process image using Texo's processor (returns tensor directly)
    pixel_values = image_processor(image).unsqueeze(0).to(device)

    with torch.no_grad():
        generated_ids = model.generate(
            pixel_values,
            max_length=512,
            num_beams=4,
            early_stopping=True
        )

    latex = tokenizer.decode(generated_ids[0], skip_special_tokens=True)

    # Format LaTeX to remove unnecessary spaces
    latex = format_latex(latex)

    return latex


def cleanup():
    """Remove socket and PID files."""
    try:
        os.unlink(SOCKET_PATH)
    except OSError:
        pass
    try:
        os.unlink(PID_FILE)
    except OSError:
        pass


def signal_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    print(f"Received signal {signum}, shutting down...", file=sys.stderr, flush=True)
    cleanup()
    sys.exit(0)


def run_server():
    """Run the inference server."""
    # Set up signal handlers
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    # Clean up any stale socket
    cleanup()

    # Write PID file
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))

    # Load model once at startup
    model, tokenizer, image_processor, device = load_model()

    # Warm up the model with a dummy inference to trigger compilation
    print("Warming up model...", file=sys.stderr, flush=True)
    try:
        dummy_image = Image.new('RGB', (384, 384), color='white')
        pixel_values = image_processor(dummy_image).unsqueeze(0).to(device)
        with torch.no_grad():
            _ = model.generate(pixel_values, max_length=10)
        print("Warmup complete", file=sys.stderr, flush=True)
    except Exception as e:
        print(f"Warmup failed: {e}", file=sys.stderr, flush=True)

    # Create Unix socket
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(1)

    # Signal that we're ready
    print("READY", flush=True)

    print(f"Server listening on {SOCKET_PATH}", file=sys.stderr, flush=True)

    try:
        while True:
            conn, _ = server.accept()
            try:
                # Receive image path
                data = conn.recv(4096)
                if not data:
                    continue

                image_path = data.decode('utf-8').strip()

                if not Path(image_path).exists():
                    conn.sendall(b"ERROR: Image not found")
                    continue

                # Run inference
                latex = inference(image_path, model, tokenizer, image_processor, device)
                conn.sendall(latex.encode('utf-8'))

            except Exception as e:
                error_msg = f"ERROR: {str(e)}"
                print(error_msg, file=sys.stderr, flush=True)
                try:
                    conn.sendall(error_msg.encode('utf-8'))
                except:
                    pass
            finally:
                conn.close()
    finally:
        cleanup()


def main():
    """Entry point - run as server or single inference based on args."""
    if len(sys.argv) == 2 and sys.argv[1] == "--server":
        run_server()
    elif len(sys.argv) == 2:
        # Legacy single-shot mode for compatibility
        image_path = sys.argv[1]
        if not Path(image_path).exists():
            print(f"Error: Image not found: {image_path}", file=sys.stderr)
            sys.exit(1)
        model, tokenizer, image_processor, device = load_model()
        latex = inference(image_path, model, tokenizer, image_processor, device)
        print(latex)
    else:
        print("Usage: inference.py --server  (daemon mode)", file=sys.stderr)
        print("       inference.py <image_path>  (single inference)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
