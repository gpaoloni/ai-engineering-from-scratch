#!/usr/bin/env bash
set -euo pipefail

echo "────────────────────────────────────────────────────────────────"
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
  echo "GPU: NVIDIA GPU detected and visible to this container."
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
elif [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
  echo "GPU: arm64 host (e.g. Apple Silicon) — no GPU passed through."
  echo "     Metal/MPS cannot be passed into a Linux container on macOS;"
  echo "     this is a virtualization-boundary limit, not a missing flag."
  echo "     PyTorch will run on CPU in here. For Metal (MPS)"
  echo "     acceleration, run the code natively on macOS with uv,"
  echo "     outside Docker, instead."
else
  echo "GPU: no NVIDIA GPU detected. PyTorch will run on CPU."
  echo "     (Rebuild with --build-arg TORCH_INDEX_URL=.../cu124 and"
  echo "     run with --gpus all if this host does have an NVIDIA GPU"
  echo "     with the NVIDIA Container Toolkit installed.)"
fi
echo "────────────────────────────────────────────────────────────────"

exec "$@"
