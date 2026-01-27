#!/usr/bin/env python3
"""
Wrench creation test v2 - using native sketch features with proper closed profiles.

A wrench needs:
1. Handle (rectangle)
2. Head (circular with jaw cutout)
3. Extrude the profile
4. Optional: fillets on edges
"""

import os
import sys
import json
import math
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
    if isinstance(resp.get("featureId"), str):
        return resp.get("featureId")
    return None


def setup_context(m, url):
    parsed = m.tool_onshape_parse_url({"url": url})
    if not isinstance(parsed, dict) or parsed.get("error"):
        raise RuntimeError(f"Failed to parse test URL: {parsed}")

    ctx = m.tool_onshape_set_context({
        "did": parsed.get("did"),
        "wvm": parsed.get("wvm"),
        "wvmid": parsed.get("wvmid"),
        "eid": parsed.get("eid"),
        "base_url": parsed.get("base_url"),
    })
    print(f"Context: did={ctx['did']}, wvmid={ctx['wvmid']}, eid={ctx['eid']}")
    return ctx


def cleanup_features(m, feature_ids):
    wid = m.STATE.wvmid if m.STATE.wvm == "w" else None
    eid = m.STATE.eid
    did = m.STATE.did
    
    for fid in reversed(feature_ids):
        try:
            m.tool_onshape_delete_partstudio_feature({
                "did": did, "wid": wid, "eid": eid, "feature_id": fid
            })
            print(f"  Deleted feature {fid}")
        except Exception as e:
            print(f"  Failed to delete {fid}: {e}")


def create_wrench_sketch(m, name="Wrench Profile"):
    """
    Create a wrench outline sketch using polyline + arc.
    
    Wrench dimensions (in meters):
    - Handle length: 150mm = 0.15m
    - Handle width: 20mm = 0.02m  
    - Head diameter: 30mm = 0.03m
    - Jaw opening: 12mm = 0.012m
    - Jaw depth: 10mm = 0.01m
    """
    
    # Dimensions in meters
    handle_length = 0.12  # 120mm
    handle_width = 0.018  # 18mm
    head_radius = 0.018   # 18mm radius = 36mm diameter
    jaw_opening = 0.010   # 10mm
    jaw_depth = 0.012     # 12mm
    
    # Key points (origin at left end of handle)
    # Handle corners
    h_left = 0
    h_right = handle_length
    h_top = handle_width / 2
    h_bottom = -handle_width / 2
    
    # Head center
    head_cx = handle_length + head_radius * 0.7
    head_cy = 0
    
    # Create sketch entities
    # We'll use line segments to form a closed wrench profile
    
    entities = []
    entity_id = 0
    
    def add_line(x1, y1, x2, y2):
        nonlocal entity_id
        entity_id += 1
        dx = x2 - x1
        dy = y2 - y1
        length = math.sqrt(dx*dx + dy*dy)
        if length < 1e-9:
            return None
        return {
            "btType": "BTMSketchCurveSegment-155",
            "geometry": {
                "btType": "BTCurveGeometryLine-117",
                "pntX": x1,
                "pntY": y1,
                "dirX": dx,
                "dirY": dy,
            },
            "startParam": 0,
            "endParam": 1,
            "entityId": f"line{entity_id}",
        }
    
    def add_arc(cx, cy, radius, start_angle, end_angle):
        """Add an arc. Angles in radians, counterclockwise from +X axis."""
        nonlocal entity_id
        entity_id += 1
        return {
            "btType": "BTMSketchCurve-4",
            "geometry": {
                "btType": "BTCurveGeometryCircle-115",
                "radius": radius,
                "xCenter": cx,
                "yCenter": cy,
                "xDir": 1,
                "yDir": 0,
                "clockwise": False,
            },
            "centerId": f"arc{entity_id}.center",
            "entityId": f"arc{entity_id}",
            # For partial arcs we'd need BTMSketchCurveSegment with start/end params
        }
    
    def add_circle(cx, cy, radius):
        nonlocal entity_id
        entity_id += 1
        return {
            "btType": "BTMSketchCurve-4",
            "geometry": {
                "btType": "BTCurveGeometryCircle-115",
                "radius": radius,
                "xCenter": cx,
                "yCenter": cy,
                "xDir": 1,
                "yDir": 0,
                "clockwise": False,
            },
            "centerId": f"circle{entity_id}.center",
            "entityId": f"circle{entity_id}",
        }
    
    # Simple approach: rectangle for handle + offset circle for head
    # They will union when extruded
    
    # Handle rectangle (4 lines forming closed loop)
    lines = [
        add_line(h_left, h_bottom, h_right, h_bottom),      # bottom
        add_line(h_right, h_bottom, h_right, h_top),        # right
        add_line(h_right, h_top, h_left, h_top),            # top
        add_line(h_left, h_top, h_left, h_bottom),          # left (closes)
    ]
    entities.extend([l for l in lines if l])
    
    # Head circle (overlapping with handle end)
    entities.append(add_circle(head_cx, head_cy, head_radius))
    
    did = m.STATE.did
    wid = m.STATE.wvmid
    eid = m.STATE.eid
    
    sketch_body = {
        "btType": "BTFeatureDefinitionCall-1406",
        "feature": {
            "btType": "BTMSketch-151",
            "featureType": "newSketch",
            "name": name,
            "parameters": [
                {
                    "btType": "BTMParameterQueryList-148",
                    "queries": [
                        {
                            "btType": "BTMIndividualQuery-138",
                            "queryString": 'query=qCreatedBy(makeId("Top"), EntityType.FACE);',
                        }
                    ],
                    "parameterId": "sketchPlane",
                }
            ],
            "entities": entities,
            "constraints": [],
        },
    }
    
    result = m.CLIENT.add_partstudio_feature(did, "w", wid, eid, sketch_body)
    fid = _extract_feature_id(result)
    
    print(f"  Sketch '{name}': {'OK' if fid else 'FAILED'} -> {fid}")
    if not fid:
        print(f"    Response: {json.dumps(result, indent=2)[:800]}")
    
    return fid, result


def create_extrude(m, sketch_fid, depth="8 mm", name="Wrench Body"):
    """Extrude a sketch."""
    
    did = m.STATE.did
    wid = m.STATE.wvmid
    eid = m.STATE.eid
    
    extrude_body = {
        "btType": "BTFeatureDefinitionCall-1406",
        "feature": {
            "btType": "BTMFeature-134",
            "featureType": "extrude",
            "name": name,
            "parameters": [
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "SOLID",
                    "enumName": "ExtendedToolBodyType",
                    "parameterId": "bodyType",
                },
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "NEW",
                    "enumName": "NewBodyOperationType",
                    "parameterId": "operationType",
                },
                {
                    "btType": "BTMParameterQueryList-148",
                    "queries": [
                        {"btType": "BTMIndividualSketchRegionQuery-140", "featureId": sketch_fid}
                    ],
                    "parameterId": "entities",
                },
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "BLIND",
                    "enumName": "BoundingType",
                    "parameterId": "endBound",
                },
                {
                    "btType": "BTMParameterQuantity-147",
                    "expression": depth,
                    "parameterId": "depth"
                },
            ],
            "returnAfterSubfeatures": False,
            "suppressed": False,
        },
    }
    
    result = m.CLIENT.add_partstudio_feature(did, "w", wid, eid, extrude_body)
    fid = _extract_feature_id(result)
    
    print(f"  Extrude '{name}': {'OK' if fid else 'FAILED'} -> {fid}")
    if not fid:
        print(f"    Response: {json.dumps(result, indent=2)[:800]}")
    
    return fid, result


def create_jaw_cutout_sketch(m, wrench_sketch_fid, name="Jaw Cutout Sketch"):
    """Create a sketch for the jaw cutout (the open end of the wrench)."""
    
    # Jaw cutout dimensions
    handle_length = 0.12
    head_radius = 0.018
    head_cx = handle_length + head_radius * 0.7
    
    jaw_width = 0.010   # 10mm
    jaw_depth = 0.025   # 25mm (goes past center)
    jaw_y = 0
    
    # Rectangle for jaw cutout
    entities = [
        {
            "btType": "BTMSketchCurveSegment-155",
            "geometry": {
                "btType": "BTCurveGeometryLine-117",
                "pntX": head_cx + head_radius - 0.002,
                "pntY": -jaw_width / 2,
                "dirX": jaw_depth,
                "dirY": 0,
            },
            "startParam": 0,
            "endParam": 1,
            "entityId": "jaw1",
        },
        {
            "btType": "BTMSketchCurveSegment-155",
            "geometry": {
                "btType": "BTCurveGeometryLine-117",
                "pntX": head_cx + head_radius - 0.002 + jaw_depth,
                "pntY": -jaw_width / 2,
                "dirX": 0,
                "dirY": jaw_width,
            },
            "startParam": 0,
            "endParam": 1,
            "entityId": "jaw2",
        },
        {
            "btType": "BTMSketchCurveSegment-155",
            "geometry": {
                "btType": "BTCurveGeometryLine-117",
                "pntX": head_cx + head_radius - 0.002 + jaw_depth,
                "pntY": jaw_width / 2,
                "dirX": -jaw_depth,
                "dirY": 0,
            },
            "startParam": 0,
            "endParam": 1,
            "entityId": "jaw3",
        },
        {
            "btType": "BTMSketchCurveSegment-155",
            "geometry": {
                "btType": "BTCurveGeometryLine-117",
                "pntX": head_cx + head_radius - 0.002,
                "pntY": jaw_width / 2,
                "dirX": 0,
                "dirY": -jaw_width,
            },
            "startParam": 0,
            "endParam": 1,
            "entityId": "jaw4",
        },
    ]
    
    did = m.STATE.did
    wid = m.STATE.wvmid
    eid = m.STATE.eid
    
    sketch_body = {
        "btType": "BTFeatureDefinitionCall-1406",
        "feature": {
            "btType": "BTMSketch-151",
            "featureType": "newSketch",
            "name": name,
            "parameters": [
                {
                    "btType": "BTMParameterQueryList-148",
                    "queries": [
                        {
                            "btType": "BTMIndividualQuery-138",
                            "queryString": 'query=qCreatedBy(makeId("Top"), EntityType.FACE);',
                        }
                    ],
                    "parameterId": "sketchPlane",
                }
            ],
            "entities": entities,
            "constraints": [],
        },
    }
    
    result = m.CLIENT.add_partstudio_feature(did, "w", wid, eid, sketch_body)
    fid = _extract_feature_id(result)
    
    print(f"  Sketch '{name}': {'OK' if fid else 'FAILED'} -> {fid}")
    
    return fid, result


def create_cut_extrude(m, sketch_fid, depth="10 mm", name="Jaw Cut"):
    """Extrude-cut (remove material)."""
    
    did = m.STATE.did
    wid = m.STATE.wvmid
    eid = m.STATE.eid
    
    extrude_body = {
        "btType": "BTFeatureDefinitionCall-1406",
        "feature": {
            "btType": "BTMFeature-134",
            "featureType": "extrude",
            "name": name,
            "parameters": [
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "SOLID",
                    "enumName": "ExtendedToolBodyType",
                    "parameterId": "bodyType",
                },
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "REMOVE",  # Cut operation
                    "enumName": "NewBodyOperationType",
                    "parameterId": "operationType",
                },
                {
                    "btType": "BTMParameterQueryList-148",
                    "queries": [
                        {"btType": "BTMIndividualSketchRegionQuery-140", "featureId": sketch_fid}
                    ],
                    "parameterId": "entities",
                },
                {
                    "btType": "BTMParameterEnum-145",
                    "value": "THROUGH_ALL",  # Cut through everything
                    "enumName": "BoundingType",
                    "parameterId": "endBound",
                },
            ],
            "returnAfterSubfeatures": False,
            "suppressed": False,
        },
    }
    
    result = m.CLIENT.add_partstudio_feature(did, "w", wid, eid, extrude_body)
    fid = _extract_feature_id(result)
    
    print(f"  Cut '{name}': {'OK' if fid else 'FAILED'} -> {fid}")
    if not fid:
        print(f"    Response: {json.dumps(result, indent=2)[:800]}")
    
    return fid, result


def main():
    _ensure_env()
    ensure_onshape_agent_on_path()
    
    url = os.environ.get("ONSHAPE_TEST_URL", "").strip() or DEFAULT_TEST_URL
    
    import onshape_mcp_server as m
    
    ctx = setup_context(m, url)
    
    created_ids = []
    
    try:
        print("\n=== Creating Wrench ===")
        
        # Step 1: Create main profile sketch
        sketch_fid, _ = create_wrench_sketch(m, "Wrench Outline")
        if sketch_fid:
            created_ids.append(sketch_fid)
        else:
            raise RuntimeError("Failed to create wrench sketch")
        
        # Step 2: Extrude the profile
        extrude_fid, _ = create_extrude(m, sketch_fid, "6 mm", "Wrench Base")
        if extrude_fid:
            created_ids.append(extrude_fid)
        else:
            raise RuntimeError("Failed to create extrude")
        
        # Step 3: Create jaw cutout sketch
        jaw_sketch_fid, _ = create_jaw_cutout_sketch(m, sketch_fid, "Jaw Sketch")
        if jaw_sketch_fid:
            created_ids.append(jaw_sketch_fid)
        
        # Step 4: Cut the jaw
        if jaw_sketch_fid:
            jaw_cut_fid, _ = create_cut_extrude(m, jaw_sketch_fid, "10 mm", "Jaw Cut")
            if jaw_cut_fid:
                created_ids.append(jaw_cut_fid)
        
        # Check result
        print("\n=== Result ===")
        bbox = m.tool_onshape_get_partstudio_bounding_boxes({})
        if isinstance(bbox, dict) and not bbox.get("error"):
            width = (bbox.get("highX", 0) - bbox.get("lowX", 0)) * 1000
            height = (bbox.get("highY", 0) - bbox.get("lowY", 0)) * 1000
            depth = (bbox.get("highZ", 0) - bbox.get("lowZ", 0)) * 1000
            print(f"Bounding box: {width:.1f}mm x {height:.1f}mm x {depth:.1f}mm")
        
        features = m.tool_onshape_get_features_summary({})
        if isinstance(features, dict) and features.get("features"):
            print(f"Total features: {len(features['features'])}")
            for f in features["features"]:
                print(f"  - {f.get('name')} ({f.get('featureType')})")
        
        print("\n=== Keeping features for visual inspection ===")
        print("Created feature IDs:", created_ids)
        
        # Don't clean up - let user inspect
        # input("Press Enter to clean up...")
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
    
    # finally:
    #     print(f"\n=== Cleanup ===")
    #     cleanup_features(m, created_ids)
    
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
