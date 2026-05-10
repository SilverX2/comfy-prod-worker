# comfy-prod-worker

Custom ComfyUI worker image for RunPod Serverless.

Built on `runpod/worker-comfyui:5.4.1-base`. Adds:

- **Heavy custom-node Python deps**: `insightface`, `onnxruntime` (CPU build —
  GPU build segfaults inside RunPod's cpuset-constrained Serverless containers),
  `facexlib`, `timm`, `ftfy`, `ultralytics`, `dill`, `segment_anything`.
- **Pre-baked custom nodes** so they register at startup and the auto-installer
  doesn't try to pip-install conflicting forks:
  - [`ComfyUI-PuLID-Flux-Enhanced`](https://github.com/sipie800/ComfyUI-PuLID-Flux-Enhanced)
  - [`ComfyUI_IPAdapter_plus`](https://github.com/cubiq/ComfyUI_IPAdapter_plus)

## Usage on RunPod

Set the endpoint template's image to:

```
ghcr.io/silverx2/comfy-prod-worker:v1
```

The image expects a network volume mounted at `/runpod-volume/` containing the
standard ComfyUI model layout under `/runpod-volume/ComfyUI/models/...`. The
base image's `extra_model_paths.yaml` handles the model lookups automatically.

## Building

GitHub Actions builds + pushes to GHCR on every push to `main`. To trigger a
new tagged build manually:

```sh
gh workflow run build.yml -f tag=v2
```

## Tags

- `v1` — first build, 2026-05-10
- `latest` — always points at most recent build
