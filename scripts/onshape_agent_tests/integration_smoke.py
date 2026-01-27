import os
import sys
import time

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT))

from scripts.onshape_agent_tests._bootstrap import ensure_onshape_agent_on_path, ensure_onshape_oauth_env


DEFAULT_TEST_URL = (
    "https://cteinccsd.onshape.com/documents/89a3e2e598f9ad2ace0fb496/"
    "w/8c522fba543883263f4d1645/e/466338a94d244e8b3d9ca656"
)


def _ensure_env() -> None:
    ensure_onshape_oauth_env()


def _extract_feature_id(resp):
    if not isinstance(resp, dict):
        return None
    feature = resp.get("feature")
    if isinstance(feature, dict) and isinstance(feature.get("featureId"), str):
        return feature.get("featureId")
    # Some responses return a flat structure.
    if isinstance(resp.get("featureId"), str):
        return resp.get("featureId")
    return None


def main() -> int:
    _ensure_env()
    ensure_onshape_agent_on_path()

    url = os.environ.get("ONSHAPE_TEST_URL", "").strip() or DEFAULT_TEST_URL

    # Import after env is configured (CLIENT is initialized at import time).
    import onshape_mcp_server as m

    parsed = m.tool_onshape_parse_url({"url": url})
    if not isinstance(parsed, dict) or parsed.get("error"):
        raise RuntimeError(f"Failed to parse test URL: {parsed}")

    ctx = m.tool_onshape_set_context(
        {
            "did": parsed.get("did"),
            "wvm": parsed.get("wvm"),
            "wvmid": parsed.get("wvmid"),
            "eid": parsed.get("eid"),
            "base_url": parsed.get("base_url"),
        }
    )
    print("Context:", ctx)

    elements = m.tool_onshape_list_elements({})
    if isinstance(elements, dict) and elements.get("error"):
        raise RuntimeError(f"Failed to list elements: {elements}")
    print("Elements:", elements.get("count"))

    created_feature_ids = []
    try:
        # Plane coverage: direct + alias + case-insensitive.
        planes = ["Front", "Top", "Right", "xy", "XZ"]
        for idx, plane in enumerate(planes, start=1):
            sketch_name = f"BSmoke Sketch {int(time.time())}-{idx}"
            extrude_name = f"BSmoke Extrude {int(time.time())}-{idx}"

            sketch_resp = m.tool_cad_create_circle_sketch(
                {
                    "name": sketch_name,
                    "plane": plane,
                    "radius": "10 mm",
                    "x_center": 0,
                    "y_center": 0,
                }
            )
            sketch_fid = _extract_feature_id(sketch_resp)
            if not sketch_fid:
                raise RuntimeError(f"Sketch missing featureId (plane={plane}): {sketch_resp}")
            created_feature_ids.append(sketch_fid)

            extrude_resp = m.tool_cad_extrude_from_sketch(
                {
                    "name": extrude_name,
                    "sketch_feature_id": sketch_fid,
                    "depth": "5 mm",
                    "operation": "NEW",
                }
            )
            extrude_fid = _extract_feature_id(extrude_resp)
            if extrude_fid:
                created_feature_ids.append(extrude_fid)

        bbox = m.tool_onshape_get_partstudio_bounding_boxes({})
        if isinstance(bbox, dict) and bbox.get("error"):
            raise RuntimeError(f"Bounding boxes failed: {bbox}")
        print("Bounding boxes OK")

        shaded = m.tool_onshape_get_partstudio_shaded_views({})
        if isinstance(shaded, dict) and shaded.get("error"):
            raise RuntimeError(f"Shaded views failed: {shaded}")
        print("Shaded views OK")

    finally:
        # Best-effort cleanup: delete in reverse order so dependents are removed first.
        wid = m.STATE.wvmid if m.STATE.wvm == "w" else None
        eid = m.STATE.eid
        did = m.STATE.did
        if did and wid and eid:
            for fid in reversed(created_feature_ids):
                try:
                    m.tool_onshape_delete_partstudio_feature(
                        {"did": did, "wid": wid, "eid": eid, "feature_id": fid}
                    )
                except Exception as e:
                    print(f"Cleanup failed for {fid}: {e}", file=sys.stderr)

    print("Integration smoke test OK")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as e:
        msg = str(e)
        if "invalid_token" in msg or "401" in msg:
            print(
                "OnShape integration test failed due to expired/invalid OAuth token. "
                "Re-authorize in the app (Settings -> OnShape) or export ONSHAPE_OAUTH_CLIENT_ID/SECRET for refresh.",
                file=sys.stderr,
            )
        raise
