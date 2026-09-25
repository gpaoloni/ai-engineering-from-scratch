# syntax=docker/dockerfile:1.7
###############################################################################
# ai-engineering-from-scratch — secure, multi-language learning environment
#
# Python via uv (uv-managed Python 3.12, uv-managed venv, uv pip installs)
# Node via nvm (pinned to Node 24)
# Rust via rustup (pinned version)
#
# Build (run from inside a clone of the repo, next to this Dockerfile):
#   git clone https://github.com/rohitg00/ai-engineering-from-scratch.git
#   cp Dockerfile docker-compose.yml .dockerignore entrypoint.sh ai-engineering-from-scratch/
#   cd ai-engineering-from-scratch
#   docker compose build
#
# Run:
#   docker compose run --rm aiefs
#
# GPU note (read before building on Apple Silicon): see the GPU section
# near the bottom of this file and DOCKER_README.md. Short version — on a
# Mac, this Linux container cannot reach the Metal/MPS GPU no matter how
# this Dockerfile is written; that's a virtualization boundary, not a
# missing flag. CUDA only applies on Linux/Windows hosts with an NVIDIA GPU.
###############################################################################

ARG DEBIAN_VERSION=bookworm-slim
ARG RUST_VERSION=1.82.0
ARG NODE_VERSION=24
ARG UID=1000
ARG GID=1000

FROM debian:${DEBIAN_VERSION} AS base
SHELL ["/bin/bash", "-c"]

# ---------------------------------------------------------------------------
# OS packages: minimal set, pinned, no recommended extras, apt cache purged
# in the same layer so it never ends up in an image layer. Neither Python
# nor Node come from apt anymore — uv and nvm manage those, pinned below.
# ---------------------------------------------------------------------------
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  build-essential \
  pkg-config \
  libssl-dev \
  tini \
  ; \
  rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Non-root user. Everything from here runs as this user, never root.
# ---------------------------------------------------------------------------
ARG UID
ARG GID
RUN groupadd --gid "${GID}" learner \
  && useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash learner

USER learner
WORKDIR /home/learner/app

# ---------------------------------------------------------------------------
# uv + Python 3.12 (uv installs and manages its own standalone Python build,
# so no system python3/pip/venv package is needed at all).
# ---------------------------------------------------------------------------
ENV PATH="/home/learner/.local/bin:$PATH"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

RUN uv python install 3.12

# uv-managed virtualenv, created inside the project directory, same as the
# `uv venv` / `source .venv/bin/activate` workflow you'd run by hand.
RUN uv venv --python 3.12 .venv
ENV VIRTUAL_ENV=/home/learner/app/.venv \
  PATH=/home/learner/app/.venv/bin:$PATH

COPY --chown=learner:learner requirements.txt ./
RUN uv pip install -r requirements.txt

# ---------------------------------------------------------------------------
# GPU / PyTorch (see the long comment near the bottom of this file).
#
# Default build = the plain PyPI build (works everywhere, includes Apple's
# MPS backend in the wheel itself — irrelevant here since a Linux container
# can't reach Metal, but harmless).
#
# On a Linux host with an NVIDIA GPU, rebuild with:
#   docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu124
# ---------------------------------------------------------------------------
ARG TORCH_INDEX_URL=""
RUN if [ -n "${TORCH_INDEX_URL}" ]; then \
  uv pip install torch torchvision torchaudio --index-url "${TORCH_INDEX_URL}"; \
  else \
  uv pip install torch torchvision torchaudio; \
  fi

# ---------------------------------------------------------------------------
# Node.js via nvm, pinned to a single major version. nvm itself is a shell
# function, not a binary, so we source nvm.sh once per RUN and then expose
# the installed version through a stable "current" symlink so later layers
# and the running container just need it on PATH — no sourcing required.
# ---------------------------------------------------------------------------
ENV NVM_DIR="/home/learner/.nvm"
ARG NODE_VERSION
RUN mkdir -p "$NVM_DIR" \
  && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh | bash \
  && . "$NVM_DIR/nvm.sh" \
  && nvm install "${NODE_VERSION}" \
  && nvm alias default "${NODE_VERSION}" \
  && ln -sfn "$NVM_DIR/versions/node/$(nvm version "${NODE_VERSION}")" "$NVM_DIR/current"
ENV PATH="$NVM_DIR/current/bin:$PATH"
RUN node --version && npm --version

# ---------------------------------------------------------------------------
# Rust — installed via rustup, minimal profile, pinned version (not
# "stable", so the image is reproducible).
# ---------------------------------------------------------------------------
ENV RUSTUP_HOME=/home/learner/.rustup \
  CARGO_HOME=/home/learner/.cargo \
  PATH=/home/learner/.cargo/bin:$PATH
ARG RUST_VERSION
RUN set -eux; \
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup-init.sh; \
  chmod +x /tmp/rustup-init.sh; \
  /tmp/rustup-init.sh -y \
  --default-toolchain "${RUST_VERSION}" \
  --profile minimal \
  --no-modify-path; \
  rm -f /tmp/rustup-init.sh; \
  rustup component add clippy rustfmt

# ---------------------------------------------------------------------------
# Repository source.
# ---------------------------------------------------------------------------
COPY --chown=learner:learner . .

# ---------------------------------------------------------------------------
# Node dependencies for whichever parts of the repo ship a package.json
# (web/, api/, scripts/, or the repo root). Skipped where none exists.
# ---------------------------------------------------------------------------
# RUN set -eux; \
#     for d in . web api scripts; do \
#         if [ -f "$d/package-lock.json" ]; then \
#             (cd "$d" && npm ci --no-audit --no-fund); \
#         elif [ -f "$d/package.json" ]; then \
#             (cd "$d" && npm install --no-audit --no-fund); \
#         fi; \
#     done

# ---------------------------------------------------------------------------
# Entrypoint: reports what compute this container actually has access to
# (NVIDIA GPU, "Apple Silicon but no passthrough", or CPU-only) before
# dropping you into a shell — see entrypoint.sh.
# ---------------------------------------------------------------------------
COPY --chown=learner:learner entrypoint.sh /home/learner/entrypoint.sh
RUN chmod +x /home/learner/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/home/learner/entrypoint.sh"]
CMD ["bash"]

###############################################################################
# GPU support — read this before you build
#
# NVIDIA (Linux / Windows host):
#   1. Install the NVIDIA driver + NVIDIA Container Toolkit on the HOST
#      (not in this image).
#   2. Build with the CUDA wheel index:
#        docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu124
#   3. Run with the GPU attached — either `docker run --gpus all ...` or the
#      commented `deploy.resources.reservations.devices` block in
#      docker-compose.yml.
#   4. Verify inside the container: `nvidia-smi` and
#      `python3 -c "import torch; print(torch.cuda.is_available())"`.
#
# Apple Silicon (M1-M5) host, running this Linux container via Docker
# Desktop/OrbStack/similar:
#   There is no CUDA here — CUDA is NVIDIA-only and never applies on a Mac,
#   containerized or not.
#   There is also no Metal/MPS passthrough into a Linux container. Every
#   container runtime on macOS (Docker Desktop, Podman, OrbStack, Lima) runs
#   your containers inside a Linux VM, and Linux has no Metal driver, so the
#   GPU simply is not a device this container can see — this is a
#   virtualization-boundary limitation, not a missing package or flag, and
#   it holds true as of 2026 (Docker's own Model Runner works around it by
#   running its Metal-accelerated backend as a *native macOS process*
#   outside the Linux VM, rather than inside a container).
#   Practically: `torch.backends.mps.is_available()` will report False
#   inside this container even though it would report True if you ran the
#   identical Python natively on the same Mac. PyTorch here runs on CPU.
#   If you want real GPU acceleration on Apple Silicon, run the code
#   natively on macOS with `uv` directly (outside Docker) instead of inside
#   this container — that's the only way to reach the Metal/Neural Engine
#   backend today.
###############################################################################
