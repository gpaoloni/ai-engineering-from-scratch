# Running ai-engineering-from-scratch in Docker

`Dockerfile`, `docker-compose.yml`, `.dockerignore`, and `entrypoint.sh` at
the repo root give you a non-root, hardened container with Python (via `uv`),
Node.js, and Rust — the toolchains the curriculum's lessons need. Python and
Node resolve to their **latest** releases at build time; Rust is pinned via the
`RUST_VERSION` build arg.

## Setup

1. Clone the repo:

   ```bash
   git clone https://github.com/rohitg00/ai-engineering-from-scratch.git
   cd ai-engineering-from-scratch
   ```

2. Build:

   ```bash
   docker compose build
   ```

3. Run an interactive shell:

   ```bash
   docker compose run --rm aiefs
   ```

   You'll land in `/home/learner/app` (a bind mount of the repo) as the
   non-root `learner` user. The entrypoint first prints what compute is
   actually reachable (NVIDIA GPU / arm64 with no passthrough / CPU only —
   see the GPU section below), then drops you into bash with `python3`, `uv`,
   `node`, `npm`, `npx`, `cargo`, and `rustc` all on `PATH`.

4. Run a lesson, same as the README describes, just inside the container:

   ```bash
   python3 phases/00-setup-and-tooling/01-dev-environment/code/verify.py --route beginner
   python3 phases/01-math-foundations/01-linear-algebra-intuition/code/vectors.py
   ```

   Rust lessons are single files compiled with `rustc` (no Cargo project):

   ```bash
   cd phases/00-setup-and-tooling/01-dev-environment/code
   rustc --edition 2021 main.rs -o /tmp/main && /tmp/main
   ```

   TypeScript lessons run through `tsx`, which `npx` downloads on first use:

   ```bash
   cd phases/05-nlp-foundations-to-advanced/19-subword-tokenization/code
   npx tsx main.ts
   ```

## Python via uv

`uv` installs its own standalone CPython (the latest stable release at build
time) and a virtualenv at `/home/learner/venv`, outside the bind-mounted repo
so it never lands in your working tree. `VIRTUAL_ENV` and `PATH` are set at the
image level, so the venv is already active in every shell — no
`source .../activate` needed. To add packages ad hoc:
`uv pip install <package>` (these live in the container and are gone after
`--rm`; add them to `requirements.txt` and rebuild to keep them).

## Jupyter (.ipynb)

```bash
export JUPYTER_TOKEN=$(openssl rand -hex 24)
docker compose --profile jupyter up jupyter
```

Open `http://127.0.0.1:8888/?token=$JUPYTER_TOKEN`. The port is published on
`127.0.0.1` only, and the service refuses to start without a token. Pick the
"ai-engineering-from-scratch (venv)" kernel so notebooks run inside the
container.

## GPU support — read this, especially on Apple Silicon

**NVIDIA (Linux or Windows host with an NVIDIA GPU):**

```bash
nvidia-smi   # confirm the driver + GPU are visible on the HOST first
```

1. Install the NVIDIA driver and the [NVIDIA Container
   Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
   on the host (not in the image).
2. Build with the CUDA wheel index:

   ```bash
   docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu128
   ```

3. Uncomment the `deploy.resources.reservations.devices` block in
   `docker-compose.yml` (or run with `docker run --gpus all ...`).
4. Verify inside the container:

   ```bash
   nvidia-smi
   python3 -c "import torch; print(torch.cuda.is_available())"
   ```

**amd64 host without a GPU:** the default PyPI torch wheel on x86-64 Linux
pulls several GB of CUDA libraries you can't use. Build with the CPU index
instead:

```bash
docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cpu
```

**Apple Silicon — a Linux container on a Mac:**

Short version: **you can't get GPU acceleration inside this container on a
Mac, and that's not something a Dockerfile can fix.**

- CUDA doesn't apply at all — it's an NVIDIA-only hardware/driver stack.
- Metal/MPS (Apple's GPU backend) cannot be passed into a Linux container.
  Docker Desktop, OrbStack, Podman, Lima — every container runtime on macOS —
  runs your containers inside a lightweight **Linux VM**. Linux has no Metal
  driver, so there is no GPU device to attach to. This is a
  virtualization-boundary limitation, not a missing package or flag. Docker's
  own "Model Runner" works around it by running its Metal-accelerated backend
  as a **native macOS process outside the VM**, not inside a container.
- Concretely: `python3 -c "import torch; print(torch.backends.mps.is_available())"`
  prints `False` inside the container, even though the same command run
  natively on the same Mac prints `True`. PyTorch in here uses CPU only.
- The default (empty) `TORCH_INDEX_URL` is the right choice on a Mac: on
  arm64 Linux the PyPI wheel is already CPU-only.

**If you want the Mac's GPU for these lessons:** run the Python side natively
on macOS with `uv`, outside Docker:

```bash
uv python install
uv venv && source .venv/bin/activate
uv pip install -r requirements.txt
python3 -c "import torch; print(torch.backends.mps.is_available())"  # True
```

— and keep this container for Node/Rust lesson work, or for anything you'd
rather run isolated. `entrypoint.sh` prints which situation you're in every
time the container starts.

## What's hardened, and why

| Control | Where | Effect |
| --- | --- | --- |
| Non-root user (`learner`, UID/GID 1000) | `Dockerfile`, `docker-compose.yml` | Container processes never run as root. |
| `cap_drop: ALL` | `docker-compose.yml` | Removes every Linux capability, including Docker's defaults (`NET_RAW`, `CHOWN`, `SETUID`, …). |
| `security_opt: no-new-privileges` | `docker-compose.yml` | Blocks setuid/setgid binaries from gaining privileges. |
| `pids_limit: 512`, `mem_limit: 4g`, `cpus: "2.0"` | `docker-compose.yml` | Caps a runaway script (infinite training loop, fork bomb) instead of letting it exhaust the host. Raise them if a lesson needs more; `cpus` can't exceed the cores Docker sees. |
| `.git` mounted read-only | `docker-compose.yml` | Code in the container can read history but can't plant git hooks or rewrite refs that would later run on the host. Commit from the host. |
| No Docker socket, not `privileged` | `docker-compose.yml` | The container can't control the Docker daemon or the host kernel. |
| Node tarball verified against `SHASUMS256.txt` | `Dockerfile` | Catches corrupted or tampered downloads. |
| `apt-get ... --no-install-recommends` + `rm -rf /var/lib/apt/lists/*` in the same `RUN` | `Dockerfile` | Smaller image, smaller attack surface, no stale package index in a layer. |
| No published ports by default; Jupyter on `127.0.0.1` with a required token | `docker-compose.yml` | Nothing in the container is reachable from your network unless you opt in. |
| `.dockerignore` excludes `.git`, `.env*`, `*.pem`, `*.key` (at any depth), venvs, `node_modules`, `target/` | `.dockerignore` | Local secrets, VCS metadata, and local build state never enter the build context or the image. |
| API keys passed as runtime env vars, never `ARG`/`ENV` | `docker-compose.yml` (commented example) | Secrets don't end up in an image layer or `docker history`. |

### What this does **not** protect

- **The rest of the repo is writable from the container.** That's needed for
  lesson outputs and progress files, but it also means code in the container
  can delete or modify any file in your working tree. Commit often from the
  host. Files that host tools execute later (`.claude/`, `.vscode/`,
  `scripts/`, `package.json` scripts) can be modified too — review changes
  with `git diff` before running host tooling on them.
- **Outbound network is unrestricted.** Lesson code can reach the internet,
  and could send anything it can read (the repo, any API keys you pass in).
  Use dedicated, low-limit API keys.
- **Build-time downloads are not pinned.** Python, Node, `uv`, `rustup`, and
  `requirements.txt` packages resolve to whatever is current at build time.
  `uv` and `rustup` are installed via their official install scripts without
  checksum verification.
- **If an AI coding agent runs on the host, so does the code it executes.**
  To keep agent-run lesson code sandboxed, run the agent inside this
  container, or have it run code only via `docker compose exec`.

### Optional: fully read-only root filesystem

The default compose file mounts the repo read-write, because several lessons
write to the tree (`LEARNING.md` progress files, `outputs/`,
`scripts/install_skills.py`). If you only need to _read_ lessons or run
stateless ones, see the commented `read_only` / `tmpfs` block at the bottom
of `docker-compose.yml`.

### Optional: Julia

Julia lessons exist in Phases 1 and 10 but aren't installed by default to keep
the image smaller. To add it, append to the `Dockerfile` (after the Rust
section, still as the `learner` user):

```dockerfile
ARG JULIA_VERSION=1.10.5
RUN set -eux; \
    case "${TARGETARCH}" in \
    amd64) JULIA_DIR="x64";     JULIA_ARCH="x86_64" ;; \
    arm64) JULIA_DIR="aarch64"; JULIA_ARCH="aarch64" ;; \
    esac; \
    curl -fsSL "https://julialang-s3.julialang.org/bin/linux/${JULIA_DIR}/${JULIA_VERSION%.*}/julia-${JULIA_VERSION}-linux-${JULIA_ARCH}.tar.gz" -o /tmp/julia.tar.gz; \
    tar -xzf /tmp/julia.tar.gz -C /home/learner; \
    rm /tmp/julia.tar.gz
ENV PATH=/home/learner/julia-${JULIA_VERSION}/bin:$PATH
```

## Rebuilding

```bash
docker compose build
```

Changes to `requirements.txt` invalidate its layer, so a normal build picks
them up. Docker caches the Python and Node download layers, though, so a
normal build will **not** fetch newer Python/Node releases. To upgrade them:

```bash
docker compose build --no-cache
```
