# Custom comfy-prod worker image.
#
# Strategy: thin layer on top of the official runpod/worker-comfyui image
# that adds the heavy Python deps + the *correct* PuLID/IPAdapter custom
# node forks. Solves three problems:
#
# 1. The base image's auto-install of custom-node deps is unreliable for
#    nodes with native extensions (insightface, onnxruntime). Baking deps
#    into the image guarantees they're present at startup.
# 2. The runtime auto-installer (when used via ComfyGen / similar) maps
#    `PulidFluxModelLoader` to the wrong fork (`ComfyUI_PuLID_Flux_ll`)
#    whose runtime crashes on RunPod. Baking the correct fork
#    (`ComfyUI-PuLID-Flux-Enhanced`) makes the auto-installer skip it.
# 3. CPU `onnxruntime` is used instead of `onnxruntime-gpu` because the
#    GPU build segfaults inside RunPod's cpuset-constrained Serverless
#    containers. CPU ONNX is fast enough for the small InsightFace
#    antelopev2 face-embedding model.

FROM runpod/worker-comfyui:5.4.1-base

LABEL maintainer="ZeeShu (sahr / comfy-prod)"
LABEL description="runpod/worker-comfyui + PuLID-Flux-Enhanced + IPAdapter + heavy deps baked in"

# 1. Heavy custom-node runtime deps. These are NOT in the base image and
#    the auto-installer can't reliably add them.
#
#    `albumentations` + `onnx` added 2026-05-11 for Reactor
#    (`Gourieff/ComfyUI-ReActor` requirements.txt).
RUN pip install --no-cache-dir \
        insightface \
        onnxruntime \
        facexlib \
        timm \
        ftfy \
        ultralytics \
        dill \
        segment_anything \
        albumentations \
        onnx

# 2. Pre-bake the *correct* PuLID-Flux fork + IPAdapter_plus so ComfyUI
#    registers `PulidFluxModelLoader` and `IPAdapterUnifiedLoader` at
#    startup. Auto-installer then sees them as already-present and skips.
#
#    The base image installs ComfyUI to `/comfyui` (lowercase). If a
#    future base image moves it, this RUN will fail and we'll know.
#
#    InstantID + Reactor added 2026-05-11. Reactor repo is the SFW
#    rebuild `Gourieff/ComfyUI-ReActor` (old `-Node` repo was disabled
#    by GitHub staff for ToS).
RUN cd /comfyui/custom_nodes \
    && git clone --depth 1 https://github.com/sipie800/ComfyUI-PuLID-Flux-Enhanced.git \
    && git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git \
    && git clone --depth 1 https://github.com/cubiq/ComfyUI_InstantID.git \
    && git clone --depth 1 https://github.com/Gourieff/ComfyUI-ReActor.git

# 2b. Make Reactor's NSFW filter env-controlled. Default: enabled
#     (REACTOR_NSFW_FILTER unset or "1" → filter ON). Set =0 to bypass.
#     Targets the verified function signature in
#     `Gourieff/ComfyUI-ReActor` scripts/reactor_sfw.py (HEAD 2026-05-11).
#
#     Python (not sed) because the inject is multi-line and the
#     assert-before-write pattern is the build-time guard rail: if
#     Reactor ever moves/renames the function, `assert needle in src`
#     fails and the build aborts BEFORE we push an unpatched image.
#     Do not relax this assert.
RUN python3 <<'PY'
import pathlib, sys
p = pathlib.Path("/comfyui/custom_nodes/ComfyUI-ReActor/scripts/reactor_sfw.py")
src = p.read_text()
needle = "def nsfw_image(img_data, model_path: str):"
inject = (
    "\n    import os"
    "\n    if os.getenv(\"REACTOR_NSFW_FILTER\", \"1\") == \"0\":"
    "\n        return False"
)
assert needle in src, "Reactor moved nsfw_image() — build aborted"
p.write_text(src.replace(needle, needle + inject, 1))
print("reactor NSFW filter patched")
PY

# 3. Sanity check at build time — if any of these imports fail, the
#    build fails BEFORE we push. Catches dep issues before they hit
#    production.
RUN python3 -c "import insightface, onnxruntime, facexlib, timm, ftfy, ultralytics, dill, segment_anything; print('all heavy deps import OK')"

# 4. Verify the cloned custom nodes have the right top-level files.
RUN test -f /comfyui/custom_nodes/ComfyUI-PuLID-Flux-Enhanced/__init__.py \
    && test -f /comfyui/custom_nodes/ComfyUI_IPAdapter_plus/__init__.py \
    && test -f /comfyui/custom_nodes/ComfyUI_InstantID/__init__.py \
    && test -f /comfyui/custom_nodes/ComfyUI-ReActor/__init__.py \
    && echo "custom node clone verified"

# 4b. Importability check — the v3 build shipped with Reactor's __init__.py
#     present but its import raised, so ComfyUI silently skipped it and
#     `ReActorFaceSwap` never registered. The job got back a runtime
#     `node does not exist` error and we had no signal from the build.
#
#     This step actually loads each node's __init__.py the same way
#     ComfyUI does (importlib + spec_from_file_location) so a broken
#     import fails the BUILD with the traceback visible in CI logs.
#
#     CI runners have no NVIDIA driver, but ComfyUI's
#     `comfy.model_management` probes the GPU at MODULE LOAD via
#     `torch.cuda.current_device()`, which raises `RuntimeError: Found
#     no NVIDIA driver` and would mask the real custom-node import
#     errors. Setting `sys.argv = [..., '--cpu']` BEFORE the first
#     comfy import makes `comfy.cli_args` parse `--cpu`, which makes
#     `model_management` set `CPUState.CPU` at module load, which
#     bypasses the cuda probe entirely. Real workers have a GPU and
#     parse their own (non-`--cpu`) argv — so this hack is build-only.
RUN python3 - <<'PY'
import sys
sys.argv = ['comfy-build-importability-check', '--cpu']
sys.path.insert(0, "/comfyui")

import importlib.util, traceback
errors = []
for name, path in [
    ("PuLID_Flux_Enhanced", "/comfyui/custom_nodes/ComfyUI-PuLID-Flux-Enhanced/__init__.py"),
    ("IPAdapter_plus",     "/comfyui/custom_nodes/ComfyUI_IPAdapter_plus/__init__.py"),
    ("InstantID",          "/comfyui/custom_nodes/ComfyUI_InstantID/__init__.py"),
    ("ReActor",            "/comfyui/custom_nodes/ComfyUI-ReActor/__init__.py"),
]:
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        m = importlib.util.module_from_spec(spec)
        sys.modules[name] = m
        spec.loader.exec_module(m)
        print(f"  IMPORT OK:     {name}")
    except Exception as e:
        print(f"  IMPORT FAILED: {name}: {type(e).__name__}: {e}")
        traceback.print_exc()
        errors.append(name)
if errors:
    print(f"\nFAILED IMPORTS: {errors}")
    sys.exit(1)
PY

# 5. Bake extra_model_paths.yaml so the worker can find models on the
#    network volume. The base image's COMFY_HOME env var isn't honored,
#    so we override the yaml at /comfyui/extra_model_paths.yaml directly.
#    Our volume layout is `/runpod-volume/ComfyUI/models/<type>` (the
#    ComfyGen-style layout we re-laid the volume to earlier).
RUN cat > /comfyui/extra_model_paths.yaml <<'EOF'
# Tells ComfyUI where to find models on the RunPod network volume.
# Overridden in our image to match the volume's ComfyGen-style layout.
runpod_volume:
    base_path: /runpod-volume/ComfyUI/models
    checkpoints: checkpoints
    unet: unet
    diffusion_models: diffusion_models
    clip: clip
    clip_vision: clip_vision
    text_encoders: text_encoders
    vae: vae
    loras: loras
    controlnet: controlnet
    ipadapter: ipadapter
    pulid: pulid
    upscale_models: upscale_models
    embeddings: embeddings
    style_models: style_models
    instantid: instantid
    insightface: insightface
    facerestore_models: facerestore_models
    nsfw_detector: nsfw_detector
EOF

# 6. Symlink /comfyui/models/<dir> → /runpod-volume/ComfyUI/models/<dir>
#    for dirs that Reactor (and similar) look up via
#    `folder_paths.models_dir` directly, bypassing extra_model_paths.yaml.
#
#    Verified bypass paths in `Gourieff/ComfyUI-ReActor` (HEAD 2026-05-11):
#      - nodes.py:73   NSFWDET_MODEL_PATH = os.path.join(models_dir, "nsfw_detector", ...)
#      - nodes.py:80   dir_facerestore_models = os.path.join(models_dir, "facerestore_models")
#      - nodes.py:82   folder_paths.folder_names_and_paths["facerestore_models"] = ([dir_facerestore_models], ...)
#                      (this OVERWRITES whatever yaml had set, so yaml alone won't reach the volume)
#      - install.py:25 models_dir_path = os.path.join(models_dir, "insightface")  (for inswapper_128.onnx)
#
#    Symlink targets don't exist at build time (volume isn't mounted yet) —
#    that's fine; symlinks resolve at access time when the volume is up.
#    Yaml entries above stay for well-behaved nodes; symlinks are the
#    belt-and-suspenders fallback for ones that bypass yaml.
RUN mkdir -p /comfyui/models \
    && for d in facerestore_models nsfw_detector insightface instantid reactor; do \
           rm -rf /comfyui/models/$d ; \
           ln -s /runpod-volume/ComfyUI/models/$d /comfyui/models/$d ; \
       done \
    && ls -la /comfyui/models/ | grep -E 'facerestore|nsfw|insightface|instantid|reactor'
