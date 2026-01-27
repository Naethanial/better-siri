#!/usr/bin/env python3

import sys
import argparse
import base64
import json
import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


REPO_ROOT = Path(__file__).resolve().parents[2]

# Ensure repo root is importable so `scripts.*` works when running by path.
sys.path.insert(0, str(REPO_ROOT))
CASES_DIR = Path(__file__).resolve().parent / "cases"
RUNS_DIR = Path(__file__).resolve().parent / "runs"


class LLMRunError(RuntimeError):
    def __init__(self, message: str, *, transcript: List[Dict[str, Any]], tool_calls: int, tool_errors: int):
        super().__init__(message)
        self.transcript = transcript
        self.tool_calls = tool_calls
        self.tool_errors = tool_errors


DEFAULT_TEST_URL = (
    "https://cteinccsd.onshape.com/documents/89a3e2e598f9ad2ace0fb496/"
    "w/8c522fba543883263f4d1645/e/466338a94d244e8b3d9ca656"
)


def _now_tag() -> str:
    return time.strftime("%Y%m%d_%H%M%S")


def _read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def _ensure_bootstrap() -> None:
    # Ensure we can import onshape_mcp_server from Resources.
    from scripts.onshape_agent_tests._bootstrap import ensure_onshape_agent_on_path, ensure_onshape_oauth_env

    ensure_onshape_oauth_env()
    ensure_onshape_agent_on_path()


def _load_onshape_module():
    import importlib

    return importlib.import_module("onshape_mcp_server")


def _openrouter_request(payload: Dict[str, Any], *, api_key: str, timeout_s: int = 120) -> Dict[str, Any]:
    url = "https://openrouter.ai/api/v1/chat/completions"
    data = json.dumps(payload, ensure_ascii=True).encode("utf-8")
    req = Request(url, data=data, method="POST")
    req.add_header("Authorization", f"Bearer {api_key}")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    req.add_header("X-Title", "BetterSiri Onshape Agent Tests")

    try:
        with urlopen(req, timeout=timeout_s) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)
    except HTTPError as e:
        body = ""
        try:
            body = e.read().decode("utf-8")
        except Exception:
            pass
        raise RuntimeError(f"OpenRouter HTTP {e.code}: {body[:800]}")
    except URLError as e:
        raise RuntimeError(f"OpenRouter request failed: {e}")


def _try_get_openrouter_api_key_from_app_defaults() -> Optional[str]:
    # BetterSiri stores the API key in macOS UserDefaults via @AppStorage("openrouter_apiKey").
    # We intentionally keep this best-effort + silent to avoid leaking secrets.
    try:
        p = subprocess.run(
            ["/usr/bin/defaults", "read", "com.bettersiri.app", "openrouter_apiKey"],
            check=False,
            capture_output=True,
            text=True,
        )
        if p.returncode != 0:
            return None
        key = (p.stdout or "").strip()
        return key or None
    except Exception:
        return None


def _tool_specs_from_onshape(m, *, allow: Optional[set[str]] = None) -> List[Dict[str, Any]]:
    # Convert MCP tool schemas into OpenAI-style tool specs.
    tools = []
    for t in getattr(m, "TOOLS", []):
        if not isinstance(t, dict):
            continue
        name = t.get("name")
        if not isinstance(name, str) or not name:
            continue
        if allow is not None and name not in allow:
            continue

        params = t.get("inputSchema") or {"type": "object"}
        if isinstance(params, dict):
            # Some providers (notably OpenAI) require object schemas to include `properties`.
            if params.get("type") == "object" and "properties" not in params:
                params = {**params, "properties": {}}
        else:
            params = {"type": "object", "properties": {}}

        tools.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "description": t.get("description") or t.get("title") or "",
                    "parameters": params,
                },
            }
        )
    return tools


def _encode_image_data_url(path: Path) -> str:
    ext = path.suffix.lower().lstrip(".")
    mime = {
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
    }.get(ext, "application/octet-stream")
    b64 = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:{mime};base64,{b64}"


def _quicklook_pdf_thumbnail(pdf_path: Path, *, out_dir: Path, size: int = 1024) -> Optional[Path]:
    # macOS QuickLook thumbnail generator.
    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(
            ["qlmanage", "-t", "-s", str(size), "-o", str(out_dir), str(pdf_path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return None

    # qlmanage produces <name>.png in out_dir.
    png = out_dir / (pdf_path.name + ".png")
    if png.exists():
        return png
    # Sometimes it strips the extension.
    alt = out_dir / (pdf_path.stem + ".png")
    if alt.exists():
        return alt
    return None


def _attachment_message_content(attachments: List[str], *, artifacts_dir: Path) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]]]:
    # Returns: (message_content_parts, attachment_debug)
    parts: List[Dict[str, Any]] = []
    debug: List[Dict[str, Any]] = []

    if not attachments:
        return parts, debug

    parts.append({"type": "text", "text": "Reference attachments (images included inline when possible):"})

    thumb_dir = artifacts_dir / "thumbnails"
    for raw in attachments:
        p = Path(raw)
        if not p.is_absolute():
            p = (REPO_ROOT / raw).resolve()
        info: Dict[str, Any] = {"path": str(p)}

        if not p.exists():
            parts.append({"type": "text", "text": f"- {raw}: missing at {p}"})
            info["missing"] = True
            debug.append(info)
            continue

        kind = p.suffix.lower().lstrip(".")
        parts.append({"type": "text", "text": f"- {p.name}"})

        img_path: Optional[Path] = None
        if kind in {"png", "jpg", "jpeg", "webp"}:
            img_path = p
        elif kind == "pdf":
            img_path = _quicklook_pdf_thumbnail(p, out_dir=thumb_dir)
            if img_path is not None:
                info["thumbnail"] = str(img_path)

        if img_path is not None and img_path.exists():
            parts.append({"type": "image_url", "image_url": {"url": _encode_image_data_url(img_path)}})
            info["image_included"] = True
        else:
            info["image_included"] = False

        debug.append(info)

    return parts, debug


def _system_prompt() -> str:
    # Aggressively enforce unit-safety + validation loops.
    return "\n".join(
        [
            "You are a CAD agent controlling Onshape via tools.",
            "Goal: create a competent parametric 3D model that matches the user request/drawing.",
            "",
            "Context:",
            "- Onshape context (did/wid/eid/base_url) is already set for you.",
            "- Do NOT use placeholder ids like <DID>/<WID>/<EID>. Omit did/wid/eid arguments unless you have real values.",
            "- Do NOT import attachments into Onshape. Treat them as reference images only.",
            "- Coordinate convention: Top plane is XY, +Z is extrude thickness. Use X for length, Y for width.",
            "",
            "Critical units rule:",
            "- For ANY non-zero length or coordinate, ALWAYS pass a string with explicit units, e.g. '10 mm' or '2 in'.",
            "- Only use bare numbers for exact 0.",
            "",
            "Sketching rules:",
            "- Never create an empty sketch. Every cad_create_sketch must include at least one entity (rectangle/circle/closed loop).",
            "- Prefer simple closed profiles (rectangles/circles) and multiple sketches.",
            "- Avoid combining an outer profile + hole circles in the same sketch if you plan to extrude,",
            "  because cad_extrude selects all sketch regions.",
            "  Instead: extrude the outer profile, then create separate hole sketches and extrude REMOVE/CUT THROUGH_ALL.",
            "- If you cannot confidently read dimensions from the drawing, choose reasonable defaults (e.g. 100-200 mm scale) rather than doing nothing.",
            "",
            "Iteration rules:",
            "- After major steps, call onshape_snapshot_partstudio and adjust if bounding box/shape is wrong.",
            "- If a tool errors, change the arguments and continue; never repeat the exact same failing call.",
            "- If you need a 10 mm thick plate centered on the Top plane, use cad_extrude with direction='SYMMETRIC' and depth='5 mm'.",
        ]
    )


def _mm(v_m: float) -> float:
    return v_m * 1000.0


def _bbox_mm(bbox: Dict[str, Any]) -> Optional[Dict[str, float]]:
    try:
        lx = float(bbox["lowX"])
        ly = float(bbox["lowY"])
        lz = float(bbox["lowZ"])
        hx = float(bbox["highX"])
        hy = float(bbox["highY"])
        hz = float(bbox["highZ"])
    except Exception:
        return None
    return {
        "x": _mm(hx - lx),
        "y": _mm(hy - ly),
        "z": _mm(hz - lz),
        "lowX": _mm(lx),
        "lowY": _mm(ly),
        "lowZ": _mm(lz),
        "highX": _mm(hx),
        "highY": _mm(hy),
        "highZ": _mm(hz),
    }


def _volume_m3(mass_props: Dict[str, Any]) -> Optional[float]:
    try:
        bodies = mass_props.get("bodies")
        if not isinstance(bodies, dict):
            return None
        if len(bodies) == 0:
            # Empty Part Studio (no bodies): treat as zero volume baseline.
            return 0.0
        all_body = bodies.get("-all-")
        if not isinstance(all_body, dict):
            return None
        vol = all_body.get("volume")
        if not isinstance(vol, list) or not vol:
            return None
        return float(vol[0])
    except Exception:
        return None


@dataclass
class CaseResult:
    case_id: str
    kind: str
    ok: bool
    error: Optional[str]
    tool_errors: int
    tool_calls: int
    snapshot: Optional[Dict[str, Any]]
    bbox_mm: Optional[Dict[str, float]]
    volume_m3: Optional[float]
    artifacts: Dict[str, Any]
    transcript: List[Dict[str, Any]]


def _check_case(case: Dict[str, Any], *, snapshot: Dict[str, Any]) -> Tuple[bool, List[str]]:
    failures: List[str] = []

    bbox = snapshot.get("bounding_boxes")
    bboxmm = _bbox_mm(bbox) if isinstance(bbox, dict) else None
    mp = snapshot.get("mass_properties")
    vol = _volume_m3(mp) if isinstance(mp, dict) else None

    checks = case.get("checks") or {}
    if not isinstance(checks, dict):
        checks = {}

    if checks.get("require_volume_positive") is True:
        if not vol or vol <= 0:
            failures.append("volume_not_positive")

    bbox_check = checks.get("bbox_mm")
    if isinstance(bbox_check, dict) and bboxmm is not None:
        for axis in ("x", "y", "z"):
            rng = bbox_check.get(axis)
            if not isinstance(rng, list) or len(rng) != 2:
                continue
            lo, hi = float(rng[0]), float(rng[1])
            val = float(bboxmm.get(axis, 0.0))
            if val < lo or val > hi:
                failures.append(f"bbox_{axis}_out_of_range:{val:.2f} not in [{lo:.2f},{hi:.2f}]")

    ok = len(failures) == 0
    return ok, failures


def _check_case_with_baseline(
    case: Dict[str, Any],
    *,
    before_snapshot: Dict[str, Any],
    after_snapshot: Dict[str, Any],
) -> Tuple[bool, List[str]]:
    ok_a, fail_a = _check_case(case, snapshot=after_snapshot)

    failures: List[str] = list(fail_a)

    checks = case.get("checks") or {}
    if not isinstance(checks, dict):
        checks = {}

    before_bboxmm = _bbox_mm(before_snapshot.get("bounding_boxes") or {})
    after_bboxmm = _bbox_mm(after_snapshot.get("bounding_boxes") or {})
    before_vol = _volume_m3(before_snapshot.get("mass_properties") or {})
    after_vol = _volume_m3(after_snapshot.get("mass_properties") or {})

    dv = None
    if before_vol is not None and after_vol is not None:
        dv = after_vol - before_vol

    dv_check = checks.get("delta_volume_m3")
    if isinstance(dv_check, list) and len(dv_check) == 2:
        lo, hi = float(dv_check[0]), float(dv_check[1])
        if dv is None:
            failures.append("delta_volume_missing")
        else:
            if dv < lo or dv > hi:
                failures.append(f"delta_volume_out_of_range:{dv:.8g} not in [{lo:.8g},{hi:.8g}]")

    db_check = checks.get("delta_bbox_mm")
    if isinstance(db_check, dict) and before_bboxmm and after_bboxmm:
        for axis in ("x", "y", "z"):
            rng = db_check.get(axis)
            if not isinstance(rng, list) or len(rng) != 2:
                continue
            lo, hi = float(rng[0]), float(rng[1])
            db = float(after_bboxmm.get(axis, 0.0)) - float(before_bboxmm.get(axis, 0.0))
            if db < lo or db > hi:
                failures.append(f"delta_bbox_{axis}_out_of_range:{db:.2f} not in [{lo:.2f},{hi:.2f}]")

    return len(failures) == 0, failures


def _diff_feature_ids(m, before: List[Dict[str, Any]], after: List[Dict[str, Any]]) -> List[str]:
    b = {f.get("featureId") for f in before if isinstance(f, dict)}
    a = [f.get("featureId") for f in after if isinstance(f, dict)]
    out: List[str] = []
    for fid in a:
        if isinstance(fid, str) and fid and fid not in b:
            out.append(fid)
    return out


def _cleanup_new_features(m, new_feature_ids: List[str]) -> None:
    did = m.STATE.did
    wid = m.STATE.wvmid if m.STATE.wvm == "w" else None
    eid = m.STATE.eid
    if not did or not wid or not eid:
        return
    for fid in reversed(new_feature_ids):
        try:
            m.tool_onshape_delete_partstudio_feature({"did": did, "wid": wid, "eid": eid, "feature_id": fid})
        except Exception:
            pass


def _run_direct_case(case: Dict[str, Any], *, m, artifacts_dir: Path) -> Tuple[int, int, List[Dict[str, Any]]]:
    calls = case.get("tool_calls")
    if not isinstance(calls, list):
        raise RuntimeError("direct case missing tool_calls")

    tool_errors = 0
    tool_calls = 0
    transcript: List[Dict[str, Any]] = []

    vars: Dict[str, str] = {}

    def extract_feature_id(resp: Any) -> Optional[str]:
        if not isinstance(resp, dict):
            return None
        feature = resp.get("feature")
        if isinstance(feature, dict) and isinstance(feature.get("featureId"), str):
            return feature.get("featureId")
        if isinstance(resp.get("featureId"), str):
            return resp.get("featureId")
        return None

    def subst(value: Any) -> Any:
        if isinstance(value, str):
            if value.startswith("${") and value.endswith("}"):
                key = value[2:-1]
                return vars.get(key, value)
            return value
        if isinstance(value, list):
            return [subst(v) for v in value]
        if isinstance(value, dict):
            return {k: subst(v) for k, v in value.items()}
        return value

    for c in calls:
        if not isinstance(c, dict):
            continue
        name = c.get("name")
        args = subst(c.get("arguments") or {})
        if not isinstance(name, str) or not isinstance(args, dict):
            continue
        tool_calls += 1
        transcript.append({"type": "tool_call", "name": name, "arguments": args})
        try:
            payload = m.TOOL_HANDLERS[name](args)
            transcript.append({"type": "tool_result", "name": name, "ok": True})

            save_key = c.get("save_feature_id_as")
            if isinstance(save_key, str) and save_key:
                fid = extract_feature_id(payload)
                if isinstance(fid, str) and fid:
                    vars[save_key] = fid
                    transcript.append({"type": "var", "name": save_key, "value": fid})
            # Copy file artifacts (e.g. GLB) into the run folder if present.
            if name in {"onshape_export_partstudio_gltf", "onshape_snapshot_partstudio"}:
                path = None
                if isinstance(payload, dict):
                    if isinstance(payload.get("path"), str):
                        path = payload.get("path")
                    elif isinstance(payload.get("gltf"), dict) and isinstance(payload["gltf"].get("path"), str):
                        path = payload["gltf"].get("path")
                if path and Path(path).exists():
                    dest = artifacts_dir / Path(path).name
                    shutil.copy2(path, dest)
        except Exception as e:
            tool_errors += 1
            transcript.append({"type": "tool_result", "name": name, "ok": False, "error": str(e)})
            raise

    return tool_errors, tool_calls, transcript


def _run_llm_case(
    case: Dict[str, Any],
    *,
    m,
    artifacts_dir: Path,
    api_key: str,
    model: str,
    max_tool_iters: int,
) -> Tuple[int, int, List[Dict[str, Any]]]:
    allow = {
        # High-level CAD
        "cad_create_sketch",
        "cad_extrude",
        "cad_create_circle_sketch",
        "cad_extrude_from_sketch",
        "cad_create_cylinder",
        "cad_create_cube",
        "cad_fillet",
        "cad_chamfer",
        "cad_svg_to_sketch",
        # Validation
        "onshape_get_features_summary",
        "onshape_get_partstudio_bounding_boxes",
        "onshape_get_partstudio_mass_properties",
        "onshape_snapshot_partstudio",
        "onshape_snapshot_element",
        "onshape_create_assembly",
        "onshape_get_document_workspaces",
        "onshape_switch_to_element",
        "onshape_get_element_metadata",
        "onshape_insert_instance",
        "onshape_transform_instance",
        "onshape_add_mate",
        "onshape_get_assembly_definition",
        "onshape_get_parts",
        "cad_revolve",
        "cad_sweep",
        "cad_loft",
        "cad_mirror",
        "cad_pattern_linear",
        "cad_pattern_circular",
        "cad_hole",
        "cad_draft",
        "cad_thicken",
        "cad_split",
        "cad_transform_part",
        "cad_shell",
        "cad_boolean",
        "cad_create_plane",
        "cad_create_partstudio",
    }
    tools = _tool_specs_from_onshape(m, allow=allow)
    transcript: List[Dict[str, Any]] = []

    prompt = case.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        raise RuntimeError("llm case missing prompt")

    attachments = case.get("attachments") or []
    if not isinstance(attachments, list):
        attachments = []

    att_parts, att_debug = _attachment_message_content([str(x) for x in attachments], artifacts_dir=artifacts_dir)

    messages: List[Dict[str, Any]] = [
        {"role": "system", "content": _system_prompt()},
        {
            "role": "user",
            "content": [
                {"type": "text", "text": prompt.strip()},
                *att_parts,
            ],
        },
    ]
    transcript.append({"type": "attachments", "debug": att_debug})

    tool_errors = 0
    tool_calls = 0

    def extract_feature_id(resp: Any) -> Optional[str]:
        if not isinstance(resp, dict):
            return None
        feature = resp.get("feature")
        if isinstance(feature, dict) and isinstance(feature.get("featureId"), str):
            return feature.get("featureId")
        if isinstance(resp.get("featureId"), str):
            return resp.get("featureId")
        return None

    def tool_payload_for_model(tool_name: str, payload: Any) -> Any:
        # Keep tool outputs compact and easy for the model to chain.
        if tool_name in {
            "cad_create_sketch",
            "cad_create_circle_sketch",
            "cad_create_cube",
            "cad_extrude",
            "cad_extrude_from_sketch",
            "cad_create_cylinder",
            "cad_fillet",
            "cad_chamfer",
        }:
            fid = extract_feature_id(payload)
            if tool_name == "cad_create_sketch":
                return {"sketch_feature_id": fid, "raw_type": "feature"}
            if tool_name in {"cad_extrude", "cad_extrude_from_sketch"}:
                return {"extrude_feature_id": fid, "raw_type": "feature"}
            return {"feature_id": fid, "raw_type": "feature"}

        if tool_name == "onshape_snapshot_partstudio" and isinstance(payload, dict):
            bbox = payload.get("bounding_boxes")
            mp = payload.get("mass_properties")
            gltf = payload.get("gltf")
            out: Dict[str, Any] = {}
            if isinstance(bbox, dict):
                out["bounding_boxes_m"] = bbox
            v = _volume_m3(mp) if isinstance(mp, dict) else None
            if v is not None:
                out["volume_m3"] = v
            if isinstance(gltf, dict) and isinstance(gltf.get("path"), str):
                out["gltf_path"] = gltf.get("path")
            return out

        return payload

    def validate_tool_call(name: str, args: Dict[str, Any]) -> Optional[str]:
        if name == "cad_create_sketch":
            lines = args.get("lines") or []
            circles = args.get("circles") or []
            rects = args.get("rectangles") or []
            if not (isinstance(lines, list) and lines) and not (isinstance(circles, list) and circles) and not (
                isinstance(rects, list) and rects
            ):
                return (
                    "cad_create_sketch requires at least one entity. Provide non-empty rectangles/circles/lines using unit-suffixed strings. "
                    "Example rectangle: {\"name\":\"Base\",\"plane\":\"Top\",\"rectangles\":[{\"x1\":\"-75 mm\",\"y1\":\"-40 mm\",\"x2\":\"75 mm\",\"y2\":\"40 mm\"}]}. "
                    "Example holes: {\"name\":\"Holes\",\"plane\":\"Top\",\"circles\":[{\"cx\":\"-38.1 mm\",\"cy\":\"-12.7 mm\",\"radius\":\"2.5 mm\"}]}."
                )

        if name in {"cad_extrude", "cad_extrude_from_sketch"}:
            depth = args.get("depth")
            direction = (args.get("direction") or "").upper()
            if direction == "THROUGH_ALL":
                return None
            if isinstance(depth, str):
                if depth.strip() == "0" or depth.strip().startswith("0 "):
                    return "Extrude depth must be > 0 with explicit units, e.g. '3 mm'."
                return None
            return "Extrude depth must be a string with explicit units, e.g. '3 mm'."

        return None

    for _iter in range(max_tool_iters):
        payload = {
            "model": model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            "temperature": 0.2,
            "reasoning": {"max_tokens": 2000},
            "thinking_level": "high",
        }
        resp = _openrouter_request(payload, api_key=api_key)
        msg = (((resp.get("choices") or [None])[0]) or {}).get("message") or {}
        content = msg.get("content")
        if content:
            transcript.append({"type": "assistant", "content": content if isinstance(content, str) else "<non-string>"})

        calls = msg.get("tool_calls") or []
        if not isinstance(calls, list) or not calls:
            return tool_errors, tool_calls, transcript

        messages.append({"role": "assistant", "content": content or "", "tool_calls": calls})

        for call in calls:
            tool_calls += 1
            fn = (call.get("function") or {}) if isinstance(call, dict) else {}
            name = fn.get("name")
            args_raw = fn.get("arguments")
            if not isinstance(name, str) or name not in m.TOOL_HANDLERS:
                tool_errors += 1
                messages.append({"role": "tool", "tool_call_id": call.get("id"), "content": json.dumps({"error": f"Unknown tool: {name}"})})
                transcript.append({"type": "tool_call", "name": name, "ok": False, "error": "unknown_tool"})
                continue

            try:
                args = json.loads(args_raw) if isinstance(args_raw, str) and args_raw.strip() else {}
                if not isinstance(args, dict):
                    args = {}
            except Exception:
                args = {}

            # Never allow the model to override the active Onshape context.
            for k in ("did", "wid", "eid", "wvm", "wvmid", "base_url"):
                if k in args:
                    args.pop(k, None)

            transcript.append({"type": "tool_call", "name": name, "arguments": args})

            try:
                validation_error = validate_tool_call(name, args)
                if validation_error:
                    tool_errors += 1
                    transcript.append({"type": "tool_result", "name": name, "ok": False, "error": validation_error})
                    messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": call.get("id"),
                            "content": json.dumps({"error": validation_error}, ensure_ascii=True),
                        }
                    )
                    continue

                payload = m.TOOL_HANDLERS[name](args)
                transcript.append({"type": "tool_result", "name": name, "ok": True})

                # Persist file artifacts when possible.
                path = None
                if isinstance(payload, dict):
                    if isinstance(payload.get("path"), str):
                        path = payload.get("path")
                    elif isinstance(payload.get("gltf"), dict) and isinstance(payload["gltf"].get("path"), str):
                        path = payload["gltf"].get("path")
                if path and Path(path).exists():
                    dest = artifacts_dir / Path(path).name
                    shutil.copy2(path, dest)

                model_payload = tool_payload_for_model(name, payload)
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call.get("id"),
                        "content": json.dumps(model_payload, ensure_ascii=True),
                    }
                )
            except Exception as e:
                tool_errors += 1
                err_payload = {"error": str(e)}
                transcript.append({"type": "tool_result", "name": name, "ok": False, "error": str(e)})
                messages.append({"role": "tool", "tool_call_id": call.get("id"), "content": json.dumps(err_payload, ensure_ascii=True)})

    raise LLMRunError(
        f"Exceeded max_tool_iters={max_tool_iters}",
        transcript=transcript,
        tool_calls=tool_calls,
        tool_errors=tool_errors,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases-dir", default=str(CASES_DIR))
    ap.add_argument("--kind", choices=["direct", "llm", "all"], default="all")
    ap.add_argument("--case", dest="case_id", default=None)
    ap.add_argument("--max-tool-iters", type=int, default=10)
    ap.add_argument("--keep", action="store_true", help="Do not delete created features")
    ap.add_argument(
        "--no-temp-partstudio",
        action="store_true",
        help="Run in the existing Part Studio instead of creating a fresh one per case.",
    )
    args = ap.parse_args()

    _ensure_bootstrap()
    m = _load_onshape_module()

    test_url = os.environ.get("ONSHAPE_TEST_URL", "").strip() or DEFAULT_TEST_URL
    parsed = m.tool_onshape_parse_url({"url": test_url})
    if not isinstance(parsed, dict) or parsed.get("error"):
        raise RuntimeError(f"Failed to parse ONSHAPE_TEST_URL: {parsed}")
    m.tool_onshape_set_context(
        {
            "did": parsed.get("did"),
            "wvm": parsed.get("wvm"),
            "wvmid": parsed.get("wvmid"),
            "eid": parsed.get("eid"),
            "base_url": parsed.get("base_url"),
        }
    )

    base_did = m.STATE.did
    base_wid = m.STATE.wvmid if m.STATE.wvm == "w" else None
    base_eid = m.STATE.eid
    base_url = parsed.get("base_url")
    if not base_did or not base_wid or not base_eid:
        raise RuntimeError("Missing Onshape did/wid/eid after setting context")

    case_dir = Path(args.cases_dir)
    case_paths = sorted(case_dir.glob("*.json"))
    if args.case_id:
        case_paths = [p for p in case_paths if p.stem == args.case_id]

    if not case_paths:
        raise RuntimeError(f"No cases found in {case_dir}")

    api_key = (os.environ.get("OPENROUTER_API_KEY") or "").strip()
    if not api_key:
        api_key = _try_get_openrouter_api_key_from_app_defaults() or ""
    model = (os.environ.get("OPENROUTER_MODEL") or "").strip() or "openai/gpt-4o-mini"

    run_dir = RUNS_DIR / _now_tag()
    artifacts_root = run_dir / "artifacts"
    _write_json(run_dir / "run_meta.json", {"onshape_url": test_url, "openrouter_model": model})

    results: List[Dict[str, Any]] = []
    suite_failures = 0

    try:
        before = m.tool_onshape_get_features_summary({}).get("features", [])
        if not isinstance(before, list):
            before = []
    except Exception as e:
        msg = str(e)
        if "invalid_token" in msg or "401" in msg:
            print(
                "Onshape auth failed (invalid/expired OAuth token). "
                "Re-authorize in the app (Settings -> OnShape) or set onshape_oauthClientId/onshape_oauthClientSecret in app Settings for refresh.\n"
                f"Error: {msg}"
            )
            return 2
        raise

    for cp in case_paths:
        case = _read_json(cp)
        case_id = case.get("id") or cp.stem
        kind = case.get("kind") or "llm"
        if args.kind != "all" and kind != args.kind:
            continue
        if kind == "llm" and not api_key:
            print(f"SKIP {case_id}: OPENROUTER_API_KEY not set")
            continue

        case_artifacts = artifacts_root / case_id
        case_artifacts.mkdir(parents=True, exist_ok=True)

        print(f"RUN  {case_id} ({kind})")
        t0 = time.time()

        temp_eid: Optional[str] = None
        if not args.no_temp_partstudio:
            # Create a fresh Part Studio per case for isolation.
            try:
                created = m.tool_onshape_request(
                    {
                        "method": "POST",
                        "path": f"partstudios/d/{base_did}/w/{base_wid}",
                        "body": {"name": f"Eval {case_id} {int(time.time())}"},
                    }
                )
                if isinstance(created, dict) and isinstance(created.get("id"), str):
                    temp_eid = created.get("id")
            except Exception:
                temp_eid = None

        if temp_eid:
            m.tool_onshape_set_context(
                {
                    "did": base_did,
                    "wvm": "w",
                    "wvmid": base_wid,
                    "eid": temp_eid,
                    "base_url": base_url,
                }
            )
            before = []
        else:
            # Ensure we're on the base element.
            m.tool_onshape_set_context(
                {
                    "did": base_did,
                    "wvm": "w",
                    "wvmid": base_wid,
                    "eid": base_eid,
                    "base_url": base_url,
                }
            )

        baseline_snapshot: Optional[Dict[str, Any]] = None

        ok = False
        err: Optional[str] = None
        tool_errors = 0
        tool_calls = 0
        transcript: List[Dict[str, Any]] = []
        snapshot: Optional[Dict[str, Any]] = None
        bboxmm: Optional[Dict[str, float]] = None
        vol: Optional[float] = None
        artifacts: Dict[str, Any] = {}

        try:
            baseline_snapshot = m.tool_onshape_snapshot_partstudio({})

            if kind == "direct":
                te, tc, tr = _run_direct_case(case, m=m, artifacts_dir=case_artifacts)
                tool_errors += te
                tool_calls += tc
                transcript.extend(tr)
            elif kind == "llm":
                try:
                    te, tc, tr = _run_llm_case(
                        case,
                        m=m,
                        artifacts_dir=case_artifacts,
                        api_key=api_key,
                        model=model,
                        max_tool_iters=args.max_tool_iters,
                    )
                    tool_errors += te
                    tool_calls += tc
                    transcript.extend(tr)
                except LLMRunError as e:
                    # Preserve partial transcript/counters for debugging.
                    tool_errors += int(getattr(e, "tool_errors", 0))
                    tool_calls += int(getattr(e, "tool_calls", 0))
                    transcript.extend(getattr(e, "transcript", []) or [])
                    raise
            else:
                raise RuntimeError(f"Unknown kind: {kind}")

            snapshot = m.tool_onshape_snapshot_partstudio({})
            if isinstance(snapshot, dict):
                bboxmm = _bbox_mm(snapshot.get("bounding_boxes") or {})
                vol = _volume_m3(snapshot.get("mass_properties") or {})
                gltf = snapshot.get("gltf")
                if isinstance(gltf, dict) and isinstance(gltf.get("path"), str):
                    src = Path(gltf["path"])
                    if src.exists():
                        dest = case_artifacts / src.name
                        shutil.copy2(src, dest)
                        artifacts["gltf"] = str(dest)

            ok, failures = _check_case_with_baseline(
                case,
                before_snapshot=baseline_snapshot if isinstance(baseline_snapshot, dict) else {},
                after_snapshot=snapshot if isinstance(snapshot, dict) else {},
            )
            if failures:
                err = ";".join(failures)

        except Exception as e:
            ok = False
            err = str(e)

        elapsed_s = time.time() - t0

        new_feature_ids: List[str] = []
        if temp_eid:
            # Delete the whole temp element (fast, clean).
            if not args.keep:
                try:
                    m.tool_onshape_request({"method": "DELETE", "path": f"elements/d/{base_did}/w/{base_wid}/e/{temp_eid}"})
                except Exception:
                    pass
            # Restore base context for next iteration.
            m.tool_onshape_set_context(
                {
                    "did": base_did,
                    "wvm": "w",
                    "wvmid": base_wid,
                    "eid": base_eid,
                    "base_url": base_url,
                }
            )
            before = []
        else:
            after = m.tool_onshape_get_features_summary({}).get("features", [])
            if not isinstance(after, list):
                after = []
            new_feature_ids = _diff_feature_ids(m, before, after)
            if not args.keep:
                _cleanup_new_features(m, new_feature_ids)
            before = m.tool_onshape_get_features_summary({}).get("features", [])
            if not isinstance(before, list):
                before = []

        res = CaseResult(
            case_id=str(case_id),
            kind=str(kind),
            ok=bool(ok),
            error=err,
            tool_errors=int(tool_errors),
            tool_calls=int(tool_calls),
            snapshot=snapshot if isinstance(snapshot, dict) else None,
            bbox_mm=bboxmm,
            volume_m3=vol,
            artifacts=artifacts,
            transcript=transcript,
        )

        out = {
            **res.__dict__,
            "baseline_snapshot": baseline_snapshot if isinstance(baseline_snapshot, dict) else None,
            "elapsed_s": elapsed_s,
            "new_feature_ids": new_feature_ids,
        }
        _write_json(run_dir / "cases" / f"{case_id}.result.json", out)
        results.append(out)

        status = "OK" if ok else "FAIL"
        print(f"{status}  {case_id}  tool_calls={tool_calls} tool_errors={tool_errors} elapsed={elapsed_s:.1f}s")
        if not ok:
            suite_failures += 1

    _write_json(run_dir / "report.json", {"results": results, "failures": suite_failures})
    print(f"\nSuite complete. failures={suite_failures} report={run_dir / 'report.json'}")
    return 0 if suite_failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
