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

  # dynamically insert LoRAs (chained between the UNET and KSampler), repeatable:
  python3 scripts/comfy_dry_run.py --template t2i.json --param-map t2i.parammap.json \
      --params params.json --url http://localhost:8188 \
      --insert-lora 'krea2/Krea2-realism-V2.safetensors:0.8' \
      --insert-lora 'krea2/detail_slider_krea2_loraholic.safetensors:0.6'

  # LoRA no-op test (exercises the dynamic-insertion mechanism; the bogus-name
  # variant is expected to be rejected by the server, zero-strength to be a no-op):
  python3 scripts/comfy_dry_run.py --lora-test --template t2i.json \
      --param-map t2i.parammap.json --params params.json --url http://localhost:8188 \
      --lora <name.safetensors>
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
from urllib.parse import urlencode


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


def insert_loras(graph: dict, loras: list[tuple[str, float]]) -> list[str]:
    """Insert LoraLoaderModelOnly nodes chained between the UNETLoader and the
    KSampler.model, in the given order. This is the dynamic-insertion mechanism
    (no fixed slots, no neutralization) - the reference the Swift renderGraph
    must match. loras is a list of (name, strength_model) tuples.

    Returns the inserted node IDs (empty when no LoRAs; the KSampler is then
    wired straight to the UNET).
    """
    unet = next(nid for nid, n in graph.items() if n["class_type"] == "UNETLoader")
    ks = next(nid for nid, n in graph.items() if n["class_type"] == "KSampler")
    if not loras:
        graph[ks]["inputs"]["model"] = [unet, 0]
        return []
    prev = unet
    inserted: list[str] = []
    for i, (name, strength) in enumerate(loras):
        nid = f"lora_ins_{i}"
        graph[nid] = {
            "inputs": {"model": [prev, 0], "lora_name": name, "strength_model": float(strength)},
            "class_type": "LoraLoaderModelOnly",
            "_meta": {"title": f"LoRA {i + 1}: {name.rsplit('/', 1)[-1]}"},
        }
        inserted.append(nid)
        prev = nid
    graph[ks]["inputs"]["model"] = [prev, 0]
    return inserted


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
            filename = img["filename"]
            if Path(filename).is_absolute() or ".." in Path(filename).parts:
                raise ValueError(f"refusing to download image with unsafe filename: {filename!r}")
            path = url.rstrip("/") + "/view?" + urlencode(
                {"filename": filename, "subfolder": img.get("subfolder", ""),
                 "type": img.get("type", "output")}
            )
            dest = out_dir / filename
            dest.write_bytes(_http(path, timeout=120))
            saved.append(dest)
    return saved


def image_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_job(url: str, template: dict, param_map: dict, params: dict,
            image_path: str | None = None, out_dir: Path = Path("comfy_dry_run_out"),
            loras: list[tuple[str, float]] | None = None) -> list[Path]:
    if image_path:
        if "source_image" not in param_map:
            raise ValueError(
                "image_path given but the param map has no 'source_image' key; "
                "the image would be uploaded and then silently dropped (t2i template)"
            )
        params = dict(params)
        params["source_image"] = upload_image(url, Path(image_path))
    graph = inject(template, param_map, params)
    if loras:
        ins = insert_loras(graph, loras)
        print(f"[INFO] inserted {len(ins)} LoRA(s): {[(n, s) for n, s in loras]}", file=sys.stderr)
    prompt_id = submit(url, graph)
    print(f"submitted {prompt_id}", file=sys.stderr)
    entry = poll_history(url, prompt_id)
    saved = download_outputs(url, entry, out_dir)
    print(json.dumps({"prompt_id": prompt_id, "outputs": [str(p) for p in saved]}))
    return saved


def lora_test(url: str, template: dict, param_map: dict, params: dict, lora: str,
              out_dir: Path = Path("comfy_dry_run_out")):
    """Run 4 dynamic-insertion variants at a fixed seed and report which are clean no-ops.

    Uses insert_loras (the same mechanism as --insert-lora), applied via
    run_job(..., loras=...): (a) no LoRA (baseline; KSampler wired straight to the
    UNET), (b) a bogus LoRA name (the server should reject it -> recorded as an
    error, not a no-op), (c) the valid LoRA at strength 0 (expect a clean no-op,
    hash == (a)), (d) the valid LoRA at strength 1 (expect a distinct output).
    A non-baseline variant whose output hash equals (a) is a clean no-op.
    """
    seed = params.get("seed", 0)
    variants = {
        "a_no_lora": [],
        "b_bogus_name": [("definitely_not_a_real_lora.safetensors", 1.0)],
        "c_zero_strength": [(lora, 0.0)],
        "d_full_strength": [(lora, 1.0)],
    }
    results: dict[str, str | None] = {}
    for label, loras in variants.items():
        p = dict(params)
        p["seed"] = seed
        try:
            out = run_job(url, template, param_map, p, out_dir=out_dir / label, loras=loras)
        except Exception as e:
            # A server-rejected variant (e.g. the bogus name) must not crash the loop.
            results[label] = f"error: {e}"
            continue
        results[label] = image_hash(out[0]) if out else None
    base = results["a_no_lora"]
    clean = [label for label, h in results.items() if label != "a_no_lora" and h == base]
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
    ap.add_argument("--insert-lora", action="append", default=[], metavar="NAME:STRENGTH",
                    help="dynamically insert a LoraLoaderModelOnly between the UNET and KSampler "
                         "(repeatable), e.g. 'krea2/Krea2-realism-V2.safetensors:0.8'")
    ap.add_argument("--lora-test", action="store_true")
    ap.add_argument("--lora", default=None, help="test LoRA filename for --lora-test")
    args = ap.parse_args(argv)

    template = json.loads(Path(args.template).read_text())
    param_map = json.loads(Path(args.param_map).read_text())
    params = json.loads(Path(args.params).read_text())

    if args.lora_test:
        if not args.lora:
            ap.error("--lora-test requires --lora <name.safetensors>")
        lora_test(args.url, template, param_map, params, args.lora,
                  out_dir=Path(args.out_dir))
    else:
        loras = [(n, float(s)) for n, s in (x.split(":", 1) for x in args.insert_lora)]
        run_job(args.url, template, param_map, params, image_path=args.image,
                out_dir=Path(args.out_dir), loras=loras)


if __name__ == "__main__":
    main()
