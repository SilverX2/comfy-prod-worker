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
RUN pip install --no-cache-dir \
        insightface \
        onnxruntime \
        facexlib \
        timm \
        ftfy \
        ultralytics \
        dill \
        segment_anything

# 2. Pre-bake the *correct* PuLID-Flux fork + IPAdapter_plus so ComfyUI
#    registers `PulidFluxModelLoader` and `IPAdapterUnifiedLoader` at
#    startup. Auto-installer then sees them as already-present and skips.
#
#    The base image installs ComfyUI to `/comfyui` (lowercase). If a
#    future base image moves it, this RUN will fail and we'll know.
RUN cd /comfyui/custom_nodes \
    && git clone --depth 1 https://github.com/sipie800/ComfyUI-PuLID-Flux-Enhanced.git \
    && git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git

# 3. Sanity check at build time — if any of these imports fail, the
#    build fails BEFORE we push. Catches dep issues before they hit
#    production.
RUN python3 -c "import insightface, onnxruntime, facexlib, timm, ftfy, ultralytics, dill, segment_anything; print('all heavy deps import OK')"

# 4. Verify the cloned custom nodes have the right top-level files.
RUN test -f /comfyui/custom_nodes/ComfyUI-PuLID-Flux-Enhanced/__init__.py \
    && test -f /comfyui/custom_nodes/ComfyUI_IPAdapter_plus/__init__.py \
    && echo "custom node clone verified"

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
EOF
