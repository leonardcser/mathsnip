#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
CoreML export script for MathSnip FormulaNet model.

This script converts the PyTorch FormulaNet model to CoreML format,
splitting it into encoder and decoder components for efficient inference.

Requirements:
- Run ./setup.sh first to clone Texo and download the model
- coremltools >= 8.0
- torch >= 2.0
- transformers >= 4.40

Usage:
    ./setup.sh  # First time only
    uv run python export_coreml.py [--output-dir OUTPUT_DIR] [--no-optimize]
"""

import argparse
import json
import sys
import warnings
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from torch.export import export, Dim

# Suppress tracer warnings
warnings.filterwarnings("ignore", category=torch.jit.TracerWarning)
warnings.filterwarnings("ignore", category=UserWarning, module="coremltools")

# Setup paths relative to this script
SCRIPT_DIR = Path(__file__).parent
TEXO_PATH = SCRIPT_DIR / "Texo"
MODEL_DIR = SCRIPT_DIR / "model_cache" / "FormulaNet"

# Check if setup has been run
if not TEXO_PATH.exists():
    print("Error: Texo not found. Run ./setup.sh first.")
    sys.exit(1)

if not MODEL_DIR.exists():
    print("Error: Model not found. Run ./setup.sh first.")
    sys.exit(1)

# Add Texo to path for custom model code
sys.path.insert(0, str(TEXO_PATH / "src"))

# Register custom model types with transformers
from transformers import AutoConfig, AutoModel
from texo.model.hgnet2 import HGNetv2, HGNetv2Config

AutoConfig.register("my_hgnetv2", HGNetv2Config)
AutoModel.register(HGNetv2Config, HGNetv2)

from transformers import VisionEncoderDecoderModel

# Image preprocessing constants
IMAGE_SIZE = 384
ENC_SEQ_LEN = 144  # (384/32)^2 after HGNetv2 downsampling


class EncoderWrapper(nn.Module):
    """Wrapper for the encoder + projection layer."""

    def __init__(self, encoder, enc_to_dec_proj):
        super().__init__()
        self.encoder = encoder
        self.enc_to_dec_proj = enc_to_dec_proj

    def forward(self, pixel_values):
        encoder_output = self.encoder(pixel_values).last_hidden_state
        projected = self.enc_to_dec_proj(encoder_output)
        return projected


class DecoderWrapper(nn.Module):
    """Wrapper for decoder that disables KV-cache for simpler export."""

    def __init__(self, decoder):
        super().__init__()
        self.decoder = decoder

    def forward(self, input_ids, encoder_hidden_states):
        outputs = self.decoder(
            input_ids=input_ids,
            encoder_hidden_states=encoder_hidden_states,
            past_key_values=None,
            use_cache=False,
            return_dict=True,
        )
        return outputs.logits


def load_model():
    """Load the FormulaNet model."""
    print("Loading model from", MODEL_DIR)
    model = VisionEncoderDecoderModel.from_pretrained(str(MODEL_DIR))
    model.eval()
    return model


def export_encoder(model, output_dir: Path):
    """Export encoder to CoreML using torch.jit.trace."""
    print("\n=== Exporting Encoder ===")

    encoder_wrapper = EncoderWrapper(model.encoder, model.enc_to_dec_proj)
    encoder_wrapper.eval()

    dummy_input = torch.randn(1, 3, IMAGE_SIZE, IMAGE_SIZE)

    print("Tracing encoder...")
    with torch.no_grad():
        traced_encoder = torch.jit.trace(encoder_wrapper, dummy_input)

    print("Converting to CoreML...")
    encoder_mlmodel = ct.convert(
        traced_encoder,
        inputs=[
            ct.TensorType(
                name="pixel_values",
                shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
                dtype=np.float32,
            )
        ],
        outputs=[ct.TensorType(name="encoder_output", dtype=np.float32)],
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )

    encoder_path = output_dir / "Encoder.mlpackage"
    print(f"Saving to {encoder_path}")
    encoder_mlmodel.save(str(encoder_path))

    return encoder_mlmodel


def export_decoder(model, output_dir: Path, max_seq_len: int = 512):
    """Export decoder to CoreML using torch.export for dynamic shapes."""
    print("\n=== Exporting Decoder ===")

    decoder_wrapper = DecoderWrapper(model.decoder)
    decoder_wrapper.eval()

    # Example inputs for export
    dummy_input_ids = torch.tensor([[0, 10, 20]], dtype=torch.long)
    dummy_encoder_output = torch.randn(1, ENC_SEQ_LEN, 384)

    print("Exporting decoder with torch.export...")
    seq_dim = Dim("sequence_length", min=1, max=max_seq_len)

    with torch.no_grad():
        exported = export(
            decoder_wrapper,
            (dummy_input_ids, dummy_encoder_output),
            dynamic_shapes={
                "input_ids": {1: seq_dim},
                "encoder_hidden_states": None,
            }
        )

    # Run decompositions as required by coremltools
    exported = exported.run_decompositions({})

    print("Converting to CoreML...")
    # IMPORTANT: Use FLOAT32 precision to avoid overflow in attention mask
    # The causal attention mask uses very large negative values that overflow
    # when cast to float16, causing NaN outputs.
    decoder_mlmodel = ct.convert(
        exported,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.macOS15,
    )

    decoder_path = output_dir / "Decoder.mlpackage"
    print(f"Saving to {decoder_path}")
    decoder_mlmodel.save(str(decoder_path))

    return decoder_mlmodel


def export_vocab(output_dir: Path):
    """Export vocabulary for Swift tokenizer."""
    print("\n=== Exporting Vocabulary ===")

    tokenizer_path = MODEL_DIR / "tokenizer.json"
    with open(tokenizer_path, "r") as f:
        tokenizer_data = json.load(f)

    vocab = tokenizer_data["model"]["vocab"]
    reverse_vocab = {str(v): k for k, v in vocab.items()}

    vocab_data = {
        "vocab": vocab,
        "reverse_vocab": reverse_vocab,
        "special_tokens": {
            "bos_token_id": 0,
            "pad_token_id": 1,
            "eos_token_id": 2,
            "unk_token_id": 3,
        },
        "vocab_size": len(vocab),
    }

    vocab_path = output_dir / "vocab.json"
    print(f"Saving vocabulary ({len(vocab)} tokens) to {vocab_path}")
    with open(vocab_path, "w") as f:
        json.dump(vocab_data, f, indent=2, ensure_ascii=False)

    return vocab_data


def validate_encoder(encoder_mlmodel, model):
    """Validate encoder CoreML output matches PyTorch."""
    print("\n=== Validating Encoder ===")

    test_input = torch.randn(1, 3, IMAGE_SIZE, IMAGE_SIZE)

    with torch.no_grad():
        encoder_wrapper = EncoderWrapper(model.encoder, model.enc_to_dec_proj)
        pytorch_output = encoder_wrapper(test_input).numpy()

    coreml_output = encoder_mlmodel.predict({"pixel_values": test_input.numpy()})[
        "encoder_output"
    ]

    max_diff = np.abs(pytorch_output - coreml_output).max()
    mean_diff = np.abs(pytorch_output - coreml_output).mean()

    print(f"  Max difference: {max_diff:.6f}")
    print(f"  Mean difference: {mean_diff:.6f}")

    if max_diff < 0.1:
        print("  Validation PASSED")
        return True
    else:
        print("  Validation FAILED - differences too large")
        return False


def validate_decoder(decoder_mlmodel, model):
    """Validate decoder CoreML output matches PyTorch."""
    print("\n=== Validating Decoder ===")

    test_input_ids = torch.tensor([[0, 129, 11, 150]], dtype=torch.long)
    test_encoder_output = torch.randn(1, ENC_SEQ_LEN, 384)

    with torch.no_grad():
        decoder_wrapper = DecoderWrapper(model.decoder)
        pytorch_output = decoder_wrapper(test_input_ids, test_encoder_output).numpy()

    # Find the output key (may vary)
    coreml_result = decoder_mlmodel.predict({
        "input_ids": test_input_ids.numpy().astype(np.int32),
        "encoder_hidden_states": test_encoder_output.numpy(),
    })

    # Get the logits output (key name may vary)
    coreml_output = list(coreml_result.values())[0]

    max_diff = np.abs(pytorch_output - coreml_output).max()
    mean_diff = np.abs(pytorch_output - coreml_output).mean()
    has_nan = np.isnan(coreml_output).any()

    print(f"  Max difference: {max_diff:.6f}")
    print(f"  Mean difference: {mean_diff:.6f}")
    print(f"  Has NaN: {has_nan}")

    if not has_nan and max_diff < 0.5:
        print("  Validation PASSED")
        return True
    else:
        print("  Validation FAILED")
        return False


def main():
    parser = argparse.ArgumentParser(description="Export FormulaNet to CoreML")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path(__file__).parent.parent.parent / "models",
        help="Output directory for CoreML models",
    )
    parser.add_argument(
        "--validate",
        action="store_true",
        help="Validate CoreML output against PyTorch",
    )
    args = parser.parse_args()

    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Output directory: {output_dir}")
    print(f"PyTorch version: {torch.__version__}")
    print(f"CoreMLTools version: {ct.__version__}")

    # Load model
    model = load_model()

    # Export components
    encoder_mlmodel = export_encoder(model, output_dir)
    decoder_mlmodel = export_decoder(model, output_dir)
    export_vocab(output_dir)

    # Validate
    if args.validate:
        validate_encoder(encoder_mlmodel, model)
        validate_decoder(decoder_mlmodel, model)

    print("\n=== Export Complete ===")
    print(f"Models saved to: {output_dir}")
    print("\nFiles created:")
    for f in sorted(output_dir.iterdir()):
        if f.is_file():
            size = f.stat().st_size / 1024 / 1024
            print(f"  {f.name}: {size:.2f} MB")
        elif f.is_dir() and f.suffix == ".mlpackage":
            total = sum(p.stat().st_size for p in f.rglob("*") if p.is_file())
            size = total / 1024 / 1024
            print(f"  {f.name}: {size:.2f} MB")


if __name__ == "__main__":
    main()
