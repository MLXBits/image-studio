"""Warm-model generation driver for MLXBits Image Studio.

Runs inside the mflux tool venv (interpreter discovered from the
mflux-generate-flux2 shim's shebang) and keeps one model resident between
jobs so back-to-back generations skip the model load. Supports the flux2,
krea2, and ideogram4 families (one warm model at a time, fingerprint-keyed).

Protocol: newline-delimited JSON. Requests on stdin (hello, generate, cancel,
unload, ping, quit); events on the *original* stdout (ready, loading, loaded,
progress, image, done, error, unloaded, pong, fatal). fd 1 is re-pointed at
stderr at startup so mflux's own prints and progress bars can never corrupt
the protocol stream — the app shows stderr in the job log instead.
"""

import gc
import json
import os
import queue
import sys
import threading
import time
from collections import OrderedDict

# Protocol stream = a private dup of the original stdout. Everything else that
# writes to fd 1 (mflux prints, HF download bars) lands on stderr instead.
_protocol = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)
sys.stdout = sys.stderr

_emit_lock = threading.Lock()
_cancel = threading.Event()
_requests: "queue.Queue[dict]" = queue.Queue()

EMBED_CACHE_LIMIT = 8


def emit(obj):
    with _emit_lock:
        try:
            _protocol.write(json.dumps(obj) + "\n")
            _protocol.flush()
        except (BrokenPipeError, ValueError):
            os._exit(0)  # parent is gone


class WarmModel:
    """A resident model plus the machinery that makes text-encoder eviction
    safe. flux2 gets a driver-side embedding cache (its encoder has none);
    krea2 relies on its native prompt_cache with a reload-on-miss wrapper.
    ideogram4's encoder config is weight-layout-dependent, so its TE is never
    evicted (its native prompt_cache still skips re-encodes)."""

    def __init__(self, model, fingerprint, family, model_path):
        self.model = model
        self.fingerprint = fingerprint
        self.family = family
        self.model_path = model_path
        self.embed_cache = OrderedDict()
        if family == "flux2":
            self._orig_encode = model._encode_prompt_pair
            model._encode_prompt_pair = self._flux2_cached_encode
        elif family == "krea2":
            self._orig_encode = model._encode_prompts
            model._encode_prompts = self._krea2_ensured_encode

    def _flux2_cached_encode(self, *, prompt, negative_prompt, guidance):
        import mlx.core as mx

        key = (prompt, negative_prompt if (guidance or 0) > 1.0 else None)
        hit = self.embed_cache.get(key)
        if hit is not None:
            self.embed_cache.move_to_end(key)
            return hit
        self.ensure_text_encoder()
        result = self._orig_encode(prompt=prompt, negative_prompt=negative_prompt, guidance=guidance)
        mx.eval(*[r for r in result if r is not None])
        self.embed_cache[key] = result
        while len(self.embed_cache) > EMBED_CACHE_LIMIT:
            self.embed_cache.popitem(last=False)
        return result

    def _krea2_ensured_encode(self, *, prompt, negative_prompt, guidance):
        """Krea2's encoder checks its prompt_cache before touching the text
        encoder, so cached prompts survive eviction for free; a cache miss
        with the encoder gone fails, and we reload + retry."""
        try:
            return self._orig_encode(prompt=prompt, negative_prompt=negative_prompt, guidance=guidance)
        except Exception:
            if self.model.text_encoder is not None:
                raise
            self.ensure_text_encoder()
            return self._orig_encode(prompt=prompt, negative_prompt=negative_prompt, guidance=guidance)

    def _te_definition_and_encoder(self):
        if self.family == "flux2":
            from mflux.models.flux2.model.flux2_text_encoder.qwen3_text_encoder import Qwen3TextEncoder
            from mflux.models.flux2.weights.flux2_weight_definition import Flux2KleinWeightDefinition

            return Flux2KleinWeightDefinition, Qwen3TextEncoder(**self.model.model_config.text_encoder_overrides)
        if self.family == "krea2":
            from mflux.models.krea2.model.krea2_text_encoder.text_encoder import Krea2TextEncoder
            from mflux.models.krea2.weights.krea2_weight_definition import Krea2WeightDefinition

            return Krea2WeightDefinition, Krea2TextEncoder()
        raise RuntimeError(f"text-encoder reload unsupported for family {self.family}")

    def ensure_text_encoder(self):
        """Reloads just the text_encoder component after an eviction."""
        if getattr(self.model, "text_encoder", None) is not None:
            return
        emit({"event": "loading", "component": "text_encoder"})
        from mflux.models.common.resolution.path_resolution import PathResolution
        from mflux.models.common.weights.loading.loaded_weights import LoadedWeights, MetaData
        from mflux.models.common.weights.loading.weight_applier import WeightApplier
        from mflux.models.common.weights.loading.weight_loader import WeightLoader

        definition, encoder = self._te_definition_and_encoder()
        component = next(c for c in definition.get_components() if c.name == "text_encoder")
        root = PathResolution.resolve(path=self.model_path, patterns=definition.get_download_patterns())
        raw, q_level, version = WeightLoader._load_component(root, component)
        loaded = LoadedWeights(
            components={"text_encoder": raw},
            meta_data=MetaData(quantization_level=q_level, mflux_version=version),
        )
        WeightApplier.apply_and_quantize_single(
            weights=loaded,
            model=encoder,
            component=component,
            quantize_arg=self.model.bits,
            quantization_predicate=definition.quantization_predicate,
        )
        self.model.text_encoder = encoder

    def evict_text_encoder(self):
        import mlx.core as mx

        if self.family == "ideogram4":
            return  # layout-dependent TE config; reload is unreliable — keep resident
        if getattr(self.model, "text_encoder", None) is None:
            return
        self.model.text_encoder = None
        gc.collect()
        mx.clear_cache()


class _ProgressEmitter:
    """Per-step progress events; also the cancellation point — raising from the
    in-loop callback aborts the denoise without killing the warm process."""

    def __init__(self, total_steps):
        self.total_steps = total_steps

    def call_in_loop(self, t, seed, prompt, latents, config, time_steps):
        import mlx.core as mx

        # The in-loop callback fires before the generation loop's own
        # mx.eval — force the step's compute here so "step N" means N steps
        # actually finished (matches the CLI path's tqdm-derived counter).
        mx.eval(latents)
        emit({"event": "progress", "seed": seed, "step": t + 1, "total": config.num_inference_steps})
        if _cancel.is_set():
            from mflux.utils.exceptions import StopImageGenerationException

            raise StopImageGenerationException("cancelled by app")


_warm = None  # the single WarmModel, or None


def _memory_gb():
    import mlx.core as mx

    return round(mx.get_active_memory() / 1e9, 2)


def _unload(reason):
    global _warm
    if _warm is None:
        return
    import mlx.core as mx

    # Remove the instance-level encode wrapper so no cycle keeps the model
    # (and its weights) alive after we drop our reference.
    if _warm.family == "flux2":
        _warm.model._encode_prompt_pair = _warm._orig_encode
    elif _warm.family == "krea2":
        _warm.model._encode_prompts = _warm._orig_encode
    _warm = None
    gc.collect()
    mx.clear_cache()
    emit({"event": "unloaded", "reason": reason})


def _construct_model(req):
    """Mirrors each family CLI's model construction, including the parser's
    builtin-name vs model-path split."""
    family = req.get("family", "flux2")
    kwargs = {
        "quantize": req.get("quantize"),
        "lora_paths": req.get("lora_paths") or None,
        "lora_scales": req.get("lora_scales") or None,
    }
    from mflux.models.common.config import ModelConfig

    if family == "flux2":
        from mflux.models.flux2.variants import Flux2Klein

        return Flux2Klein(model_config=ModelConfig.from_name(model_name=req["model"]), **kwargs)
    if family == "krea2":
        from mflux.models.krea2.variants.txt2img.krea2 import Krea2

        # The app always sends a repo ID or saved-weights path here.
        return Krea2(model_config=ModelConfig.krea2(), model_path=req["model"], **kwargs)
    if family == "ideogram4":
        from mflux.models.ideogram4.variants.txt2img.ideogram4 import Ideogram4
        from mflux.models.ideogram4.weights.ideogram4_weight_definition import Ideogram4WeightDefinition

        if Ideogram4WeightDefinition.is_builtin_name(req["model"]):
            return Ideogram4(model_config=ModelConfig.from_name(req["model"]), model_path=None, **kwargs)
        return Ideogram4(model_config=ModelConfig.ideogram4_fp8(), model_path=req["model"], **kwargs)
    raise RuntimeError(f"unknown family: {family}")


def _latent_creator(family):
    if family == "krea2":
        from mflux.models.krea2.latent_creator import Krea2LatentCreator

        return Krea2LatentCreator
    if family == "ideogram4":
        from mflux.models.ideogram4.latent_creator import Ideogram4LatentCreator

        return Ideogram4LatentCreator
    from mflux.models.flux2.latent_creator.flux2_latent_creator import Flux2LatentCreator

    return Flux2LatentCreator


def _load_model(req):
    global _warm
    import mlx.core as mx

    fingerprint = req["fingerprint"]
    if _warm is not None and _warm.fingerprint != fingerprint:
        _unload("refingerprint")
    if _warm is not None:
        return _warm

    emit({"event": "loading", "component": "model"})
    started = time.monotonic()
    model = _construct_model(req)
    mx.eval(model.parameters())
    _warm = WarmModel(
        model=model,
        fingerprint=fingerprint,
        family=req.get("family", "flux2"),
        model_path=req["model"],
    )
    emit({
        "event": "loaded",
        "fingerprint": fingerprint,
        "seconds": round(time.monotonic() - started, 2),
        "memory_gb": _memory_gb(),
    })
    return _warm


def _generate_kwargs(req, seed, prompt):
    """Per-family generate_image kwargs, mirroring each family's CLI call."""
    family = req.get("family", "flux2")
    if family == "flux2":
        return {
            "seed": seed,
            "prompt": prompt,
            "num_inference_steps": req["steps"],
            "height": req["height"],
            "width": req["width"],
            "guidance": req.get("guidance", 1.0),
            "image_path": req.get("image_path"),
            "image_strength": req.get("image_strength"),
            "scheduler": "flow_match_euler_discrete",
        }
    if family == "krea2":
        return {
            "seed": seed,
            "prompt": prompt,
            "num_inference_steps": req["steps"],
            "height": req["height"],
            "width": req["width"],
            "guidance": req.get("guidance", 1.0),
            "negative_prompt": req.get("negative_prompt"),
            "image_path": req.get("image_path"),
            "image_strength": req.get("image_strength"),
        }
    # ideogram4: the preset defines steps and guidance schedule; prompt is the
    # caption JSON string (or a plain description).
    return {
        "seed": seed,
        "prompt": prompt,
        "height": req["height"],
        "width": req["width"],
        "preset": req.get("preset"),
        "strict_caption_validation": bool(req.get("strict_caption_validation")),
        "cfg_end": req.get("cfg_end"),
    }


def _generate_once(req):
    import mlx.core as mx

    from mflux.callbacks.callback_registry import CallbackRegistry
    from mflux.callbacks.instances.stepwise_handler import StepwiseHandler
    from mflux.utils.image_util import ImageUtil

    if req.get("cache_limit_gb"):
        mx.set_cache_limit(int(req["cache_limit_gb"] * 1e9))

    warm = _load_model(req)
    model = warm.model

    model.callbacks = CallbackRegistry()
    model.callbacks.register(_ProgressEmitter(total_steps=req["steps"]))
    if req.get("stepwise_dir"):
        model.callbacks.register(
            StepwiseHandler(
                model=model,
                output_dir=req["stepwise_dir"],
                latent_creator=_latent_creator(req.get("family", "flux2")),
            )
        )

    for out in req["outputs"]:
        prompt = out.get("prompt") or req["prompt"]
        image = model.generate_image(**_generate_kwargs(req, out["seed"], prompt))
        ImageUtil.save_image(image=image, path=out["path"], export_json_metadata=False)
        emit({"event": "image", "seed": out["seed"], "path": out["path"]})

    if req.get("te_policy") == "evict":
        warm.evict_text_encoder()
    gc.collect()
    peak_gb = round(mx.get_peak_memory() / 1e9, 2)
    mx.clear_cache()
    emit({"event": "done", "id": req.get("id"), "peak_gb": peak_gb, "memory_gb": _memory_gb()})


def _handle_generate(req):
    from mflux.utils.exceptions import StopImageGenerationException

    _cancel.clear()
    try:
        _generate_once(req)
    except StopImageGenerationException:
        emit({"event": "done", "id": req.get("id"), "cancelled": True})
    except Exception as first_error:  # noqa: BLE001
        # A warm instance can be stale (e.g. text-encoder component reload
        # failed). Retry exactly once from a cold start before reporting.
        if _warm is None:
            emit({"event": "error", "id": req.get("id"), "message": str(first_error)})
            return
        print(f"warm generate failed ({first_error}); retrying cold", file=sys.stderr)
        _unload("refingerprint")
        try:
            _generate_once(req)
        except StopImageGenerationException:
            emit({"event": "done", "id": req.get("id"), "cancelled": True})
        except Exception as retry_error:  # noqa: BLE001
            emit({"event": "error", "id": req.get("id"), "message": str(retry_error)})


def _handle_hello():
    try:
        import importlib.metadata

        import mflux  # noqa: F401 — self-test the import inside the venv

        version = importlib.metadata.version("mflux")
    except Exception as exc:  # noqa: BLE001
        emit({"event": "fatal", "message": f"mflux import failed: {exc}"})
        sys.exit(1)
    emit({
        "event": "ready",
        "mflux_version": version,
        "python": sys.version.split()[0],
    })


def _reader():
    """stdin thread: cancel/ping act immediately, everything else queues
    behind the (possibly long-running) generate on the main thread."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = req.get("cmd")
        if cmd == "cancel":
            _cancel.set()
        elif cmd == "ping":
            emit({"event": "pong", "loaded": _warm is not None, "memory_gb": _memory_gb() if _warm else 0})
        else:
            _requests.put(req)
    _requests.put({"cmd": "quit"})  # stdin closed — parent app exited


def main():
    threading.Thread(target=_reader, daemon=True).start()
    while True:
        req = _requests.get()
        cmd = req.get("cmd")
        if cmd == "hello":
            _handle_hello()
        elif cmd == "generate":
            _handle_generate(req)
        elif cmd == "unload":
            _unload(req.get("reason", "eject"))
        elif cmd == "quit":
            return


if __name__ == "__main__":
    main()
