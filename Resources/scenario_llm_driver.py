"""Warm-LLM driver for the MLXBits Image Studio Scenario Generator.

Runs inside the mflux tool venv (uv makes mlx-lm / mlx-vlm available) and
keeps a Gemma text model resident between generations, so re-rolling a
scenario skips the model reload. One process per open popover; the app
terminates it when the popover closes.

Protocol: newline-delimited JSON. Requests on stdin (hello, generate, quit);
events on a private dup of stdout (ready, loading, loaded, result, error,
fatal). fd 1 is repointed at stderr so the libraries' own prints can't
corrupt the protocol stream.
"""

import json
import os
import sys
import time

_protocol = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)
sys.stdout = sys.stderr


def emit(obj):
    try:
        _protocol.write(json.dumps(obj) + "\n")
        _protocol.flush()
    except (BrokenPipeError, ValueError):
        os._exit(0)


# Resident model, or None. (path, backend, model, tok_or_proc)
_loaded = None


def _load(path):
    """Loads `path` via mlx-lm, falling back to mlx-vlm for VLM-only
    architectures (e.g. gemma4_unified). Caches by path."""
    global _loaded
    if _loaded is not None and _loaded[0] == path:
        return _loaded

    emit({"event": "loading"})
    started = time.monotonic()
    backend = "mlx_lm"
    try:
        from mlx_lm import load as lm_load

        model, tok = lm_load(path)
    except Exception as lm_error:  # noqa: BLE001
        msg = str(lm_error)
        if "not supported" not in msg and "Model type" not in msg:
            raise
        from mlx_vlm import load as vlm_load

        model, tok = vlm_load(path)
        backend = "mlx_vlm"

    _loaded = (path, backend, model, tok)
    emit({"event": "loaded", "backend": backend, "seconds": round(time.monotonic() - started, 2)})
    return _loaded


def _generate(req):
    _, backend, model, tok = _load(req["model"])
    prompt = req["prompt"]
    max_tokens = int(req.get("max_tokens", 8192))
    temp = float(req.get("temp", 0.7))

    if backend == "mlx_lm":
        from mlx_lm import generate as lm_generate
        from mlx_lm.sample_utils import make_sampler

        # Match the CLI: wrap the (already few-shot-formatted) prompt in the
        # tokenizer's chat template before generating.
        formatted = tok.apply_chat_template(
            [{"role": "user", "content": prompt}], add_generation_prompt=True, tokenize=False
        )
        result = lm_generate(
            model, tok, prompt=formatted, max_tokens=max_tokens,
            sampler=make_sampler(temp=temp), verbose=False,
        )
    else:
        from mlx_vlm import generate as vlm_generate
        from mlx_vlm.prompt_utils import apply_chat_template

        # Match the CLI: process the prompt through the model's chat template
        # (text-only, thinking channel off) before generating.
        formatted = apply_chat_template(tok, model.config, prompt, num_images=0, enable_thinking=False)
        result = vlm_generate(
            model, tok, prompt=formatted, image=None,
            max_tokens=max_tokens, temperature=temp, verbose=False,
        )

    # verbose=False returns the text; tolerate objects that wrap it.
    text = result if isinstance(result, str) else getattr(result, "text", str(result))
    emit({"event": "result", "text": text})


def _handle_hello():
    try:
        import importlib.metadata

        import mlx_lm  # noqa: F401 — self-test the import

        version = importlib.metadata.version("mlx-lm")
    except Exception as exc:  # noqa: BLE001
        emit({"event": "fatal", "message": f"mlx-lm import failed: {exc}"})
        sys.exit(1)
    emit({"event": "ready", "mlx_lm_version": version, "python": sys.version.split()[0]})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        cmd = req.get("cmd")
        if cmd == "hello":
            _handle_hello()
        elif cmd == "generate":
            try:
                _generate(req)
            except Exception as exc:  # noqa: BLE001
                emit({"event": "error", "message": str(exc)})
        elif cmd == "quit":
            return


if __name__ == "__main__":
    main()
