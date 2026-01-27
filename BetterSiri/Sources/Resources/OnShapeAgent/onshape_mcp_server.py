#!/usr/bin/env python3

import base64
import hashlib
import hmac
import json
import math
import os
import re
import sys
import tempfile
import time
import traceback
import uuid
from dataclasses import dataclass
from email.utils import formatdate
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional
from urllib.parse import urlencode, urlparse, urljoin
from urllib.request import Request, build_opener, HTTPRedirectHandler
from urllib.error import HTTPError, URLError

# --- Helper Utilities ---

def _encode_multipart_form(fields: Dict[str, Any], *, file_field: str, file_name: str, file_bytes: bytes) -> Dict[str, Any]:
    boundary = "----bettersiriOnshapeBoundary" + uuid.uuid4().hex
    lines: List[bytes] = []
    def _add(s: str) -> None: lines.append(s.encode("utf-8"))
    for key, value in fields.items():
        if value is None: continue
        value_str = "true" if isinstance(value, bool) else str(value)
        _add(f"--{boundary}\r\n")
        _add(f'Content-Disposition: form-data; name="{key}"\r\n\r\n')
        _add(value_str + "\r\n")
    _add(f"--{boundary}\r\n")
    _add(f'Content-Disposition: form-data; name="{file_field}"; filename="{file_name}"\r\n')
    _add("Content-Type: application/octet-stream\r\n\r\n")
    lines.append(file_bytes)
    _add("\r\n")
    _add(f"--{boundary}--\r\n")
    return {"content_type": f"multipart/form-data; boundary={boundary}", "body": b"".join(lines)}

_JSON_STDOUT = sys.stdout
sys.stdout = sys.stderr

def _write(obj: Dict[str, Any]) -> None:
    _JSON_STDOUT.write(json.dumps(obj, ensure_ascii=True, separators=(",", ":")) + "\n")
    _JSON_STDOUT.flush()

def _text_result(payload: Any, *, is_error: bool = False) -> Dict[str, Any]:
    return {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=True)}], "isError": is_error}

def _error_result(message: str, *, data: Optional[Any] = None) -> Dict[str, Any]:
    payload: Dict[str, Any] = {"error": message}
    if data is not None: payload["data"] = data
    return _text_result(payload, is_error=True)

def _get_env(name: str) -> str: return (os.environ.get(name) or "").strip()

def _safe_int(value: Any, default: int) -> int:
    try: return int(value)
    except: return default

@dataclass
class OnShapeContext:
    did: Optional[str] = None
    wvm: Optional[str] = None
    wvmid: Optional[str] = None
    eid: Optional[str] = None
    base_url: Optional[str] = None

STATE = OnShapeContext()

class OnShapeClient:
    def __init__(self) -> None:
        self.access_key = _get_env("ONSHAPE_ACCESS_KEY")
        self.secret_key = _get_env("ONSHAPE_SECRET_KEY")
        self.base_url = _get_env("ONSHAPE_BASE_URL") or "https://cad.onshape.com/api"
        self.api_version = _get_env("ONSHAPE_API_VERSION") or "v13"
        self.oauth_base_url = _get_env("ONSHAPE_OAUTH_BASE_URL") or "https://oauth.onshape.com"
        self.oauth_client_id = _get_env("ONSHAPE_OAUTH_CLIENT_ID")
        self.oauth_client_secret = _get_env("ONSHAPE_OAUTH_CLIENT_SECRET")
        self.oauth_token_file = _get_env("ONSHAPE_OAUTH_TOKEN_FILE")
        self.access_token = None
        auth_mode_env = (_get_env("ONSHAPE_AUTH_MODE") or "").lower()
        if auth_mode_env: self.auth_mode = auth_mode_env
        else:
            if self.oauth_token_file and Path(self.oauth_token_file).exists(): self.auth_mode = "oauth"
            else: self.auth_mode = "signature"

    def _oauth_token_path(self) -> Optional[Path]: return Path(self.oauth_token_file) if self.oauth_token_file else None
    
    def _load_oauth_token(self) -> Optional[Dict[str, Any]]:
        path = self._oauth_token_path()
        if not path or not path.exists(): return None
        try: return json.loads(path.read_text(encoding="utf-8"))
        except: return None

    def _save_oauth_token(self, token: Dict[str, Any]) -> None:
        path = self._oauth_token_path()
        if not path: return
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(token, ensure_ascii=True), encoding="utf-8")

    def _oauth_access_token(self) -> str:
        token = self._load_oauth_token()
        access = (token or {}).get("accessToken") or (token or {}).get("access_token")
        if not access: raise RuntimeError("Missing OAuth access token.")
        return access.strip()

    def _refresh_oauth_token(self) -> None:
        token = self._load_oauth_token()
        refresh_token = (token or {}).get("refreshToken") or (token or {}).get("refresh_token")
        if not refresh_token: raise RuntimeError("OAuth refresh token missing")
        body = urlencode({"grant_type": "refresh_token", "refresh_token": refresh_token, "client_id": self.oauth_client_id, "client_secret": self.oauth_client_secret}).encode("utf-8")
        req = Request(urljoin(self.oauth_base_url.rstrip("/") + "/", "oauth/token"), data=body, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        with build_opener().open(req, timeout=30) as resp:
            obj = json.loads(resp.read().decode("utf-8"))
            updated = {"accessToken": obj.get("access_token"), "refreshToken": obj.get("refresh_token") or refresh_token, "tokenType": obj.get("token_type"), "expiresAt": time.time() + float(obj.get("expires_in", 0))}
            self._save_oauth_token(updated)

    def _require_auth(self) -> None:
        if self.auth_mode == "oauth" and (self.access_token or self._load_oauth_token()): return
        if not self.access_key or not self.secret_key: raise RuntimeError("Missing OnShape credentials.")

    def _make_headers(self, method: str, url: str, *, content_type: str, accept: str = "application/json") -> Dict[str, str]:
        headers = {"Accept": accept, "Content-Type": content_type, "User-Agent": "BetterSiri-OnShapeMCP/0.1"}
        if self.auth_mode == "oauth":
            headers["Authorization"] = f"Bearer {self.access_token or self._oauth_access_token()}"
            return headers
        self._require_auth()
        if self.auth_mode == "basic":
            headers["Authorization"] = f"Basic {base64.b64encode(f'{self.access_key}:{self.secret_key}'.encode('utf-8')).decode('utf-8')}"
            return headers
        nonce, auth_date = uuid.uuid4().hex, formatdate(timeval=None, localtime=False, usegmt=True)
        parsed = urlparse(url)
        canonical = (method + "\n" + nonce + "\n" + auth_date + "\n" + content_type + "\n" + parsed.path + "\n" + (parsed.query or "") + "\n").lower()
        signature = base64.b64encode(hmac.new(self.secret_key.encode("utf-8"), canonical.encode("utf-8"), hashlib.sha256).digest()).decode("utf-8")
        headers.update({"Date": auth_date, "On-Nonce": nonce, "Authorization": f"On {self.access_key}:HmacSHA256:{signature}"})
        return headers

    def _request(self, method: str, path: str, *, query: Optional[Dict[str, Any]] = None, body: Optional[Any] = None, accept: str = "application/json") -> Any:
        base = self.base_url.rstrip("/")
        if "/api/v" in base: url = base + "/" + path.lstrip("/")
        else: url = base + f"/{self.api_version}/" + path.lstrip("/")
        if query: url += "?" + urlencode(query)
        return self._request_raw(method, url, body=body, accept=accept)

    def _request_raw(self, method: str, url: str, *, body: Optional[Any] = None, accept: str = "application/json") -> Any:
        data = json.dumps(body, ensure_ascii=True).encode("utf-8") if body is not None else None
        current_url = url
        for _ in range(4):
            try:
                req = Request(current_url, data=data, method=method.upper())
                for k, v in self._make_headers(method, current_url, content_type="application/json", accept=accept).items(): req.add_header(k, v)
                with build_opener().open(req, timeout=60) as resp:
                    raw = resp.read()
                    if not raw: return {}
                    text = raw.decode("utf-8", errors="replace")
                    try: return json.loads(text)
                    except: return {"raw": text}
            except HTTPError as e:
                if e.code in (301, 302, 303, 307, 308):
                    current_url = urljoin(current_url, e.headers.get("Location", ""))
                    continue
                if e.code == 401 and self.auth_mode == "oauth":
                    try: self._refresh_oauth_token(); continue
                    except: pass
                raise RuntimeError(f"OnShape HTTP {e.code}: {e.read().decode('utf-8', errors='replace')}")
        raise RuntimeError("OnShape request failed")

    def _request_bytes(self, method: str, url: str, *, body: Optional[Any] = None, accept: str = "*/*") -> bytes:
        data = json.dumps(body, ensure_ascii=True).encode("utf-8") if body is not None else None
        current_url = url
        for _ in range(4):
            try:
                req = Request(current_url, data=data, method=method.upper())
                for k, v in self._make_headers(method, current_url, content_type="application/json", accept=accept).items(): req.add_header(k, v)
                with build_opener().open(req, timeout=60) as resp: return resp.read()
            except HTTPError as e:
                if e.code in (301, 302, 303, 307, 308):
                    current_url = urljoin(current_url, e.headers.get("Location", ""))
                    continue
                raise RuntimeError(f"OnShape HTTP {e.code}")
        raise RuntimeError("OnShape request failed")

    def get_document(self, did: str) -> Any: return self._request("GET", f"documents/{did}")
    def get_translation(self, translation_id: str) -> Any: return self._request("GET", f"translations/{translation_id}")
    def list_elements(self, did: str, wvm: str, wvmid: str) -> Any: return self._request("GET", f"documents/d/{did}/{wvm}/{wvmid}/elements")
    def get_partstudio_features(self, did: str, wvm: str, wvmid: str, eid: str) -> Any: return self._request("GET", f"partstudios/d/{did}/{wvm}/{wvmid}/e/{eid}/features", query={"rollbackBarIndex": -1})
    def get_partstudio_featurespecs(self, did: str, wvm: str, wvmid: str, eid: str) -> Any: return self._request("GET", f"partstudios/d/{did}/{wvm}/{wvmid}/e/{eid}/featurespecs")
    def get_partstudio_boundingboxes(self, did: str, wvm: str, wvmid: str, eid: str) -> Any: return self._request("GET", f"partstudios/d/{did}/{wvm}/{wvmid}/e/{eid}/boundingboxes")
    def get_partstudio_massproperties(self, did: str, wvm: str, wvmid: str, eid: str, configuration: str = "") -> Any: return self._request("GET", f"partstudios/d/{did}/{wvm}/{wvmid}/e/{eid}/massproperties", query={"configuration": configuration} if configuration else None)
    def get_variables(self, did: str, wv: str, wvid: str, eid: str, configuration: str = "") -> Any: return self._request("GET", f"variables/d/{did}/{wv}/{wvid}/e/{eid}/variables", query={"configuration": configuration} if configuration else None)
    def set_variables(self, did: str, wid: str, eid: str, variables: List[Dict[str, Any]]) -> Any: return self._request("POST", f"variables/d/{did}/w/{wid}/e/{eid}/variables", body=variables)
    
    def add_partstudio_feature(self, did: str, wvm: str, wvmid: str, eid: str, body: Dict[str, Any]) -> Any:
        if wvm == "w":
            try:
                meta = self.list_elements(did, wvm, wvmid)
                mv = next((el.get("microversionId") for el in meta if el.get("id") == eid), None) if isinstance(meta, list) else None
                if mv: body["sourceMicroversion"] = mv
            except: pass
        if "feature" in body and not body.get("btType"): body["btType"] = "BTFeatureDefinitionCall-1406"
        resp = self._request("POST", f"partstudios/d/{did}/{wvm}/{wvmid}/e/{eid}/features", body=body)
        if isinstance(resp, dict) and resp.get("feature"):
            f = resp["feature"]
            return {"featureId": f.get("featureId"), "status": "created", "name": f.get("name")}
        return resp

    def update_partstudio_feature(self, did: str, wid: str, eid: str, fid: str, body: Dict[str, Any]) -> Any: return self._request("POST", f"partstudios/d/{did}/w/{wid}/e/{eid}/features/featureid/{fid}", body=body)
    def delete_partstudio_feature(self, did: str, wid: str, eid: str, fid: str) -> Any: return self._request("DELETE", f"partstudios/d/{did}/w/{wid}/e/{eid}/features/featureid/{fid}")
    def eval_featurescript(self, did: str, wvm: str, wvmid: str, eid: str, body: Dict[str, Any], **kwargs) -> Any:
        q = {"rollbackBarIndex": kwargs.get("rollback_bar_index", -1)}
        if kwargs.get("configuration"): q["configuration"] = kwargs["configuration"]
        if kwargs.get("element_microversion_id"): q["elementMicroversionId"] = kwargs["element_microversion_id"]
        return self._request("POST", f"partstudios/d/{did}/{wvm}/{wvmid}/e/{eid}/featurescript", query=q, body=body)

CLIENT = OnShapeClient()

# --- Common Helper Logic ---

def _ctx_get(arg: Dict[str, Any], key: str) -> Optional[str]:
    v = arg.get(key)
    return str(v).strip() if v and str(v).strip() else None

def _ensure_query(q: Optional[str]) -> str:
    if not q: return ""
    qs = str(q).strip().upper()
    mapping = {
        "X": 'query=qIntersection([qCreatedBy(makeId("Top"), EntityType.FACE), qCreatedBy(makeId("Front"), EntityType.FACE)]);',
        "Y": 'query=qIntersection([qCreatedBy(makeId("Front"), EntityType.FACE), qCreatedBy(makeId("Right"), EntityType.FACE)]);',
        "Z": 'query=qIntersection([qCreatedBy(makeId("Top"), EntityType.FACE), qCreatedBy(makeId("Right"), EntityType.FACE)]);',
        "TOP": 'query=qCreatedBy(makeId("Top"), EntityType.FACE);',
        "FRONT": 'query=qCreatedBy(makeId("Front"), EntityType.FACE);',
        "RIGHT": 'query=qCreatedBy(makeId("Right"), EntityType.FACE);'
    }
    if qs in mapping: return mapping[qs]
    raw = str(q)
    if raw.isalnum() and len(raw) >= 20: return f'query=qFeature(id + "{raw}");'
    if raw.startswith("query="): return raw
    return f"query={raw}"

def _parse_length_m(value: Any) -> float:
    if isinstance(value, (int, float)): return float(value)
    if not isinstance(value, str): return 0.0
    s = value.strip().lower()
    if not s: return 0.0
    units = {"mm": 0.001, "cm": 0.01, "m": 1.0, "in": 0.0254, "ft": 0.3048}
    for u, factor in units.items():
        if s.endswith(u):
            try: return float(s[:-len(u)].strip()) * factor
            except: pass
    try: return float(s)
    except: return 0.0

def _require_workspace_context(did, wid, eid):
    if not did or not eid or not wid: raise RuntimeError("Missing context (did/wid/eid)")

# --- Tool Implementations ---

def tool_onshape_parse_url(args):
    url = _ctx_get(args, "url")
    if not url: return {"error": "Missing url"}
    parsed = urlparse(url)
    path = parsed.path or ""
    patterns = [
        re.compile(r"/documents/(?P<did>[A-Za-z0-9]{24})/(?P<wvm>w|v|m)/(?P<wvmid>[A-Za-z0-9]{24})(?:/e/(?P<eid>[A-Za-z0-9]{24}))?"),
        re.compile(r"/d/(?P<did>[A-Za-z0-9]{24})/(?P<wvm>w|v|m)/(?P<wvmid>[A-Za-z0-9]{24})(?:/e/(?P<eid>[A-Za-z0-9]{24}))?"),
    ]
    for p in patterns:
        m = p.search(path)
        if m:
            res = {k: v for k, v in m.groupdict().items() if v}
            res["base_url"] = f"{parsed.scheme}://{parsed.netloc}/api"
            return res
    return {"error": "Invalid URL"}

def tool_onshape_set_context(args):
    for k in ["did", "wvm", "wvmid", "eid"]:
        v = _ctx_get(args, k)
        if v: setattr(STATE, k, v)
    if _ctx_get(args, "base_url"): CLIENT.base_url = args["base_url"]
    return tool_onshape_get_context({})

def tool_onshape_get_context(args):
    return {"did": STATE.did, "wvm": STATE.wvm, "wvmid": STATE.wvmid, "eid": STATE.eid, "base_url": CLIENT.base_url}

def tool_cad_create_partstudio(args):
    did, wid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None)
    if not did or not wid: return {"error": "Missing context"}
    resp = CLIENT._request("POST", f"partstudios/d/{did}/w/{wid}", body={"name": args.get("name") or "Part Studio 1"})
    if isinstance(resp, dict) and resp.get("id"):
        STATE.eid = resp["id"]
        return {"id": resp["id"], "name": resp.get("name"), "status": "created_and_active"}
    return resp

def tool_onshape_create_assembly(args):
    did, wid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None)
    if not did or not wid: return {"error": "Missing context"}
    resp = CLIENT._request("POST", f"assemblies/d/{did}/w/{wid}", body={"name": args.get("name") or "Assembly 1"})
    if isinstance(resp, dict) and resp.get("id"):
        STATE.eid = resp["id"]
        return {"id": resp["id"], "name": resp.get("name"), "status": "created_and_active"}
    return resp

def tool_onshape_switch_to_element(args):
    eid = _ctx_get(args, "eid") or _ctx_get(args, "element_id")
    if not eid: return {"error": "Missing eid"}
    STATE.eid = eid
    return {"eid": STATE.eid, "status": "active", "type": "CONTEXT_SWITCH"}

def tool_cad_create_sketch(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    if not did or not wid or not eid: return {"error": "Missing context"}
    plane = args.get("plane") or "Top"
    entities = []
    for line in args.get("lines", []):
        x1, y1, x2, y2 = _parse_length_m(line.get("x1")), _parse_length_m(line.get("y1")), _parse_length_m(line.get("x2")), _parse_length_m(line.get("y2"))
        entities.append({"btType": "BTMSketchCurveSegment-155", "geometry": {"btType": "BTCurveGeometryLine-117", "pntX": x1, "pntY": y1, "dirX": x2-x1, "dirY": y2-y1}, "startParam": 0, "endParam": 1, "entityId": uuid.uuid4().hex[:8], "isConstruction": line.get("construction", False)})
    for circ in args.get("circles", []):
        cx, cy, r = _parse_length_m(circ.get("cx", 0)), _parse_length_m(circ.get("cy", 0)), _parse_length_m(circ.get("radius"))
        entities.append({"btType": "BTMSketchCurve-4", "geometry": {"btType": "BTCurveGeometryCircle-115", "radius": r, "xCenter": cx, "yCenter": cy, "xDir": 1.0, "yDir": 0.0, "clockwise": False}, "entityId": uuid.uuid4().hex[:8], "isConstruction": circ.get("construction", False)})
    for rect in args.get("rectangles", []):
        x1, y1, x2, y2 = _parse_length_m(rect.get("x1")), _parse_length_m(rect.get("y1")), _parse_length_m(rect.get("x2")), _parse_length_m(rect.get("y2"))
        corners = [(x1, y1), (x2, y1), (x2, y2), (x1, y2)]
        for i in range(4):
            px, py = corners[i]
            nx, ny = corners[(i + 1) % 4]
            entities.append({"btType": "BTMSketchCurveSegment-155", "geometry": {"btType": "BTCurveGeometryLine-117", "pntX": px, "pntY": py, "dirX": nx-px, "dirY": ny-py}, "startParam": 0, "endParam": 1, "entityId": uuid.uuid4().hex[:8]})
    body = {"feature": {"btType": "BTMSketch-151", "featureType": "newSketch", "name": args.get("name") or "Sketch", "parameters": [{"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": _ensure_query(plane)}], "parameterId": "sketchPlane"}], "entities": entities}}
    return CLIENT.add_partstudio_feature(did, "w", wid, eid, body)

def tool_cad_extrude(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    if not did or not wid or not eid: return {"error": "Missing context"}
    op = (args.get("operation") or "NEW").upper()
    params = [
        {"btType": "BTMParameterEnum-145", "value": "SOLID", "enumName": "ExtendedToolBodyType", "parameterId": "bodyType"},
        {"btType": "BTMParameterEnum-145", "value": op, "enumName": "NewBodyOperationType", "parameterId": "operationType"},
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualSketchRegionQuery-140", "featureId": args["sketch_feature_id"]}], "parameterId": "entities"}
    ]
    bound = (args.get("direction") or "BLIND").upper()
    params.append({"btType": "BTMParameterEnum-145", "value": bound, "enumName": "ExtendedBoundingType", "parameterId": "endBound"})
    if bound != "THROUGH_ALL": params.append({"btType": "BTMParameterQuantity-147", "expression": args.get("depth") or "10 mm", "parameterId": "depth"})
    body = {"feature": {"btType": "BTMFeature-134", "featureType": "extrude", "name": args.get("name") or "Extrude", "parameters": params}}
    return CLIENT.add_partstudio_feature(did, "w", wid, eid, body)

def tool_cad_revolve(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    if not did or not wid or not eid: return {"error": "Missing context"}
    body = {"feature": {"btType": "BTMFeature-134", "featureType": "revolve", "name": args.get("name") or "Revolve", "parameters": [
        {"btType": "BTMParameterEnum-145", "value": "SOLID", "enumName": "ExtendedToolBodyType", "parameterId": "bodyType"},
        {"btType": "BTMParameterEnum-145", "value": (args.get("operation") or "NEW").upper(), "enumName": "NewBodyOperationType", "parameterId": "operationType"},
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualSketchRegionQuery-140", "featureId": args["sketch_feature_id"]}], "parameterId": "entities"},
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": _ensure_query(args["axis_query"])}], "parameterId": "revolveAxis"},
        {"btType": "BTMParameterEnum-145", "value": "FULL", "enumName": "RevolveType", "parameterId": "revolveType"}
    ]}}
    return CLIENT.add_partstudio_feature(did, "w", wid, eid, body)

def tool_cad_fillet(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    body = {"feature": {"btType": "BTMFeature-134", "featureType": "fillet", "name": args.get("name") or "Fillet", "parameters": [
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": f'query=qCreatedBy(makeId("{args["feature_id"]}"), EntityType.EDGE);'}], "parameterId": "entities"},
        {"btType": "BTMParameterQuantity-147", "expression": args.get("radius") or "2 mm", "parameterId": "radius"}
    ]}}
    return CLIENT.add_partstudio_feature(did, "w", wid, eid, body)

def tool_cad_chamfer(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    body = {"feature": {"btType": "BTMFeature-134", "featureType": "chamfer", "name": args.get("name") or "Chamfer", "parameters": [
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": f'query=qCreatedBy(makeId("{args["feature_id"]}"), EntityType.EDGE);'}], "parameterId": "entities"},
        {"btType": "BTMParameterEnum-145", "value": "EQUAL_OFFSETS", "enumName": "ChamferType", "parameterId": "chamferType"},
        {"btType": "BTMParameterQuantity-147", "expression": args.get("distance") or "1 mm", "parameterId": "width"}
    ]}}
    return CLIENT.add_partstudio_feature(did, "w", wid, eid, body)

def tool_cad_shell(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    body = {"feature": {"btType": "BTMFeature-134", "featureType": "shell", "name": args.get("name") or "Shell", "parameters": [{"btType": "BTMParameterQuantity-147", "expression": args.get("thickness") or "2 mm", "parameterId": "thickness"}]}}
    if args.get("face_query"): body["feature"]["parameters"].append({"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": _ensure_query(args["face_query"])}], "parameterId": "faces"})
    return CLIENT.add_partstudio_feature(did, "w", wid, eid, body)

def tool_cad_boolean(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    body = {"feature": {"btType": "BTMFeature-134", "featureType": "boolean", "name": args.get("name") or "Boolean", "parameters": [
        {"btType": "BTMParameterEnum-145", "value": (args.get("operation") or "UNION").upper(), "enumName": "BooleanOperationType", "parameterId": "operationType"},
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": _ensure_query(args["tools_query"])}], "parameterId": "tools"}
    ]}}
    return CLIENT.add_partstudio_feature(did, "w", wid, eid, body)

def tool_cad_create_plane(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    body = {"feature": {"btType": "BTMFeature-134", "featureType": "cPlane", "name": args.get("name") or "Plane", "parameters": [
        {"btType": "BTMParameterEnum-145", "value": "OFFSET", "enumName": "CPlaneType", "parameterId": "cplaneType"},
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": _ensure_query(args.get("base_query") or "Top")}], "parameterId": "entities"},
        {"btType": "BTMParameterQuantity-147", "expression": args.get("offset") or "10 mm", "parameterId": "offset"}
    ]}}
    return CLIENT.add_partstudio_feature(did, "w", wid, eid, body)

def tool_onshape_add_mate(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    mate_type = (args.get("mate_type") or "FASTENED").upper()
    body = {"feature": {"btType": "BTMFeature-134", "featureType": "mate", "name": args.get("name") or f"{mate_type} Mate", "parameters": [
        {"btType": "BTMParameterEnum-145", "value": mate_type, "enumName": "MateType", "parameterId": "mateType"},
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": _ensure_query(args["query1"])}], "parameterId": "mateConnector1"},
        {"btType": "BTMParameterQueryList-148", "queries": [{"btType": "BTMIndividualQuery-138", "queryString": _ensure_query(args["query2"])}], "parameterId": "mateConnector2"}
    ]}}
    return CLIENT._request("POST", f"assemblies/d/{did}/w/{wid}/e/{eid}/features", body=body)

def tool_onshape_list_elements(args):
    did, wvm, wvmid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wvm") or STATE.wvm, _ctx_get(args, "wvmid") or STATE.wvmid
    if not did or not wvm or not wvmid: return {"error": "Missing context"}
    els = CLIENT.list_elements(did, wvm, wvmid)
    return {"elements": [{"id": e.get("id"), "name": e.get("name"), "type": e.get("elementType")} for e in els] if isinstance(els, list) else els}

def tool_onshape_snapshot_element(args):
    did, wvm, wvmid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wvm") or STATE.wvm, _ctx_get(args, "wvmid") or STATE.wvmid, _ctx_get(args, "eid") or STATE.eid
    if not did or not wvm or not wvmid or not eid: return {"error": "Missing context"}
    el_type = _ctx_get(args, "element_type")
    if not el_type:
        els = CLIENT.list_elements(did, wvm, wvmid)
        el_type = next((e.get("elementType") for e in els if e.get("id") == eid), "PARTSTUDIO") if isinstance(els, list) else "PARTSTUDIO"
    prefix = "assemblies" if el_type == "ASSEMBLY" else "partstudios"
    bbox = CLIENT._request("GET", f"{prefix}/d/{did}/{wvm}/{wvmid}/e/{eid}/boundingboxes")
    mass = CLIENT.get_partstudio_massproperties(did, wvm, wvmid, eid, configuration=args.get("configuration", ""))
    return {"did": did, "eid": eid, "type": el_type, "bounding_boxes": bbox, "mass_properties": mass}

def tool_cad_create_cylinder(args):
    res = tool_cad_create_sketch({"name": "Cyl Sketch", "plane": args.get("plane", "Top"), "circles": [{"radius": args["radius"]}]})
    sid = res.get("featureId")
    if not sid: return res
    return tool_cad_extrude({"sketch_feature_id": sid, "depth": args["depth"], "name": args.get("name", "Cylinder")})

def tool_onshape_get_feature_id_by_name(args):
    did, wvm, wvmid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wvm") or STATE.wvm, _ctx_get(args, "wvmid") or STATE.wvmid, _ctx_get(args, "eid") or STATE.eid
    feats = CLIENT.get_partstudio_features(did, wvm, wvmid, eid)
    if isinstance(feats, dict) and "features" in feats:
        for f in feats["features"]:
            if f.get("name") == args["name"]: return {"featureId": f.get("featureId"), "name": args["name"]}
    return {"error": "Feature not found"}

def tool_onshape_delete_partstudio_feature(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    return CLIENT.delete_partstudio_feature(did, wid, eid, args["feature_id"])

def tool_onshape_get_element_metadata(args):
    did, wvm, wvmid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wvm") or STATE.wvm, _ctx_get(args, "wvmid") or STATE.wvmid, _ctx_get(args, "eid") or STATE.eid
    if not did or not wvm or not wvmid or not eid: return {"error": "Missing context"}
    return CLIENT._request("GET", f"metadata/d/{did}/{wvm}/{wvmid}/e/{eid}")

def tool_onshape_insert_instance(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    source_eid = _ctx_get(args, "source_eid")
    if not did or not wid or not eid or not source_eid: return {"error": "Missing context or source_eid"}
    body = {"documentId": did, "elementId": source_eid, "isWholePartStudio": True}
    return CLIENT._request("POST", f"assemblies/d/{did}/w/{wid}/e/{eid}/instances", body=body)

def tool_onshape_transform_instance(args):
    did, wid, eid = _ctx_get(args, "did") or STATE.did, _ctx_get(args, "wid") or (STATE.wvmid if STATE.wvm == "w" else None), _ctx_get(args, "eid") or STATE.eid
    instance_id = _ctx_get(args, "instance_id")
    transform = args.get("transform")
    if not did or not wid or not eid or not instance_id or not transform: return {"error": "Missing context, instance_id, or transform"}
    body = {"occurrences": [{"path": [instance_id]}], "transform": transform, "isRelative": args.get("isRelative", False)}
    return CLIENT._request("POST", f"assemblies/d/{did}/w/{wid}/e/{eid}/transformoccurrences", body=body)

# --- MCP Registration ---

TOOLS = [
    {"name": "onshape_parse_url", "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]}},
    {"name": "onshape_set_context", "inputSchema": {"type": "object", "properties": {"did": {"type": "string"}, "wvm": {"type": "string"}, "wvmid": {"type": "string"}, "eid": {"type": "string"}}}},
    {"name": "onshape_get_context", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "onshape_list_elements", "inputSchema": {"type": "object", "properties": {"did": {"type": "string"}, "wvmid": {"type": "string"}}}},
    {"name": "onshape_switch_to_element", "inputSchema": {"type": "object", "properties": {"eid": {"type": "string"}}, "required": ["eid"]}},
    {"name": "onshape_get_element_metadata", "inputSchema": {"type": "object", "properties": {"eid": {"type": "string"}}, "required": ["eid"]}},
    {"name": "onshape_get_parts", "inputSchema": {"type": "object", "properties": {"eid": {"type": "string"}}}},
    {"name": "onshape_get_features_summary", "inputSchema": {"type": "object", "properties": {"eid": {"type": "string"}}}},
    {"name": "onshape_get_feature_id_by_name", "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}},
    {"name": "onshape_delete_partstudio_feature", "inputSchema": {"type": "object", "properties": {"feature_id": {"type": "string"}}, "required": ["feature_id"]}},
    {"name": "onshape_snapshot_element", "inputSchema": {"type": "object", "properties": {"eid": {"type": "string"}}}},
    {"name": "cad_create_partstudio", "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}}},
    {"name": "onshape_create_assembly", "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}}},
    {"name": "onshape_insert_instance", "inputSchema": {"type": "object", "properties": {"source_eid": {"type": "string"}}, "required": ["source_eid"]}},
    {"name": "onshape_transform_instance", "inputSchema": {"type": "object", "properties": {"instance_id": {"type": "string"}, "transform": {"type": "array", "items": {"type": "number"}}}, "required": ["instance_id", "transform"]}},
    {"name": "onshape_add_mate", "inputSchema": {"type": "object", "properties": {"query1": {"type": "string"}, "query2": {"type": "string"}}, "required": ["query1", "query2"]}},
    {"name": "cad_create_sketch", "inputSchema": {"type": "object", "properties": {"plane": {"type": "string"}, "lines": {"type": "array"}, "circles": {"type": "array"}, "rectangles": {"type": "array"}}}},
    {"name": "cad_extrude", "inputSchema": {"type": "object", "properties": {"sketch_feature_id": {"type": "string"}, "depth": {"type": "string"}}, "required": ["sketch_feature_id"]}},
    {"name": "cad_revolve", "inputSchema": {"type": "object", "properties": {"sketch_feature_id": {"type": "string"}, "axis_query": {"type": "string"}}, "required": ["sketch_feature_id", "axis_query"]}},
    {"name": "cad_fillet", "inputSchema": {"type": "object", "properties": {"feature_id": {"type": "string"}, "radius": {"type": "string"}}, "required": ["feature_id"]}},
    {"name": "cad_chamfer", "inputSchema": {"type": "object", "properties": {"feature_id": {"type": "string"}, "distance": {"type": "string"}}, "required": ["feature_id"]}},
    {"name": "cad_shell", "inputSchema": {"type": "object", "properties": {"thickness": {"type": "string"}}}},
    {"name": "cad_boolean", "inputSchema": {"type": "object", "properties": {"tools_query": {"type": "string"}}, "required": ["tools_query"]}},
    {"name": "cad_create_plane", "inputSchema": {"type": "object", "properties": {"offset": {"type": "string"}}}},
    {"name": "cad_create_cylinder", "inputSchema": {"type": "object", "properties": {"radius": {"type": "string"}, "depth": {"type": "string"}}, "required": ["radius", "depth"]}},
]

TOOL_HANDLERS = {
    "onshape_parse_url": tool_onshape_parse_url, "onshape_set_context": tool_onshape_set_context, "onshape_get_context": tool_onshape_get_context,
    "onshape_list_elements": tool_onshape_list_elements, "onshape_switch_to_element": tool_onshape_switch_to_element,
    "onshape_get_element_metadata": tool_onshape_get_element_metadata, "onshape_get_parts": lambda a: CLIENT._request("GET", f"parts/d/{_ctx_get(a,'did') or STATE.did}/{_ctx_get(a,'wvm') or STATE.wvm}/{_ctx_get(a,'wvmid') or STATE.wvmid}/e/{_ctx_get(a,'eid') or STATE.eid}"),
    "onshape_get_features_summary": lambda a: CLIENT.get_partstudio_features(_ctx_get(a,'did') or STATE.did, _ctx_get(a,'wvm') or STATE.wvm, _ctx_get(a,'wvmid') or STATE.wvmid, _ctx_get(a,'eid') or STATE.eid),
    "onshape_get_feature_id_by_name": tool_onshape_get_feature_id_by_name, "onshape_delete_partstudio_feature": tool_onshape_delete_partstudio_feature,
    "onshape_snapshot_element": tool_onshape_snapshot_element, "cad_create_partstudio": tool_cad_create_partstudio, "onshape_create_assembly": tool_onshape_create_assembly,
    "onshape_insert_instance": tool_onshape_insert_instance, "onshape_transform_instance": tool_onshape_transform_instance, "onshape_add_mate": tool_onshape_add_mate,
    "cad_create_sketch": tool_cad_create_sketch, "cad_extrude": tool_cad_extrude, "cad_revolve": tool_cad_revolve, "cad_fillet": tool_cad_fillet,
    "cad_chamfer": tool_cad_chamfer, "cad_shell": tool_cad_shell, "cad_boolean": tool_cad_boolean, "cad_create_plane": tool_cad_create_plane, "cad_create_cylinder": tool_cad_create_cylinder
}

def handle_tools_call(req_id, params):
    handler = TOOL_HANDLERS.get(params.get("name"))
    if not handler: return {"jsonrpc": "2.0", "id": req_id, "result": _error_result(f"Unknown tool: {params.get('name')}")}
    try: return {"jsonrpc": "2.0", "id": req_id, "result": _text_result(handler(params.get("arguments", {})))}
    except Exception as e: return {"jsonrpc": "2.0", "id": req_id, "result": _error_result(str(e), data={"traceback": traceback.format_exc()})}

def main():
    handlers = {"initialize": lambda rid, p: {"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}}, "serverInfo": {"name": "onshape-mcp", "version": "0.1.0"}}}, "tools/list": lambda rid, p: {"jsonrpc": "2.0", "id": rid, "result": {"tools": TOOLS}}, "tools/call": handle_tools_call, "ping": lambda rid, p: {"jsonrpc": "2.0", "id": rid, "result": {}}}
    for line in sys.stdin:
        if not line.strip(): continue
        try:
            msg = json.loads(line)
            h = handlers.get(msg.get("method"))
            if h: _write(h(msg.get("id"), msg.get("params")))
        except: pass

if __name__ == "__main__":
    try: main()
    except KeyboardInterrupt: pass
