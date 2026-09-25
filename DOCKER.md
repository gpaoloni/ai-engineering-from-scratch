# Running ai-engineering-from-scratch in Docker

These four files give you a non-root, hardened container with Python 3.12
(via `uv`), Node.js 24 (via `nvm`), and Rust — the toolchains the
curriculum's lessons need.

## Setup

1. Clone the repo, then copy these files into its root (next to
   `requirements.txt`):

   ```
   git clone https://github.com/rohitg00/ai-engineering-from-scratch.git
   cd ai-engineering-from-scratch
   cp /path/to/Dockerfile /path/to/docker-compose.yml /path/to/.dockerignore /path/to/entrypoint.sh .
   ```

2. Build:

   ```
   docker compose build
   ```

3. Run an interactive shell:

   ```
   docker compose run --rm aiefs
   ```

   You'll land in `/home/learner/app` (a bind mount of the repo) as the
   non-root `learner` user. The entrypoint first prints what compute is
   actually reachable (NVIDIA GPU / Apple Silicon with no passthrough / CPU
   only — see the GPU section below), then drops you into bash with
   `python3`, `uv`, `node`, `npm`, `cargo`, and `rustc` all on `PATH`.

4. Run a lesson, same as the README describes, just inside the container:

   ```
   python3 phases/00-setup-and-tooling/01-dev-environment/code/verify.py --route beginner
   python3 phases/01-math-foundations/01-linear-algebra-intuition/code/vectors.py
   ```

   Rust lessons: `cd phases/10-llms-from-scratch/01-tokenizers/code && cargo run`
   Node/TypeScript lessons: `cd <lesson>/code && npm install && npm run <script>`

## Python via uv

The image bakes in exactly the workflow you'd run by hand:

```
curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install 3.12
uv venv                      # creates .venv at /home/learner/app/.venv
uv pip install -r requirements.txt
```

`VIRTUAL_ENV` and `PATH` are set at the image level, so every `RUN`/shell
already has `.venv` active — no manual `source .venv/bin/activate` needed
inside the container. To add packages ad hoc: `uv pip install numpy matplotlib jupyter`.

## Node via nvm

```
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.7/install.sh | bash
nvm install 24
nvm alias default 24
```

Because `nvm` is a shell function (not a binary), it's sourced once at
build time and the resulting Node 24 install is exposed through a stable
`$NVM_DIR/current` symlink added to `PATH` — so you get `node`/`npm` on
`PATH` in the running container without needing to source `nvm.sh` every
time. `nvm` itself is still there if you want another version:
`. "$NVM_DIR/nvm.sh" && nvm install <version>`.

## GPU support — read this, especially on Apple Silicon

**NVIDIA (Linux or Windows host with an NVIDIA GPU):**

```
nvidia-smi   # confirm the driver + GPU are visible on the HOST first
```

1. Install the NVIDIA driver and the [NVIDIA Container
   Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
   on the host (not in the image).
2. Build with the CUDA wheel index:

   ```
   docker compose build --build-arg TORCH_INDEX_URL=https://download.pytorch.org/whl/cu124
   ```

3. Uncomment the `deploy.resources.reservations.devices` block in
   `docker-compose.yml` (or run with `docker run --gpus all ...`).
4. Verify inside the container:

   ```
   nvidia-smi
   python3 -c "import torch; print(torch.cuda.is_available())"
   ```

**Apple Silicon (M1–M5) — your case, a Linux container on a Mac:**

Short version: **you can't get GPU acceleration inside this container on a
Mac, and that's not something a Dockerfile can fix.**

- CUDA doesn't apply at all — it's NVIDIA-only hardware/driver stack, so it
  was never relevant on a Mac regardless of containers.
- Metal/MPS (Apple's GPU backend) _is_ relevant on your hardware, but it
  cannot be passed into a Linux container. Docker Desktop, OrbStack, Podman,
  Lima — every container runtime on macOS — runs your containers inside a
  lightweight **Linux VM**. Linux has no Metal driver, so from inside that
  VM (and therefore inside any container running in it) there is no GPU
  device to attach to. This is a virtualization-boundary limitation, not a
  missing package, flag, or driver you can install your way around. It's
  still true as of 2026 — even Docker's own "Model Runner" feature, which
  _does_ support Metal-accelerated inference on Apple Silicon, works around
  this by running its accelerated backend as a **native macOS process
  outside the Linux VM** and talking to it from the container, rather than
  running the GPU workload inside the container itself.
- Concretely: build this image, `exec` into it, and run
  `python3 -c "import torch; print(torch.backends.mps.is_available())"` —
  it will print `False` inside the container, even though the identical
  command run natively (outside Docker) on the same Mac would print `True`.
  PyTorch inside this container will use CPU only, full stop.
- The plain `uv pip install torch torchvision torchaudio` (no
  `--index-url`) is still the right _default_ build to bake into the
  image, exactly as your snippet says — it's what lets the same Dockerfile
  work unmodified on any host. It just won't get you Metal acceleration
  when that host is a Mac and the workload is inside a container.

**If you actually want the M5's GPU for these lessons:** run the Python
side natively on macOS with `uv`, outside Docker —

```
uv python install 3.12
uv venv && source .venv/bin/activate
uv pip install -r requirements.txt
uv pip install torch torchvision torchaudio
python3 -c "import torch; print(torch.backends.mps.is_available())"  # True
```

— and keep this container around for the Node/Rust lesson work, or for
anything you'd rather run in an isolated, resource-limited sandbox. The
`entrypoint.sh` in this container prints which of these situations you're
in (NVIDIA GPU visible / Apple Silicon no-passthrough / CPU-only) every
time you start it, so it's never a silent surprise.

## What's hardened, and why

| Control                                                                                 | Where                                    | Effect                                                                                                                                                 |
| --------------------------------------------------------------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Non-root user (`learner`, fixed UID/GID)                                                | `Dockerfile`                             | Container processes never run as root; a code-execution bug in a lesson script can't touch root-owned files or escalate via setuid binaries.           |
| `cap_drop: ALL`                                                                         | `docker-compose.yml`                     | Removes all Linux capabilities (`NET_RAW`, `SYS_ADMIN`, etc.) beyond what an unprivileged process gets.                                                |
| `security_opt: no-new-privileges`                                                       | `docker-compose.yml`                     | Blocks any setuid/setgid binary from gaining privileges it didn't already have.                                                                        |
| `pids_limit`, `mem_limit`, `cpus`                                                       | `docker-compose.yml`                     | Caps a runaway or malicious script (e.g. an infinite training loop, fork bomb) instead of letting it exhaust the host.                                 |
| Pinned base image + pinned Python/Node/Rust versions                                    | `Dockerfile`                             | Reproducible builds; no silent toolchain drift between rebuilds.                                                                                       |
| `apt-get ... --no-install-recommends` + `rm -rf /var/lib/apt/lists/*` in the same `RUN` | `Dockerfile`                             | Smaller image, smaller attack surface, no stale package index sitting in a layer.                                                                      |
| Python via `uv`-managed venv, not system pip                                            | `Dockerfile`                             | No system Python touched at all; the whole Python toolchain lives in a disposable, project-local `.venv`.                                              |
| No published ports by default                                                           | `docker-compose.yml`                     | The lesson code doesn't need to be network-reachable; you opt in explicitly (and only to `127.0.0.1`) if you run the `web/` dev server.                |
| `.dockerignore` excludes `.env*`, `*.pem`, `*.key`, `.git`, `.venv`, `.nvm`             | `.dockerignore`                          | Local secrets, version-control metadata, and local toolchain state never enter the build context or the image.                                         |
| API keys passed as runtime env vars, never `ARG`/`ENV` baked into the image             | `docker-compose.yml` (commented example) | Secrets don't end up cached in an image layer or visible via `docker history`.                                                                         |
| GPU passthrough opt-in only, and only where it's real                                   | `docker-compose.yml`                     | The commented NVIDIA block does nothing unless you're on a Linux host with the NVIDIA Container Toolkit — no false sense of GPU acceleration on a Mac. |

### Optional: fully read-only root filesystem

The default compose file mounts the repo read-write, because several
lessons write to the tree (`cargo build` artifacts, `LEARNING.md` progress
files, `outputs/` generated by some lessons, `scripts/install_skills.py`).
If you only need to _read_ lessons or run stateless "Learn"-type ones, you
can lock the container down further — see the commented `read_only` /
`tmpfs` block at the bottom of `docker-compose.yml`.

### Optional: Julia

Julia lessons exist in Phases 1 and 10 but aren't installed by default to
keep the image smaller and the toolchain list matching what you asked for.
To add it, append to the `Dockerfile` (after the Rust stage, still as the
`learner` user):

```dockerfile
ARG JULIA_VERSION=1.10.5
RUN set -eux; \
    curl -fsSL "https://julialang-s3.julialang.org/bin/linux/x64/${JULIA_VERSION%.*}/julia-${JULIA_VERSION}-linux-x86_64.tar.gz" -o /tmp/julia.tar.gz; \
    tar -xzf /tmp/julia.tar.gz -C /home/learner; \
    rm /tmp/julia.tar.gz
ENV PATH=/home/learner/julia-${JULIA_VERSION}/bin:$PATH
```

## Rebuilding after `requirements.txt` or lockfile changes

```
docker compose build
```

Layer caching keys off the copied `requirements.txt`/`package*.json`, so a
normal build already picks up changes to those files. Use `docker compose
build --no-cache` only if you suspect a stale layer.
