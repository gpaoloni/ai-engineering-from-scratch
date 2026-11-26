# syntax=docker/dockerfile:1.7
###############################################################################
# ai-engineering-from-scratch — secure, multi-language learning environment
#
# Python via uv (latest stable CPython at build time, uv-managed venv)
# Node from the official tarball (latest release at build time, checksum-verified)
# Rust via rustup (pinned version)
#
# Build (from the repo root):
#   docker compose build
#
# Run:
#   docker compose run --rm aiefs
#
# GPU note (read before building on Apple Silicon): see the GPU section
# near the bottom of this file and DOCKER.md. Short version — on a
# Mac, this Linux container cannot reach the Metal/MPS GPU no matter how
# this Dockerfile is written; that's a virtualization boundary, not a
# missing flag. CUDA only applies on Linux/Windows hosts with an NVIDIA GPU.
###############################################################################

ARG DEBIAN_VERSION=bookworm-slim
ARG RUST_VERSION=1.82.0
ARG UID=1000
ARG GID=1000

FROM debian:${DEBIAN_VERSION} AS base
SHELL ["/bin/bash", "-c"]

# ---------------------------------------------------------------------------
# OS packages: minimal set, no recommended extras, apt cache purged in the
# same layer so it never ends up in an image layer. Neither Python nor Node
# come from apt — uv and the official Node tarball provide those below.
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
# Node.js — latest release at build time, official prebuilt tarball,
# verified against Node's published SHASUMS256.txt. Docker caches this
# layer, so run `docker compose build --no-cache` to pick up a newer Node.
# ---------------------------------------------------------------------------
ARG TARGETARCH
ENV NODE_HOME=/home/learner/node
RUN set -eux; \
  case "${TARGETARCH}" in \
  amd64) NODE_ARCH="x64" ;; \
  arm64) NODE_ARCH="arm64" ;; \
  *) echo "Unsupported or unset TARGETARCH='${TARGETARCH}' — pass --build-arg TARGETARCH=amd64|arm64 explicitly if your builder doesn't set it." >&2; exit 1 ;; \
  esac; \
  NODE_DIST="https://nodejs.org/dist/latest"; \
  curl -fsSLO "${NODE_DIST}/SHASUMS256.txt"; \
  NODE_TARBALL="$(grep -oE "node-v[0-9.]+-linux-${NODE_ARCH}\.tar\.xz" SHASUMS256.txt | head -n1)"; \
  curl -fsSLO "${NODE_DIST}/${NODE_TARBALL}"; \
  grep " ${NODE_TARBALL}\$" SHASUMS256.txt | sha256sum -c -; \
  mkdir -p "${NODE_HOME}"; \
  tar -xJf "${NODE_TARBALL}" -C "${NODE_HOME}" --strip-components=1; \
  rm -f "${NODE_TARBALL}" SHASUMS256.txt
ENV PATH="${NODE_HOME}/bin:$PATH"
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
# uv + Python (uv installs and manages its own standalone Python build, so
# no system python3/pip/venv package is needed at all). `uv python install`
# with no version picks the latest stable CPython at build time.
# ---------------------------------------------------------------------------
ENV PATH="/home/learner/.local/bin:$PATH"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
RUN uv python install

# uv-managed virtualenv outside the bind-mounted repo, so it survives the
# mount and never lands in your working tree. Activated via ENV below.
RUN uv venv /home/learner/venv
ENV VIRTUAL_ENV=/home/learner/venv \
  PATH=/home/learner/venv/bin:$PATH

# ---------------------------------------------------------------------------
# GPU / PyTorch (see the long comment near the bottom of this file).
#
# Installed BEFORE requirements.txt: requirements.txt also lists torch, and
# uv skips packages that are already satisfied, so whichever build lands
# first wins. Doing it here is what lets TORCH_INDEX_URL take effect.
#
# Default build = the plain PyPI build.
#
# On a Linux host with an NVIDIA GPU, rebuild with:
#   docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
# On an amd64 host without a GPU, the CPU index avoids GBs of CUDA wheels:
#   docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu
# ---------------------------------------------------------------------------
ARG TORCH_INDEX_URL=""
RUN if [ -n "${TORCH_INDEX_URL}" ]; then \
  uv pip install torch torchvision torchaudio --index-url "${TORCH_INDEX_URL}"; \
  else \
  uv pip install torch torchvision torchaudio; \
  fi

COPY --chown=learner:learner requirements.txt ./
RUN uv pip install -r requirements.txt
# JupyterLab + a kernel that points at this exact venv, so notebooks opened
# in the browser run their code inside this container, not on your host.
RUN uv pip install jupyterlab ipykernel \
  && python -m ipykernel install --user \
  --name aiefs \
  --display-name "ai-engineering-from-scratch (venv)"

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

EXPOSE 8888

ENTRYPOINT ["/usr/bin/tini", "--", "/home/learner/entrypoint.sh"]
CMD ["bash"]

###############################################################################
# GPU support — read this before you build
#
# NVIDIA (Linux / Windows host):
#   1. Install the NVIDIA driver + NVIDIA Container Toolkit on the HOST
#      (not in this image).
#   2. Build with the CUDA wheel index:
#        docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
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
