#!/usr/bin/env python3
"""ComfyUI dry-run harness.

Loads a frozen API-format template ({nodeID: {class_type, inputs}}) plus a
param-map sidecar ({param: {node, input}}), fills the mapped inputs from a job's
params, and submits to a live ComfyUI server.

This is the reference implementation of the param-injection contract that the
Swift side (ComfyTemplate+Injection.renderGraph) must match. It is a dev tool,
not shipped in the app bundle.

Usage:
  # dry-run a t2i (or i2i, with --image) job:
  python3 scripts/comfy_dry_run.py --template t2i.json --param-map t2i.parammap.json \
      --params params.json --url http://localhost:8188 [--image src.png]

  # LoRA no-op test (determines the LoraMechanism for the 10-slot chain):
  python3 scripts/comfy_dry_run.py --lora-test --template t2i.json \
      --param-map t2i.parammap.json --params params.json --url http://localhost:8188 \
      --lora <name.safetensors> [--lora-on lora1_on --lora-name lora1_name \
      --lora-sm lora1_strength_model --lora-sc lora1_strength_clip]
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import sys
import time
import urllib.request
import uuid
from pathlib import Path


class ParamMapError(Exception):
    """A param map targets a node or input that is not in the template."""


def inject(template: dict, param_map: dict, params: dict) -> dict:
    """Fill each mapped input from params; return the /prompt-ready graph (a deep copy).

    A param present in the map but absent from `params` leaves its template value
    untouched (optional param). Raises ParamMapError if a mapped node or input is
    missing from the template (the #69 failure class: fail loudly, never silently).
    """
    graph = copy.deepcopy(template)
    for param, target in param_map.items():
        if param not in params:
            continue
        node_id = target["node"]
        input_name = target["input"]
        if node_id not in graph:
            raise ParamMapError(f"param {param!r} targets missing node {node_id!r}")
        if input_name not in graph[node_id]["inputs"]:
            raise ParamMapError(
                f"param {param!r} targets missing input {input_name!r} on node {node_id!r}"
            )
        graph[node_id]["inputs"][input_name] = params[param]
    return graph


# --- live transport (exercised in step 3 against a real server) --------------

def _http(url: str, data: bytes | None = None, method: str | None = None,
          headers: dict | None = None, timeout: int = 600) -> bytes:
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def submit(url: str, graph: dict) -> str:
    body = json.dumps({"prompt": graph, "client_id": str(uuid.uuid4())}).encode()
    raw = _http(url.rstrip("/") + "/prompt", data=body, method="POST",
                headers={"Content-Type": "application/json"}, timeout=60)
    return json.loads(raw)["prompt_id"]


def upload_image(url: str, path: Path) -> str:
    boundary = "----comfydryrun" + uuid.uuid4().hex
    body = bytearray()
    body += f"--{boundary}\r\n".encode()
    body += (
        f'Content-Disposition: form-data; name="image"; filename="{path.name}"\r\n'
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    body += path.read_bytes()
    body += f"\r\n--{boundary}--\r\n".encode()
    raw = _http(url.rstrip("/") + "/upload/image", data=bytes(body), method="POST",
                headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
                timeout=120)
    return json.loads(raw)["name"]


def poll_history(url: str, prompt_id: str, timeout_s: int = 1800) -> dict:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        entry = json.loads(_http(url.rstrip("/") + f"/history/{prompt_id}", timeout=30)).get(prompt_id)
        if entry:
            status = entry.get("status", {})
            if entry.get("outputs"):
                return entry
            if status.get("status_str") == "error":
                raise RuntimeError(f"prompt {prompt_id} failed: {json.dumps(entry.get('status'))}")
        time.sleep(1.0)
    raise TimeoutError(f"timed out waiting for {prompt_id}")


def download_outputs(url: str, entry: dict, out_dir: Path) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    saved: list[Path] = []
    for node_out in entry.get("outputs", {}).values():
        for img in node_out.get("images", []):
            path = (
                f"{url.rstrip('/')}/view?filename={img['filename']}"
                f"&subfolder={img.get('subfolder', '')}&type={img.get('type', 'output')}"
            )
            dest = out_dir / img["filename"]
            dest.write_bytes(_http(path, timeout=120))
            saved.append(dest)
    return saved


def image_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_job(url: str, template: dict, param_map: dict, params: dict,
            image_path: str | None = None, out_dir: Path = Path("comfy_dry_run_out")) -> list[Path]:
    if image_path:
        params = dict(params)
        params["source_image"] = upload_image(url, Path(image_path))
    graph = inject(template, param_map, params)
    prompt_id = submit(url, graph)
    print(f"submitted {prompt_id}", file=sys.stderr)
    entry = poll_history(url, prompt_id)
    saved = download_outputs(url, entry, out_dir)
    print(json.dumps({"prompt_id": prompt_id, "outputs": [str(p) for p in saved]}))
    return saved


def lora_test(url: str, template: dict, param_map: dict, params: dict, lora: str,
              on: str, name: str, sm: str, sc: str,
              out_dir: Path = Path("comfy_dry_run_out")):
    """Run 4 unused-slot variants at a fixed seed and report which are clean no-ops.

    (a) off, (b) on + empty name, (c) on + bogus name, (d) on + valid name + zero
    strength. A variant whose output hash equals (a) is a clean no-op; the cleanest
    one fixes the LoraMechanism for the Swift 10-slot chain.
    """
    seed = params.get("seed", 0)
    variants = {
        "a_off": {on: False},
        "b_on_empty_name": {on: True, name: ""},
        "c_on_bogus_name": {on: True, name: "definitely_not_a_real_lora.safetensors"},
        "d_on_zero_strength": {on: True, name: lora, sm: 0.0, sc: 0.0},
    }
    results: dict[str, str | None] = {}
    for label, extra in variants.items():
        p = dict(params)
        p["seed"] = seed
        p.update(extra)
        out = run_job(url, template, param_map, p, out_dir=out_dir / label)
        results[label] = image_hash(out[0]) if out else None
    base = results["a_off"]
    clean = [label for label, h in results.items() if label != "a_off" and h == base]
    print(json.dumps({"results": results, "base": base, "clean_noops": clean}, indent=2))
    return results, clean


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(description="ComfyUI dry-run harness")
    ap.add_argument("--template", required=True)
    ap.add_argument("--param-map", required=True)
    ap.add_argument("--params", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--image", default=None, help="source image for i2i (uploaded to the server)")
    ap.add_argument("--out-dir", default="comfy_dry_run_out")
    ap.add_argument("--lora-test", action="store_true")
    ap.add_argument("--lora", default=None, help="test LoRA filename for --lora-test")
    ap.add_argument("--lora-on", default="lora_on", help="param name for the slot on/off switch")
    ap.add_argument("--lora-name", default="lora_name", help="param name for the slot lora name")
    ap.add_argument("--lora-sm", default="lora_strength_model", help="param name for strength_model")
    ap.add_argument("--lora-sc", default="lora_strength_clip", help="param name for strength_clip")
    args = ap.parse_args(argv)

    template = json.loads(Path(args.template).read_text())
    param_map = json.loads(Path(args.param_map).read_text())
    params = json.loads(Path(args.params).read_text())

    if args.lora_test:
        if not args.lora:
            ap.error("--lora-test requires --lora <name.safetensors>")
        lora_test(args.url, template, param_map, params, args.lora,
                  args.lora_on, args.lora_name, args.lora_sm, args.lora_sc,
                  out_dir=Path(args.out_dir))
    else:
        run_job(args.url, template, param_map, params, image_path=args.image,
                out_dir=Path(args.out_dir))


if __name__ == "__main__":
    main()
